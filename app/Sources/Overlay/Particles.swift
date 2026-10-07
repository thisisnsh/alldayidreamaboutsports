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
        .onAppear {
            // Reset the clock HERE, not at init: if the view is created
            // before it appears, particles would start mid-trajectory —
            // that's the "confetti not starting from the bottom" bug.
            start = Date()
            particles = Self.makeBursts(in: size)
        }
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
