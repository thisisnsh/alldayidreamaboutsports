import SwiftUI

/// Confetti bursting from bottom-left and bottom-right when a fan team scores.
struct ConfettiView: View {
    let size: CGSize
    @State private var start = Date()

    private struct Particle {
        let origin: CGPoint
        let velocity: CGVector
        let color: Color
        let spin: Double
        let size: CGFloat
        let delay: Double
    }

    @State private var particles: [Particle] = []

    /// Tuned so the burst is unmissable: weak gravity lets pieces float high
    /// out of the corners and hang for ~4s instead of streaking across.
    private static let gravity = 280.0
    private static let lifetime = 4.2

    var body: some View {
        TimelineView(.animation) { context in
            let elapsed = context.date.timeIntervalSince(start)
            Canvas { canvas, _ in
                for p in particles {
                    let t = elapsed - p.delay
                    guard t > 0, t < Self.lifetime else { continue }
                    let x = p.origin.x + p.velocity.dx * t
                    let y = p.origin.y + p.velocity.dy * t + 0.5 * Self.gravity * t * t
                    guard y < size.height + 30 else { continue }
                    var ctx = canvas
                    ctx.opacity = min(1, max(0, (Self.lifetime - t) / 1.5))
                    ctx.translateBy(x: x, y: y)
                    ctx.rotate(by: .radians(p.spin * t))
                    ctx.fill(
                        Path(CGRect(x: -p.size / 2, y: -p.size / 4, width: p.size, height: p.size / 2)),
                        with: .color(p.color)
                    )
                }
            }
        }
        .allowsHitTesting(false)
        .onAppear { particles = Self.makeBursts(in: size) }
    }

    private static func makeBursts(in size: CGSize) -> [Particle] {
        let colors: [Color] = [.yellow, .green, .blue, .pink, .orange, .white, .red]
        var all: [Particle] = []
        // Spawn just outside the bottom-left and bottom-right corners; mostly
        // vertical launch angles keep the burst anchored to its corner
        // instead of drifting into the center of the screen.
        let corners: [(CGPoint, Double)] = [
            (CGPoint(x: -20, y: size.height + 20), 1.0),
            (CGPoint(x: size.width + 20, y: size.height + 20), -1.0),
        ]
        for (corner, dir) in corners {
            for _ in 0..<80 {
                let angle = Double.random(in: 1.05...1.5) // steep: up, barely inward
                let speed = Double.random(in: 320...650)
                all.append(Particle(
                    origin: corner,
                    velocity: CGVector(dx: cos(angle) * speed * dir, dy: -sin(angle) * speed),
                    color: colors.randomElement()!,
                    spin: Double.random(in: -6...6),
                    size: CGFloat.random(in: 10...18),
                    delay: Double.random(in: 0...0.5)
                ))
            }
        }
        return all
    }
}

/// Every click throws 4 mini flag-balls that arc out and settle on the bottom
/// edge of the screen — the floor fills up as fans hammer the ball. They stay
/// put (no bounce, no per-ball fade) until the whole scene fades out.
struct MiniBallBursts: View {
    let team: Team
    let size: CGSize
    let bursts: Int

    /// Matches CelebrationService.tapsPerClick — one click, 4 balls, 4 counts.
    static let ballsPerClick = 4
    /// Hard cap so marathon tap sessions can't grow the canvas unbounded.
    private static let maxBalls = 240
    private static let gravity = 700.0

    private struct Mini {
        let born: Date
        let origin: CGPoint
        let velocity: CGVector
        let diameter: CGFloat
        let landTime: Double // when it touches the bottom edge…
        let landX: CGFloat // …and the x it stays at forever after
    }

    @State private var minis: [Mini] = []

    var body: some View {
        TimelineView(.animation) { context in
            Canvas { canvas, _ in
                let now = context.date
                for m in minis {
                    let t = now.timeIntervalSince(m.born)
                    let floorY = size.height - m.diameter / 2
                    let pos: CGPoint
                    if t >= m.landTime {
                        pos = CGPoint(x: m.landX, y: floorY) // sitting on the edge
                    } else {
                        pos = CGPoint(
                            x: m.origin.x + m.velocity.dx * t,
                            y: m.origin.y + m.velocity.dy * t + 0.5 * Self.gravity * t * t
                        )
                    }
                    var resolved = canvas.resolve(Text("⚽").font(.system(size: m.diameter)))
                    canvas.draw(resolved, at: pos)
                    resolved = canvas.resolve(Text(team.flag).font(.system(size: m.diameter * 0.55)))
                    canvas.draw(resolved, at: CGPoint(x: pos.x + m.diameter * 0.4, y: pos.y - m.diameter * 0.4))
                }
            }
        }
        .allowsHitTesting(false)
        .onChange(of: bursts) { old, new in
            guard new > old else {
                minis.removeAll() // new celebration started (counter reset)
                return
            }
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            for _ in 0..<Self.ballsPerClick {
                let angle = Double.random(in: 0...(2 * .pi))
                let speed = Double.random(in: 250...700)
                let velocity = CGVector(dx: cos(angle) * speed, dy: sin(angle) * speed - 250)
                let diameter = CGFloat.random(in: 16...30)
                // Solve origin.y + vy·t + ½g·t² = floor for the landing moment.
                let floorY = size.height - diameter / 2
                let a = 0.5 * Self.gravity
                let b = velocity.dy
                let c = center.y - floorY
                let landTime = (-b + (b * b - 4 * a * c).squareRoot()) / (2 * a)
                let landX = min(max(center.x + velocity.dx * landTime, diameter / 2),
                                size.width - diameter / 2)
                minis.append(Mini(
                    born: Date(),
                    origin: center,
                    velocity: velocity,
                    diameter: diameter,
                    landTime: landTime,
                    landX: landX
                ))
            }
            if minis.count > Self.maxBalls {
                minis.removeFirst(minis.count - Self.maxBalls)
            }
        }
    }
}
