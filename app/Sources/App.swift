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

        // Separate windows, all without title bars — just the traffic
        // lights over content; headings live in the views themselves.
        Window("Sign In", id: WindowID.login) {
            LoginView()
                .environmentObject(session)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("Become a Fan", id: WindowID.teamPicker) {
            TeamPickerView()
                .environmentObject(session)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("Settings", id: WindowID.settings) {
            SettingsView(updater: appDelegate.updaterController.updater)
                .environmentObject(session)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

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
    static let login = "login"
    static let teamPicker = "teamPicker"
    static let settings = "settings"
    static let gate = "gate"
}
