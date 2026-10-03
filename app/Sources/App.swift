import SwiftUI

@main
struct AllDayIDreamAboutSportsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var session = AppSession.shared
    @State private var insertsSwiftUIMenu = false

    var body: some Scene {
        // Keep a non-window scene first so SwiftUI does not open one of the
        // utility windows at launch. AppKit owns the real transient menu.
        MenuBarExtra(isInserted: $insertsSwiftUIMenu) {
            EmptyView()
        } label: {
            EmptyView()
        }

        // Separate windows, all without title bars — just the traffic
        // lights over content; headings live in the views themselves.
        Window("Welcome", id: WindowID.welcome) {
            WelcomeView()
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
            SettingsView()
                .environmentObject(session)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        Window("Update", id: WindowID.update) {
            UpdateView()
                .environmentObject(session)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)

    }
}

enum WindowID {
    static let welcome = "welcome"
    static let teamPicker = "teamPicker"
    static let settings = "settings"
    static let update = "update"
}
