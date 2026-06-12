import SwiftUI

/// Full-screen, click-through layer: dropping ball, scoreboard, confetti,
/// mini-ball bursts, and everything that hangs off the notch.
struct OverlayDisplayView: View {
    @EnvironmentObject var overlay: OverlayManager

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let event = overlay.currentEvent {
                    switch overlay.phase {
                    case .ballDropping, .tapWindow, .count, .fadeOut:
                        CelebrationScene(event: event, size: geo.size)
                    case .pill:
                        NotchPillView(
                            icon: pillIcon(for: event),
                            iconColor: pillIconColor(for: event),
                            text: pillText(for: event),
                            matchLine: pillMatchLine(for: event)
                        )
                        // Fan goal shown as a pill still gets its confetti.
                        if overlay.pillCelebratory,
                           AppSession.shared.prefs.settings.confetti ?? true {
                            ConfettiView(size: geo.size)
                        }
                    case .idle:
                        EmptyView()
                    }
                }
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
            if overlay.phase != .count {
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

                if overlay.phase == .tapWindow {
                    NotchTextDrop(text: "Tap the ball to show support")
                }
            } else {
                // Everything has faded; only now does the celebration total
                // drop from the notch, so the number means something.
                NotchTextDrop(text: countText)
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

    /// Only the team that scored — and the celebration itself only runs for
    /// teams the user is a fan of, so this is always "your" team. The manager
    /// skips this phase entirely if there's no count and the user never tapped.
    private var countText: String {
        let count = overlay.countTotals[event.teamCode ?? ""] ?? 0
        return count > 0
            ? "🎉 \(count.formattedCompact) celebrations for \(team.name) this match"
            : "🎉 You celebrated with \(team.name)!"
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

/// Text pinned to drop from the notch (or top-center on notchless Macs).
struct NotchTextDrop: View {
    let text: String
    @State private var shown = false

    private var topInset: CGFloat {
        let inset = NSScreen.main?.safeAreaInsets.top ?? 0
        return inset > 0 ? inset : 26 // just below the menu bar when no notch
    }

    var body: some View {
        VStack {
            Text(text)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Capsule().fill(.black)) // matches the notch hardware
                .offset(y: shown ? topInset + 8 : -60)
                .animation(.spring(duration: 0.6, bounce: 0.25), value: shown)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .onAppear { shown = true }
        .allowsHitTesting(false)
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
