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
            // Crossfade between screens. The animation modifier sits INSIDE
            // the frame, so the frame (and the window with it) snaps to the
            // new shape instantly while only the content fades.
            .transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.25), value: session.mainScreen)
        .frame(width: session.mainScreen.size.width, height: session.mainScreen.size.height)
        .installsWindowOpener()
        .appTheme(session.prefs.settings.theme ?? .system)
    }
}
