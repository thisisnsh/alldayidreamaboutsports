import SwiftUI

/// Full-screen, click-through layer hosting both lanes at once:
/// the notch stack (real-time pills) and the center celebration scene.
struct OverlayDisplayView: View {
    @EnvironmentObject var overlay: OverlayManager

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let event = overlay.currentEvent, overlay.phase != .idle {
                    // Keyed by event so back-to-back celebrations rebuild
                    // their views (confetti clocks, mini-ball state) fresh.
                    CelebrationScene(event: event, size: geo.size)
                        .id(event.eventId)
                }

                // Fan goal shown only as a pill (goal-in-center off) still
                // gets confetti — one burst per celebratory item.
                if AppSession.shared.prefs.settings.confetti ?? true,
                   !(AppSession.shared.prefs.settings.goalCenter ?? true) {
                    ForEach(overlay.notchItems.filter(\.celebratory)) { item in
                        ConfettiView(size: geo.size).id(item.id)
                    }
                }

                NotchStackView(items: overlay.notchItems)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
    }
}

private struct CelebrationScene: View {
    let event: MatchEvent
    let size: CGSize
    @EnvironmentObject var overlay: OverlayManager

    private var team: Team {
        TeamCatalog.team(for: event.teamCode ?? "", in: AppSession.shared.teams)
    }

    private var confettiWanted: Bool {
        AppSession.shared.prefs.settings.confetti ?? true
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

            if overlay.phase == .ballDropping {
                FallingBall(team: team, size: size)
            }

            // Confetti fires the moment the celebration appears — it
            // doesn't wait for the ball to land or for any click.
            if confettiWanted {
                ConfettiView(size: size)
            }

            if overlay.phase != .ballDropping {
                scoreboard
                MiniBallBursts(team: team, size: size, bursts: overlay.tapBursts)
            }

            // Small tip floating just above the ball — not a notch drop.
            if overlay.phase == .tapWindow {
                Text("Tap the ball to show support")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))
                    .position(x: size.width / 2, y: size.height / 2 - 110)
                    .allowsHitTesting(false)
            }
        }
        .opacity(overlay.phase == .fadeOut ? 0 : 1)
        .animation(.easeOut(duration: 0.7), value: overlay.phase)
    }

    private var scoreboard: some View {
        VStack(spacing: 10) {
            Spacer().frame(height: size.height / 2 + 90)
            Text("\(flag(event.homeTeam)) \(event.homeName)  \(event.homeGoals) – \(event.awayGoals)  \(event.awayName) \(flag(event.awayTeam))")
                .font(.system(size: 26, weight: .bold, design: .rounded))
            if let player = event.player {
                Text("\(player)\(event.minute.map { " · \($0)′" } ?? "")")
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .opacity(0.85)
            }
            Spacer()
        }
        .foregroundStyle(.white)
        .shadow(radius: 6)
        .transition(.opacity)
        .allowsHitTesting(false)
    }

    private func flag(_ code: String) -> String {
        TeamCatalog.team(for: code, in: AppSession.shared.teams).flag
    }
}

/// Drops from the notch, bounces off the bottom edge, settles center while
/// growing — all analytic (time-based), so it stays smooth and interruptible.
private struct FallingBall: View {
    let team: Team
    let size: CGSize
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation) { context in
            let total = ControlPlane.shared.animationParams.ballDropSeconds
            let t = min(max(context.date.timeIntervalSince(start) / total, 0), 1)
            BallView(team: team, diameter: 60 + 100 * t)
                .position(position(at: t))
        }
        .allowsHitTesting(false)
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

/// The ball: SF soccerball.inverse in white (white ball, dark hexagons), plus
/// the team's flag emoji badge. No images.
struct BallView: View {
    let team: Team
    let diameter: CGFloat

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: "soccerball.inverse")
                .resizable()
                .foregroundStyle(.white)
                .frame(width: diameter, height: diameter)
                .shadow(color: .black.opacity(0.5), radius: 8, y: 4)
            Text(team.flag)
                .font(.system(size: diameter * 0.34))
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
