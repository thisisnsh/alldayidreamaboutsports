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

        // The welcome window, without a title bar — just the traffic lights
        // over content. Teams and Settings live in the menu bar popover.
        Window("Welcome", id: WindowID.welcome) {
            WelcomeView()
                .environmentObject(session)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

enum WindowID {
    static let welcome = "welcome"
}
