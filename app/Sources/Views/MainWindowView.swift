import Sparkle
import SwiftUI

/// Which screen the single main window is showing. The window is one surface
/// that resizes between login → team picker → settings.
enum MainScreen {
    case login, teamPicker, settings

    var size: CGSize {
        switch self {
        case .login: CGSize(width: 380, height: 420)
        case .teamPicker: CGSize(width: 520, height: 560)
        case .settings: CGSize(width: 440, height: 640)
        }
    }
}

/// The one app window: hosts login, team picker and settings, animating its
/// frame when the screen switches instead of opening separate windows.
struct MainWindowView: View {
    let updater: SPUUpdater
    @EnvironmentObject var session: AppSession

    var body: some View {
        ZStack {
            AppBackground()
            switch session.mainScreen {
            case .login:
                LoginView()
            case .teamPicker:
                TeamPickerView()
            case .settings:
                SettingsView(updater: updater)
            }
        }
        .frame(width: session.mainScreen.size.width, height: session.mainScreen.size.height)
        .animation(.spring(duration: 0.35, bounce: 0.15), value: session.mainScreen)
        .installsWindowOpener()
        .appTheme(session.prefs.settings.theme ?? .system)
    }
}
