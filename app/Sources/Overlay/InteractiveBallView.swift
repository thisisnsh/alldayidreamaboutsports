import SwiftUI

/// Content of the small interactive panel shown while the ball is tappable:
/// one ball carrying every celebrated team's logo, plus a hover-revealed ✕
/// at the top centre (same look as the notification stack's ✕). The ✕
/// dismisses ONLY the ball — the notification set keeps its own ✕ and life.
struct InteractiveBallView: View {
    @EnvironmentObject var overlay: OverlayManager
    @State private var hovering = false
    @State private var pulse = false

    private var teams: [Team] {
        overlay.ballEvents.compactMap { $0.teamId }
            .map { TeamCatalog.team(for: $0, in: AppSession.shared.teams) }
    }

    var body: some View {
        ZStack {
            BallView(teams: teams, diameter: 160)
                .scaleEffect(pulse ? 1.06 : 1.0)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulse)
                .contentShape(Circle())
                .onTapGesture {
                    overlay.registerTap()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if hovering {
                // ✕ with the prompt right beneath it — both only while
                // hovering, stacked below the ball so neither overlaps it.
                VStack(spacing: 8) {
                    DismissCrossButton { overlay.dismissBall() }
                    Text("Tap the ball to show support")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                        .shadow(radius: 4)
                        .allowsHitTesting(false)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 20)
                .transition(.opacity)
            }
        }
        .onHover { hovering = $0 }
        .onAppear { pulse = true }
    }
}
