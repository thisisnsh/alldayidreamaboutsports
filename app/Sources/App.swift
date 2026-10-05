import SwiftUI

@main
struct AllDayIDreamAboutSportsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var session = AppSession.shared
    @State private var insertsSwiftUIMenu = false

    var body: some Scene {
        // SwiftUI needs a scene; a hidden menu bar extra is one that opens no
        // window. AppKit owns the real status item, popover and onboarding
        // window (see AppDelegate / OnboardingWindowController).
        MenuBarExtra(isInserted: $insertsSwiftUIMenu) {
            EmptyView()
        } label: {
            EmptyView()
        }
    }
}
