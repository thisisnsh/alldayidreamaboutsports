import SwiftUI

/// Full-screen, click-through layer hosting fire-and-forget confetti bursts,
/// the center ball scene for the set's fan goals, and passive notch pills.
struct OverlayDisplayView: View {
    @EnvironmentObject var overlay: OverlayManager

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if overlay.ballPhase != .hidden, !overlay.ballEvents.isEmpty {
                    BallScene(size: geo.size)
                        // Keyed per set so state never leaks between
                        // consecutive sets.
                        .id(overlay.ballEvents.first?.eventId ?? "")
                        .transition(.opacity)
                }

                // Bursts overlap freely and outlive their set — each token is
                // an independent ConfettiView with its own clock.
                ForEach(overlay.confettiBursts) { burst in
                    ConfettiView(size: geo.size)
                        .id(burst.id)
                }

                NotchStackView(items: overlay.activeSet)
            }
            .animation(.easeOut(duration: 0.35), value: overlay.ballPhase)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
    }
}

/// The backdrop behind the center ball (which lives in its own panel, see
/// `InteractiveBallView`): a dark gradient so the white ball pops over any
/// wallpaper.
private struct BallScene: View {
    let size: CGSize

    var body: some View {
        RadialGradient(
            colors: [Color.black.opacity(0.55), .clear],
            center: .center,
            startRadius: 40,
            endRadius: min(size.width, size.height) * 0.45
        )
        .allowsHitTesting(false)
    }
}

/// The ball: SF soccerball in white, with a logo badge for EVERY team
/// that scored.
struct BallView: View {
    let teams: [Team]
    let diameter: CGFloat

    var body: some View {
        ZStack(alignment: .center) {
            Image(systemName: "soccerball")
                .resizable()
                .foregroundStyle(.white)
                .frame(width: diameter, height: diameter)
                .shadow(color: .black.opacity(0.5), radius: 8, y: 4)
            HStack(spacing: diameter * 0.05) {
                ForEach(Array(teams.enumerated()), id: \.offset) { _, team in
                    CachedTeamLogo(url: team.logo, size: diameter * (teams.count > 2 ? 0.14 : 0.18))
                }
            }
            .padding(.horizontal, diameter * 0.045)
            .padding(.vertical, diameter * 0.03)
            .background(
                Capsule(style: .continuous)
                    .fill(.black.opacity(0.32))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(.white.opacity(0.16), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
            )
        }
    }
}
