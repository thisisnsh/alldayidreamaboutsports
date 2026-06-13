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
        events.compactMap { $0.teamCode }.map { TeamCatalog.team(for: $0, in: AppSession.shared.teams) }
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
                FallingBall(teams: teams, size: size)
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

    /// 🏳️ Team 1 - 0 Team 🏳️ — the side that scored is bold.
    private func scoreLine(for event: MatchEvent) -> Text {
        let homeScored = event.teamCode == event.homeTeam
        return Text("\(flag(event.homeTeam)) \(event.homeName) \(event.homeGoals)")
            .fontWeight(homeScored ? .bold : .medium)
            + Text(" - ").fontWeight(.medium)
            + Text("\(event.awayGoals) \(event.awayName) \(flag(event.awayTeam))")
            .fontWeight(homeScored ? .medium : .bold)
    }

    private func scorerLine(for event: MatchEvent) -> String? {
        let minute = event.minute.map { "\($0)′" }
        guard let player = event.player else { return minute }
        return minute.map { "\(player) \($0)" } ?? player
    }

    private func flag(_ code: String) -> String {
        TeamCatalog.team(for: code, in: AppSession.shared.teams).flag
    }
}

/// Drops from the notch, bounces off the bottom edge, settles center while
/// growing — all analytic (time-based), so it stays smooth and interruptible.
private struct FallingBall: View {
    let teams: [Team]
    let size: CGSize
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation) { context in
            let total = ControlPlane.shared.animationParams.ballDropSeconds
            let t = min(max(context.date.timeIntervalSince(start) / total, 0), 1)
            BallView(teams: teams, diameter: 60 + 100 * t)
                .position(position(at: t))
        }
        .allowsHitTesting(false)
        .onAppear { start = Date() }
    }

    private func position(at t: Double) -> CGPoint {
        let topY: CGFloat = -60
        let bottomY = size.height - 40
        let centerY = size.height / 2
        let x = size.width / 2
        switch t {
        case ..<0.45: // accelerating fall from the notch
            let p = t / 0.45
            return CGPoint(x: x, y: topY + (bottomY - topY) * p * p)
        case ..<0.75: // bounce off the bottom edge
            let p = (t - 0.45) / 0.3
            let bounceHeight = (bottomY - centerY) * 0.55
            return CGPoint(x: x, y: bottomY - bounceHeight * sin(p * .pi))
        default: // settle into the center
            let p = (t - 0.75) / 0.25
            let from = bottomY
            let eased = 1 - pow(1 - p, 2)
            return CGPoint(x: x, y: from + (centerY - from) * eased)
        }
    }
}

/// The ball: SF soccerball.inverse in white, with a flag badge for EVERY team
/// being celebrated. No images.
struct BallView: View {
    let teams: [Team]
    let diameter: CGFloat

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: "soccerball.inverse")
                .resizable()
                .foregroundStyle(.white)
                .frame(width: diameter, height: diameter)
                .shadow(color: .black.opacity(0.5), radius: 8, y: 4)
            HStack(spacing: -diameter * 0.08) {
                ForEach(teams) { team in
                    Text(team.flag)
                        .font(.system(size: diameter * (teams.count > 2 ? 0.24 : 0.34)))
                }
            }
            .offset(x: diameter * 0.1, y: -diameter * 0.1)
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
