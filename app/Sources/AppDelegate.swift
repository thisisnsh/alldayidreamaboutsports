import AppKit
import FirebaseCore
import FirebaseMessaging
import GoogleSignIn
import Sparkle
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
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
        // Firebase config is optional in dev builds (plist is gitignored).
        if Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil {
            FirebaseApp.configure()
            Messaging.messaging().delegate = PushService.shared
            NSApplication.shared.registerForRemoteNotifications()
        } else {
            NSLog("⚠️ GoogleService-Info.plist missing — push/remote-config disabled (dev mode)")
        }

        AppSession.shared.bootstrap()
        ControlPlane.shared.start()

        #if DEV_BACKEND
        // Bypassed sign-in means we're already in; fire fake events on a
        // timer so animations can be eyeballed hands-free. Don't register a
        // Debug build as a login item.
        if DevConfig.autoEventsEnabled {
            DevSimulator.startAutoLoop()
        }
        #else
        LaunchAtLogin.registerByDefault()
        if !AppSession.shared.isSignedIn {
            openWindow(WindowID.login)
        }
        #endif
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            GIDSignIn.sharedInstance.handle(url)
        }
    }

    // App is invisible except the menu bar — reopening from Finder/Spotlight
    // should surface something useful.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openWindow(AppSession.shared.isSignedIn ? WindowID.settings : WindowID.login)
        return false
    }

    // APNs token → FCM (required for topic delivery on macOS).
    func application(_ application: NSApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Messaging.messaging().apnsToken = deviceToken
    }

    func application(_ application: NSApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NSLog("APNs registration failed: \(error.localizedDescription)")
    }

    // FCM data messages land here while the app runs.
    func application(_ application: NSApplication,
                     didReceiveRemoteNotification userInfo: [String: Any]) {
        EventRouter.shared.handlePush(userInfo)
    }
}

/// Opens a SwiftUI `Window` scene by id from AppKit contexts.
func openWindow(_ id: String) {
    DispatchQueue.main.async {
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
