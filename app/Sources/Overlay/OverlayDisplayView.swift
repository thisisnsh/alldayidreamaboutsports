import SwiftUI

/// Full-screen, click-through layer hosting fire-and-forget confetti bursts,
/// the center ball scene for the set's fan goals, and passive notch pills.
struct OverlayDisplayView: View {
    @EnvironmentObject var overlay: OverlayManager

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if overlay.ballPhase != .hidden, !overlay.ballEvents.isEmpty {
                    BallScene(events: overlay.ballEvents, size: geo.size)
                        // Keyed per set so confetti clocks / mini-ball state
                        // never leak between consecutive sets.
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

/// The center celebration for one set: a single ball carrying the flags of
/// every team that scored. Just the ball carrying their logos — no names or
/// scoreline (that detail rides in the notification pills).
private struct BallScene: View {
    let events: [MatchEvent]
    let size: CGSize
    @EnvironmentObject var overlay: OverlayManager

    private var teams: [Team] {
        events.compactMap { $0.teamId }.map { TeamCatalog.team(for: $0, in: AppSession.shared.teams) }
    }

    var body: some View {
        ZStack {
            // Center dark gradient so the white ball pops over any wallpaper.
            RadialGradient(
                colors: [Color.black.opacity(0.55), .clear],
                center: .center,
                startRadius: 40,
                endRadius: min(size.width, size.height) * 0.45
            )
            .allowsHitTesting(false)

            if overlay.ballPhase == .tapping {
                // Each user tap spawns a mini ball; the ✕ and "tap to…" prompt
                // live in the interactive ball panel, revealed on hover
                // (see InteractiveBallView).
                MiniBallBursts(teams: teams, size: size, bursts: overlay.tapBursts)
            }
        }
    }
}

/// The ball: SF soccerball in white, with a logo badge for EVERY team
/// being celebrated.
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
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .black.opacity(0.38), location: 0.18),
                                .init(color: .black.opacity(0.48), location: 0.5),
                                .init(color: .black.opacity(0.38), location: 0.82),
                                .init(color: .clear, location: 1),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .shadow(color: .black.opacity(0.45), radius: 9, y: 3)
            )
        }
    }
}

extension Int {
    /// 2_340_000 → "2.3M", 12_400 → "12.4K"
    var formattedCompact: String {
        let n = Double(self)
        switch n {
        case 1_000_000...: return String(format: "%.1fM", n / 1_000_000)
        case 1_000...: return String(format: "%.1fK", n / 1_000)
        default: return String(self)
        }
    }
}
