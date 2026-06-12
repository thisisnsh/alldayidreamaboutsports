import SwiftUI

/// Content of the small interactive panel shown during the tap window: the
/// tappable ball plus a hover-revealed ✕ at the cluster's top-right.
struct InteractiveBallView: View {
    @EnvironmentObject var overlay: OverlayManager
    @State private var hovering = false
    @State private var pulse = false

    private var team: Team {
        TeamCatalog.team(for: overlay.currentEvent?.teamCode ?? "", in: AppSession.shared.teams)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            BallView(team: team, diameter: 160)
                .scaleEffect(pulse ? 1.06 : 1.0)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulse)
                .contentShape(Circle())
                .onTapGesture {
                    overlay.registerTap()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if hovering {
                Button {
                    overlay.dismissCurrent()
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
