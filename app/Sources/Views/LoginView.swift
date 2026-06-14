import SwiftUI

struct LoginView: View {
    @EnvironmentObject var session: AppSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ZStack {
            AppBackground()
            loginContent
        }
        .frame(width: 380, height: 420)
        .installsWindowOpener()
        .appTheme(session.prefs.settings.theme ?? .system)
        .onChange(of: session.profile) { _, profile in
            guard profile != nil else { return }
            dismiss()
            // Straight into the team picker — an empty app is a dead app.
            if session.fanTeamIds.isEmpty {
                openWindow(id: WindowID.teamPicker)
            }
        }
    }

    private var loginContent: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "soccerball")
                .font(.system(size: 56))
                .foregroundStyle(.primary)
                .shadow(radius: 8)
            Text("All Day I Dream\nAbout Sports")
                .font(.system(size: 28, weight: .heavy, design: .rounded))
                .multilineTextAlignment(.center)
            Text("Live World Cup goals, right on your Mac.")
                .font(.system(size: 14, design: .rounded))
                .opacity(0.8)

            Button {
                session.signInWithGoogle(presenting: NSApp.keyWindow)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "g.circle.fill")
                    Text("Sign in with Google")
                }
            }
            .buttonStyle(.primaryPill)

            if let error = session.signInError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: 280)
            }
            Spacer()
            #if DEV_BACKEND
            Text("🧪 DEV build — you only see this after signing out; sign-in is instant and offline")
                .font(.caption2)
                .padding(4)
                .background(Capsule().fill(.yellow.opacity(0.3)))
            #endif
            Text("Lives in your menu bar — look for the ⚽ up top.")
                .font(.caption)
                .opacity(0.6)
                .padding(.bottom, 14)
        }
        .padding(28)
    }
}
