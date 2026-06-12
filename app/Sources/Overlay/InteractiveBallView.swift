import SwiftUI

/// Content of the small interactive panel shown while the ball is tappable:
/// one ball carrying every celebrated team's flag, plus a hover-revealed ✕
/// at the cluster's top-right. The ✕ dismisses ONLY the ball — the
/// notification set keeps its own ✕ and its own life.
struct InteractiveBallView: View {
    @EnvironmentObject var overlay: OverlayManager
    @State private var hovering = false
    @State private var pulse = false

    private var teams: [Team] {
        overlay.ballEvents.compactMap { $0.teamCode }
            .map { TeamCatalog.team(for: $0, in: AppSession.shared.teams) }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            BallView(teams: teams, diameter: 160)
                .scaleEffect(pulse ? 1.06 : 1.0)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulse)
                .contentShape(Circle())
                .onTapGesture {
                    overlay.registerTap()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if hovering {
                Button {
                    overlay.dismissBall()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.white, .black.opacity(0.6))
                }
                .buttonStyle(.plain)
                .hoverLift()
                .padding(10)
                .transition(.opacity)
            }
        }
        .onHover { hovering = $0 }
        .onAppear { pulse = true }
    }
}
