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
            Group {
                switch session.mainScreen {
                case .login:
                    LoginView()
                case .teamPicker:
                    TeamPickerView()
                case .settings:
                    SettingsView(updater: updater)
                }
            }
            // Crossfade between screens; the frame eases without bounce so
            // the window resize tracks it cleanly (spring overshoot makes the
            // window server stutter).
            .transition(.opacity)
        }
        .frame(width: session.mainScreen.size.width, height: session.mainScreen.size.height)
        .animation(.easeInOut(duration: 0.28), value: session.mainScreen)
        .installsWindowOpener()
        .appTheme(session.prefs.settings.theme ?? .system)
    }
}
