import SwiftUI

/// Content of the small panel shown with the goal ball: who scored, one ball
/// carrying every scoring team's logo, and a ✕ that dismisses ONLY the ball —
/// the notification set keeps its own life.
struct InteractiveBallView: View {
    @EnvironmentObject var overlay: OverlayManager
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The teams that scored, one entry each — two goals by the same side
    /// in one set shouldn't badge the ball twice or name it twice. Names are
    /// the full club names: this is the middle of the screen, and the compact
    /// codes belong to the pills and the resting capsule.
    private var scorers: [(team: Team, name: String)] {
        var seen = Set<Int>()
        return overlay.ballEvents.compactMap { event in
            guard let teamId = event.teamId, seen.insert(teamId).inserted else { return nil }
            return (TeamCatalog.team(for: teamId, in: AppSession.shared.allTeams), event.wireName(for: teamId))
        }
    }

    var body: some View {
        let scorers = self.scorers
        VStack(spacing: 8) {
            Spacer(minLength: 0)

            Text(scorers.map(\.name).joined(separator: " · "))
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .shadow(radius: 4)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 10)
                .allowsHitTesting(false)

            BallView(teams: scorers.map(\.team), diameter: 160)
                .scaleEffect(!reduceMotion && pulse ? 1.06 : 1.0)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulse)
                .allowsHitTesting(false)

            DismissCrossButton { overlay.dismissBall() }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { pulse = true }
        .respectReducedMotion()
    }
}
