import AppKit
import FirebaseCore
import FirebaseMessaging
import GoogleSignIn
import Sparkle
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let menuController = MenuPopoverController.shared
    // Dev builds never start Sparkle: the scheduled appcast fetch is a network
    // hit, and a Debug build registering for auto-updates is wrong anyway.
    #if DEV_BACKEND
    private static let startsUpdater = false
    #else
    private static let startsUpdater = true
    #endif

    // Same pattern as aithing-mac: one standard updater for the whole app.
    let updaterController = SPUStandardUpdaterController(
        startingUpdater: AppDelegate.startsUpdater,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Disk-backed HTTP cache so team/league logos (API CDN) download once and
        // are reused across the app — no third-party image service, no cost.
        URLCache.shared = URLCache(memoryCapacity: 16 << 20, diskCapacity: 64 << 20)

        // Firebase config is optional in dev builds (plist is gitignored).
        if Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil {
            FirebaseApp.configure()
            Messaging.messaging().delegate = PushService.shared
            NSLog("Registering for APNs")
            NSApplication.shared.registerForRemoteNotifications()
        } else {
            NSLog("⚠️ GoogleService-Info.plist missing — push/remote-config disabled (dev mode)")
        }

        ControlPlane.shared.start()
        AppSession.shared.bootstrap()
        menuController.install()

        #if DEV_BACKEND
        // Bypassed sign-in means we're already in; play the deterministic
        // demo timeline (DevConfig.timeline) so animations can be eyeballed
        // hands-free. Don't register a Debug build as a login item.
        if DevConfig.autostart {
            DemoEngine.shared.start()
        }
        #else
        LaunchAtLogin.registerByDefault()
        if !AppSession.shared.isSignedIn, ControlPlane.shared.isOperational {
            openWindow(WindowID.login)
        }
        #endif
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            GIDSignIn.sharedInstance.handle(url)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppSession.shared.stopAllActivity()
        ControlPlane.shared.stop()
    }

    // App is invisible except the menu bar — reopening from Finder/Spotlight
    // should surface something useful.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard ControlPlane.shared.isOperational else {
            if ControlPlane.shared.updateRequired {
                openWindow(WindowID.gate)
            }
            return false
        }
        openWindow(AppSession.shared.isSignedIn ? WindowID.settings : WindowID.login)
        return false
    }

    // APNs token → FCM (required for topic delivery on macOS).
    func application(_ application: NSApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Messaging.messaging().apnsToken = deviceToken
        NSLog("APNs registration succeeded: %d-byte token", deviceToken.count)
        PushService.shared.retryPending()
    }

    func application(_ application: NSApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NSLog("APNs registration failed: \(error.localizedDescription)")
    }

    // FCM data messages land here while the app runs.
    func application(_ application: NSApplication,
                     didReceiveRemoteNotification userInfo: [String: Any]) {
        NSLog("Incoming push: %@", String(describing: userInfo))
        EventRouter.shared.handlePush(userInfo)
    }
}

/// AppKit owns the status item so a transient popover closes on focus loss and
/// always clears the status button's highlighted state.
@MainActor
final class MenuPopoverController: NSObject, NSPopoverDelegate {
    static let shared = MenuPopoverController()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private var refreshTimer: Timer?
    private var remoteConfigTimer: Timer?
    private var eventMonitor: Any?

    func install() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "soccerball", accessibilityDescription: "All Day I Dream About Sports")
        button.target = self
        button.action = #selector(toggle)
        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = NSSize(width: 320, height: 520)
        popover.contentViewController = NSHostingController(
            rootView: MenuPopoverView().environmentObject(AppSession.shared)
        )
    }

    @objc private func toggle() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            close()
        } else {
            ControlPlane.shared.refreshRemoteConfig(ignoreCache: true)
            popover.contentSize = NSSize(
                width: 320,
                height: AppSession.shared.isSignedIn ? 520 : (ControlPlane.shared.killSwitch ? 300 : 200)
            )
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            button.highlight(true)
            startRefreshing()
        }
    }

    func close() {
        popover.performClose(nil)
        statusItem.button?.highlight(false)
        stopRefreshing()
    }

    func popoverDidClose(_ notification: Notification) {
        statusItem.button?.highlight(false)
        stopRefreshing()
    }

    private func startRefreshing() {
        // Guard the fetch/timer, not the monitor below — the signed-out popover
        // still needs the outside-click monitor to close.
        startFixtureRefreshing()
        remoteConfigTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in ControlPlane.shared.refreshRemoteConfig(ignoreCache: true) }
        }
        // .transient doesn't reliably close the popover on outside clicks for
        // accessory-policy apps on macOS Sequoia+, so we add our own monitor.
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
    }

    private func stopRefreshing() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        remoteConfigTimer?.invalidate()
        remoteConfigTimer = nil
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    func controlPlaneDidChange() {
        guard popover.isShown else { return }
        refreshTimer?.invalidate()
        refreshTimer = nil
        startFixtureRefreshing()
    }

    private func startFixtureRefreshing() {
        guard AppSession.shared.isSignedIn, ControlPlane.shared.isOperational else { return }
        Task { await AppSession.shared.refreshFixtures() }
        guard ControlPlane.shared.autoRefreshEnabled else { return }
        let interval = max(1, ControlPlane.shared.autoRefreshSeconds)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { await AppSession.shared.refreshFixtures() }
        }
    }

}

/// SwiftUI utility windows are separate scenes, but maintenance should live
/// only in the menu bar popover.
func closeUtilityWindows(titles: Set<String> = ["Sign In", "Become a Fan", "Settings", "Update Required"]) {
    for window in NSApp.windows where titles.contains(window.title) {
        window.close()
    }
}

/// Opens a SwiftUI `Window` scene by id from AppKit contexts.
func openWindow(_ id: String) {
    DispatchQueue.main.async {
        if ControlPlane.shared.killSwitch,
           [WindowID.login, WindowID.teamPicker, WindowID.settings, WindowID.gate].contains(id) {
            return
        }
        if ControlPlane.shared.updateRequired,
           [WindowID.login, WindowID.teamPicker, WindowID.settings].contains(id) {
            return
        }
        if id == WindowID.gate, !ControlPlane.shared.updateRequired {
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        if let url = URL(string: "alldayidreamaboutsports://\(id)") {
            _ = url // reserved for deep links
        }
        // SwiftUI exposes scene opening via EnvironmentValues; from AppKit we
        // go through the shared opener installed by RootWindowOpener.
        WindowOpener.shared.open(id)
    }
}

/// Bridges AppKit → SwiftUI's openWindow environment action. Opens requested
/// before any SwiftUI scene has rendered (e.g. from
/// applicationDidFinishLaunching) are queued and replayed once the handler
/// is installed — the MenuBarExtra label installs it at launch.
final class WindowOpener {
    static let shared = WindowOpener()
    private var pending: [String] = []

    var handler: ((String) -> Void)? {
        didSet {
            guard let handler else { return }
            let queued = pending
            pending = []
            queued.forEach(handler)
        }
    }

    func open(_ id: String) {
        if let handler {
            handler(id)
        } else {
            pending.append(id)
        }
    }
}

/// Invisible helper installed at the root of every scene so AppKit code can
/// open SwiftUI windows.
struct WindowOpenerInstaller: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            WindowOpener.shared.handler = { id in openWindow(id: id) }
        }
    }
}

extension View {
    func installsWindowOpener() -> some View { modifier(WindowOpenerInstaller()) }
}
