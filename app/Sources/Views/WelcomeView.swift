import SwiftUI

/// Shown when the app is opened (launch, or reopened from Finder/Spotlight)
/// once the user follows a team: the app itself lives in the menu bar, so this
/// doubles as a "where did the app go?" guide.
struct WelcomeView: View {
    @EnvironmentObject var session: AppSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    private static let screen = "welcome"

    var body: some View {
        ZStack {
            AppBackground()
            content
        }
        .frame(width: 380, height: 420)
        .installsWindowOpener()
        .appTheme(session.prefs.settings.theme ?? .system)
        .onAppear {
            AppAnalytics.screenView(Self.screen)
        }
    }

    private var content: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "soccerball")
                .font(.system(size: 56))
                .foregroundStyle(.primary)
                .shadow(radius: 8)
            Text("All Day I Dream\nAbout Sports")
                .font(.system(size: 28, weight: .heavy, design: .rounded))
                .multilineTextAlignment(.center)
            Text("Look for the \(Image(systemName: "soccerball")) icon in your status menu")
                .font(.system(size: 14, design: .rounded))
                .multilineTextAlignment(.center)
                .opacity(0.8)
            if session.fanTeamIds.isEmpty {
                Button {
                    AppAnalytics.teamPickerOpened()
                    dismiss()
                    openWindow(id: WindowID.teamPicker)
                } label: {
                    Label("Pick your teams", systemImage: "star.fill")
                }
                .buttonStyle(.primaryPill)
            }
            Spacer()
            Text("Tip: Can't find the icon? Open Finder, then check the top bar.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .opacity(0.6)
                .frame(maxWidth: 300)
                .padding(.bottom, 14)
        }
        .padding(28)
    }
}
