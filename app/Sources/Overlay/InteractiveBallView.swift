import SwiftUI

/// Content of the small interactive panel shown while the ball is tappable:
/// one ball carrying every celebrated team's logo, plus a hover-revealed ✕
/// below the persistent prompt. The ✕ dismisses ONLY the ball — the
/// notification set keeps its own life.
struct InteractiveBallView: View {
    @EnvironmentObject var overlay: OverlayManager
    @State private var hovering = false
    @State private var pulse = false

    private var teams: [Team] {
        overlay.ballEvents.compactMap { $0.teamId }
            .map { TeamCatalog.team(for: $0, in: AppSession.shared.teams) }
    }

    var body: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)

            BallView(teams: teams, diameter: 160)
                .scaleEffect(pulse ? 1.06 : 1.0)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulse)
                .contentShape(Circle())
                .onTapGesture {
                    overlay.registerTap()
                }

            Text("Tap the ball to show support")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .shadow(radius: 4)
                .allowsHitTesting(false)

            if hovering {
                DismissCrossButton { overlay.dismissBall() }
                    .transition(.opacity)
            } else {
                Color.clear
                    .frame(width: 22, height: 22)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onHover { hovering = $0 }
        .onAppear { pulse = true }
    }
}
