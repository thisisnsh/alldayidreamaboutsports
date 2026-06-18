import SwiftUI

struct LoginView: View {
    @EnvironmentObject var session: AppSession
    @ObservedObject private var control = ControlPlane.shared
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

    @ViewBuilder private var loginContent: some View {
        if session.isSignedIn {
            signedInContent
        } else {
            signedOutContent
        }
    }

    /// Already signed in: the window doubles as a "where did the app go?" guide,
    /// since the app itself lives in the menu bar. No sign-in affordance.
    private var signedInContent: some View {
        VStack(spacing: 22) {
            Spacer()
            ballMark
            Text("All Day I Dream\nAbout Sports")
                .font(.system(size: 28, weight: .heavy, design: .rounded))
                .multilineTextAlignment(.center)
            Text("Look for the \(Image(systemName: "soccerball")) icon in your status menu")
                .font(.system(size: 14, design: .rounded))
                .multilineTextAlignment(.center)
                .opacity(0.8)
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

    private var signedOutContent: some View {
        VStack(spacing: 22) {
            Spacer()
            ballMark
            Text("All Day I Dream\nAbout Sports")
                .font(.system(size: 28, weight: .heavy, design: .rounded))
                .multilineTextAlignment(.center)
            Text("Live Sports Events")
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
            .disabled(!control.isOperational)

            if control.killSwitch {
                Text(control.killMessage.isEmpty
                     ? "Sign-in is unavailable while maintenance is in progress."
                     : control.killMessage)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }

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

    private var ballMark: some View {
        Image(systemName: "soccerball")
            .font(.system(size: 56))
            .foregroundStyle(.primary)
            .shadow(radius: 8)
    }
}
