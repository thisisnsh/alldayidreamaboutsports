import AppKit
import FirebaseCore
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
        // Live scores arrive by polling (LiveStore) — Firebase is kept solely
        // for Remote Config (the control plane) and Crashlytics. No FCM/APNs.
        if Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil {
            FirebaseApp.configure()
            AppAnalytics.configureAppMetadata()
            AppLog.configureFirebaseCollection()
        } else {
            AppLog.info(.app, "firebase_unconfigured remote_config_disabled")
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

        // Recover live polling after system sleep: App Nap + sleep suspend the
        // LiveStore loop, so on wake we reconcile finished matches and poll now.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main,
        ) { [weak self] _ in
            Task { @MainActor in self?.recoverLivePolling() }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            GIDSignIn.sharedInstance.handle(url)
        }
    }

    // Foreground (e.g. the user clicks into the app): same recovery as wake —
    // the loop may have been App-Napped while idle in the menu bar.
    func applicationDidBecomeActive(_ notification: Notification) {
        recoverLivePolling()
    }

    /// After idle/sleep the LiveStore `Task.sleep` loop may be throttled or
    /// suspended and the Remote Config socket dead. Refresh the control plane,
    /// then (if signed in + operational) reconcile any finished-while-suspended
    /// fan match and run one immediate poll pass. `reconcileFanMatches` is the
    /// only path that can un-stick a past-window match; `refreshNow` covers
    /// in-window ones.
    @MainActor private func recoverLivePolling() {
        #if DEV_BACKEND
        return
        #else
        ControlPlane.shared.refreshRemoteConfig(ignoreCache: true)
        guard AppSession.shared.isSignedIn, ControlPlane.shared.isOperational else { return }
        Task {
            await LiveStore.shared.reconcileFanMatches()
            await LiveStore.shared.refreshNow()
        }
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppSession.shared.stopAllActivity()
        // Quitting drops the cached fixtures/scores/celebrations so the next
        // launch re-fetches fresh rather than flashing a stale board.
        AppSession.shared.clearMatchCache()
        // UserDefaults writes are async (cfprefsd flushes them on a later runloop
        // tick). Terminate gives no such tick, so without forcing a flush the
        // removals in clearMatchCache() are lost and the next launch reads the
        // stale cache back. synchronize() blocks until the writes hit disk.
        UserDefaults.standard.synchronize()
        ControlPlane.shared.stop()
    }

    // App is invisible except the menu bar — reopening from Finder/Spotlight
    // should surface something useful.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard ControlPlane.shared.isOperational else { return false }
        openWindow(AppSession.shared.isSignedIn ? WindowID.settings : WindowID.login)
        return false
    }
}

/// AppKit owns the status item so a transient popover closes on focus loss and
/// always clears the status button's highlighted state.
@MainActor
final class MenuPopoverController: NSObject, NSPopoverDelegate {
    static let shared = MenuPopoverController()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
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
                height: AppSession.shared.isSignedIn
                    ? 520
                    : (ControlPlane.shared.killSwitch || ControlPlane.shared.updateRequired ? 300 : 200)
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
        // Live scores flow continuously from LiveStore (always-on poll loop) —
        // opening the menu just nudges a schedule refresh for immediate freshness
        // and keeps the control plane current.
        if AppSession.shared.isSignedIn, ControlPlane.shared.isOperational {
            Task { await AppSession.shared.refreshFixtures() }
        }
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
        remoteConfigTimer?.invalidate()
        remoteConfigTimer = nil
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    /// Control-plane recovery: the menu no longer drives a fixture timer (the
    /// always-on poll loop does), so there's nothing to restart here.
    func controlPlaneDidChange() {}
}

/// SwiftUI utility windows are separate scenes, but maintenance should live
/// only in the menu bar popover.
func closeUtilityWindows(titles: Set<String> = ["Sign In", "Become a Fan", "Settings"]) {
    for window in NSApp.windows where titles.contains(window.title) {
        window.close()
    }
}

/// Opens a SwiftUI `Window` scene by id from AppKit contexts.
func openWindow(_ id: String) {
    DispatchQueue.main.async {
        if ControlPlane.shared.killSwitch,
           [WindowID.login, WindowID.teamPicker, WindowID.settings].contains(id) {
            return
        }
        if ControlPlane.shared.updateRequired,
           [WindowID.login, WindowID.teamPicker, WindowID.settings].contains(id) {
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        if let url = URL(string: "alldayidreamaboutsports://\(id)") {
            _ = url // reserved for deep links
        }
        // SwiftUI exposes scene opening via EnvironmentValues; from AppKit we
        // go through the shared opener installed by RootWindowOpener.
        WindowOpener.shared.open(id)
        // As an accessory (menu-bar) app, openWindow doesn't reliably raise the
        // window above other apps — especially when the scene already exists and
        // is just being re-shown. Force it to the front once it has rendered.
        bringWindowToFront(id)
    }
}

/// Window titles keyed by scene id, so AppKit can find a just-opened SwiftUI
/// window in `NSApp.windows` (which exposes title, not scene id).
private let windowTitleByID: [String: String] = [
    WindowID.login: "Sign In",
    WindowID.teamPicker: "Become a Fan",
    WindowID.settings: "Settings",
]

/// Raises the window for a scene id above all other apps. Retries briefly
/// because SwiftUI may not have inserted the window into `NSApp.windows` yet.
private func bringWindowToFront(_ id: String, attempt: Int = 0) {
    guard let title = windowTitleByID[id] else { return }
    if let window = NSApp.windows.first(where: { $0.title == title }) {
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        return
    }
    guard attempt < 10 else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
        bringWindowToFront(id, attempt: attempt + 1)
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
