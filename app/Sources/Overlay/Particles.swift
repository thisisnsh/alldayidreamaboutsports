import SwiftUI

/// Goal confetti: footballs and the scoring team's crest bursting from the
/// bottom-left and bottom-right corners when a fan team scores. Stays in the
/// corners and out of the middle of the screen, so it never covers what the
/// user is doing.
struct ConfettiView: View {
    let size: CGSize
    /// The scoring team's crest; pieces fall back to footballs until it loads.
    let logo: String
    /// Fixed at first init — the burst token is created and shown in the
    /// same tick, so this is when the burst appears.
    @State private var start = Date()
    @ObservedObject private var logos = TeamLogoStore.shared

    private enum Kind { case ball, crest }

    private struct Particle {
        let kind: Kind
        let origin: CGPoint
        let velocity: CGVector
        let spin: Double
        let size: CGFloat
        let delay: Double
    }

    /// Built in `init`, not `onAppear`: a write from `onAppear` never reaches
    /// the TimelineView's content, so the Canvas kept drawing an empty list
    /// and no confetti ever showed.
    @State private var particles: [Particle]

    init(size: CGSize, logo: String) {
        self.size = size
        self.logo = logo
        _particles = State(initialValue: Self.makeBursts(in: size))
    }

    /// Weak gravity lets pieces float up out of the corners and hang briefly
    /// instead of streaking across; the burst is gone in under four seconds.
    private static let gravity = 300.0
    static let lifetime = 3.6
    private static let fadeSeconds = 1.2

    var body: some View {
        TimelineView(.animation) { context in
            let elapsed = context.date.timeIntervalSince(start)
            // Looked up here, on the main actor, rather than inside the Canvas
            // renderer; nil until the crest has loaded.
            let crest = logos.image(for: logo)
            Canvas { canvas, _ in
                let ball = canvas.resolve(Image(systemName: "soccerball"))
                let crestImage = crest.map { canvas.resolve(Image(nsImage: $0)) }
                for p in particles {
                    let t = elapsed - p.delay
                    guard t > 0, t < Self.lifetime else { continue }
                    let x = p.origin.x + p.velocity.dx * t
                    let y = p.origin.y + p.velocity.dy * t + 0.5 * Self.gravity * t * t
                    guard y < size.height + p.size else { continue }
                    var ctx = canvas
                    ctx.opacity = min(1, max(0, (Self.lifetime - t) / Self.fadeSeconds))
                    ctx.translateBy(x: x, y: y)
                    ctx.rotate(by: .radians(p.spin * t))
                    let box = CGRect(x: -p.size / 2, y: -p.size / 2, width: p.size, height: p.size)
                    if p.kind == .crest, let crestImage {
                        ctx.draw(crestImage, in: Self.aspectFit(crestImage.size, in: box))
                    } else {
                        // White disc under the black glyph so the ball reads
                        // on light and dark wallpapers alike.
                        ctx.fill(Path(ellipseIn: box.insetBy(dx: p.size * 0.04, dy: p.size * 0.04)), with: .color(.white))
                        var glyph = ball
                        glyph.shading = .color(.black)
                        ctx.draw(glyph, in: box)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private static func aspectFit(_ image: CGSize, in box: CGRect) -> CGRect {
        guard image.width > 0, image.height > 0 else { return box }
        let scale = min(box.width / image.width, box.height / image.height)
        let w = image.width * scale, h = image.height * scale
        return CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h)
    }

    private static func makeBursts(in size: CGSize) -> [Particle] {
        var all: [Particle] = []
        // Spawn just outside the bottom-left and bottom-right corners; mostly
        // vertical launch angles keep the burst anchored to its corner
        // instead of drifting into the center of the screen.
        let corners: [(CGPoint, Double)] = [
            (CGPoint(x: -24, y: size.height + 24), 1.0),
            (CGPoint(x: size.width + 24, y: size.height + 24), -1.0),
        ]
        for (corner, dir) in corners {
            for i in 0..<18 {
                let angle = Double.random(in: 1.05...1.5) // steep: up, barely inward
                let speed = Double.random(in: 300...580)
                all.append(Particle(
                    kind: i.isMultiple(of: 2) ? .crest : .ball,
                    origin: corner,
                    velocity: CGVector(dx: cos(angle) * speed * dir, dy: -sin(angle) * speed),
                    spin: Double.random(in: -4...4),
                    size: CGFloat.random(in: 22...36),
                    delay: Double.random(in: 0...0.5)
                ))
            }
        }
        return all
    }
}
