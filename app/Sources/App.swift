import SwiftUI

@main
struct AllDayIDreamAboutSportsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var session = AppSession.shared

    var body: some Scene {
        MenuBarExtra {
            MenuPopoverView()
                .environmentObject(session)
        } label: {
            // The label is the only view guaranteed to render at launch, so it
            // installs the AppKit→SwiftUI window-opener bridge (queued opens
            // from AppDelegate replay once this appears).
            Image(systemName: "soccerball")
                .installsWindowOpener()
        }
        .menuBarExtraStyle(.window)

        // ONE window for login/picker/settings — it morphs between screens.
        // No title bar; just the traffic lights over content.
        Window("All Day I Dream About Sports", id: WindowID.main) {
            MainWindowView(updater: appDelegate.updaterController.updater)
                .environmentObject(session)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("Update Required", id: WindowID.gate) {
            GateView()
                .environmentObject(session)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

enum WindowID {
    static let main = "main"
    static let gate = "gate"
}
