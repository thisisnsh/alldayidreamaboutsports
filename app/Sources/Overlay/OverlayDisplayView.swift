import SwiftUI

/// Full-screen, click-through layer hosting everything at once: the pill set
/// under the notch, fire-and-forget confetti bursts, and the center ball
/// scene for the set's fan goals.
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
/// every team that scored, with the goals stacked vertically beneath it.
private struct BallScene: View {
    let events: [MatchEvent]
    let size: CGSize
    @EnvironmentObject var overlay: OverlayManager

    private var teams: [Team] {
        events.compactMap { $0.teamId }.map { TeamCatalog.team(for: $0, in: AppSession.shared.teams) }
    }

    var body: some View {
        ZStack {
            // Center dark gradient so text stays readable over any wallpaper.
            RadialGradient(
                colors: [Color.black.opacity(0.55), .clear],
                center: .center,
                startRadius: 40,
                endRadius: min(size.width, size.height) * 0.45
            )
            .allowsHitTesting(false)

            if overlay.ballPhase == .dropping {
                FadingBall(teams: teams, size: size)
            }

            if overlay.ballPhase == .tapping {
                goalLines
                MiniBallBursts(teams: teams, size: size, bursts: overlay.tapBursts)

                // Small tip floating just above the ball — not a notch drop.
                Text("Tap the ball to show support")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))
                    .position(x: size.width / 2, y: size.height / 2 - 110)
                    .allowsHitTesting(false)
            }
        }
    }

    /// One block per fan goal in the set, stacked vertically under the ball:
    /// the scoreline (scoring side bold) over the scorer and minute.
    private var goalLines: some View {
        VStack(spacing: events.count > 2 ? 10 : 14) {
            Spacer().frame(height: size.height / 2 + 95)
            ForEach(events, id: \.eventId) { event in
                VStack(spacing: 2) {
                    scoreLine(for: event)
                        .font(.system(size: events.count > 2 ? 16 : 22, design: .rounded))
                        .lineLimit(1)
                    if let scorer = scorerLine(for: event) {
                        Text(scorer)
                            .font(.system(size: events.count > 2 ? 11 : 14, weight: .medium, design: .rounded))
                            .opacity(0.85)
                            .lineLimit(1)
                    }
                }
            }
            Spacer()
        }
        .foregroundStyle(.white)
        .shadow(radius: 6)
        .transition(.opacity)
        .allowsHitTesting(false)
    }

    /// [logo] Team 1 - 0 Team [logo] — the side that scored is bold.
    private func scoreLine(for event: MatchEvent) -> some View {
        let homeScored = event.teamId == event.homeTeamId
        let logoSize: CGFloat = events.count > 2 ? 20 : 26
        return HStack(spacing: 6) {
            CachedTeamLogo(url: logo(event.homeTeamId), size: logoSize)
            Text("\(event.homeName) \(event.homeGoals)").fontWeight(homeScored ? .bold : .medium)
            Text("-").fontWeight(.medium)
            Text("\(event.awayGoals) \(event.awayName)").fontWeight(homeScored ? .medium : .bold)
            CachedTeamLogo(url: logo(event.awayTeamId), size: logoSize)
        }
    }

    private func scorerLine(for event: MatchEvent) -> String? {
        let minute = event.minute.map { "\($0)′" }
        guard let player = event.player else { return minute }
        return minute.map { "\(player) \($0)" } ?? player
    }

    private func logo(_ id: Int) -> String {
        TeamCatalog.team(for: id, in: AppSession.shared.teams).logo
    }
}

/// Fades into the center of the screen at full size, then hands off to the
/// tappable interact panel — no drop, no bounce.
private struct FadingBall: View {
    let teams: [Team]
    let size: CGSize
    @State private var shown = false

    var body: some View {
        BallView(teams: teams, diameter: 160)
            .position(x: size.width / 2, y: size.height / 2)
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.easeOut(duration: 0.35)) { shown = true }
            }
    }
}

/// The ball: SF soccerball.inverse in white, with a logo badge for EVERY team
/// being celebrated.
struct BallView: View {
    let teams: [Team]
    let diameter: CGFloat

    var body: some View {
        ZStack(alignment: .center) {
            Image(systemName: "soccerball.inverse")
                .resizable()
                .foregroundStyle(.white)
                .frame(width: diameter, height: diameter)
                .shadow(color: .black.opacity(0.5), radius: 8, y: 4)
            HStack(spacing: diameter * 0.05) {
                ForEach(teams) { team in
                    CachedTeamLogo(url: team.logo, size: diameter * (teams.count > 2 ? 0.30 : 0.42))
                }
            }
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
