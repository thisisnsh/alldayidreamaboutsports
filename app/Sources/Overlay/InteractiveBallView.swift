import SwiftUI

/// Content of the small interactive panel shown while the ball is tappable:
/// who scored, a prompt, one ball carrying every celebrated team's logo, and a
/// persistent ✕ that dismisses ONLY the ball — the notification set keeps its
/// own life.
struct InteractiveBallView: View {
    @EnvironmentObject var overlay: OverlayManager
    @State private var pulse = false

    /// The teams being celebrated, one entry each — two goals by the same side
    /// in one set shouldn't badge the ball twice or name it twice. Names are
    /// the full club names: this is the middle of the screen, and the compact
    /// codes belong to the pills and the resting capsule.
    private var celebrated: [(team: Team, name: String)] {
        var seen = Set<Int>()
        return overlay.ballEvents.compactMap { event in
            guard let teamId = event.teamId, seen.insert(teamId).inserted else { return nil }
            return (TeamCatalog.team(for: teamId, in: AppSession.shared.allTeams), event.wireName(for: teamId))
        }
    }

    var body: some View {
        let celebrated = self.celebrated
        VStack(spacing: 8) {
            Spacer(minLength: 0)

            Text(celebrated.map(\.name).joined(separator: " · "))
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .shadow(radius: 4)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 10)
                .allowsHitTesting(false)

            Text("Tap the ball to celebrate")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .shadow(radius: 4)
                .allowsHitTesting(false)

            BallView(teams: celebrated.map(\.team), diameter: 160)
                .scaleEffect(pulse ? 1.06 : 1.0)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulse)
                .contentShape(Circle())
                .onTapGesture {
                    overlay.registerTap()
                }

            DismissCrossButton { overlay.dismissBall() }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { pulse = true }
    }
}
