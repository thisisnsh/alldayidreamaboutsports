import SwiftUI

/// Goal confetti: the scoring team's crest and paper confetti bursting from
/// the bottom-left and bottom-right corners when a fan team scores. Each burst
/// leans in toward the middle of the screen, then falls away within seconds.
struct ConfettiView: View {
    let size: CGSize
    /// The scoring team's crest; crest pieces stay hidden until it loads.
    /// Empty (the Settings sample) draws the app's ball instead.
    let logo: String
    /// Fixed at first init — the burst token is created and shown in the
    /// same tick, so this is when the burst appears.
    @State private var start = Date()
    @ObservedObject private var logos = TeamLogoStore.shared

    private enum Kind { case crest, paper }

    private struct Particle {
        let kind: Kind
        let origin: CGPoint
        let velocity: CGVector
        let spin: Double
        let size: CGFloat
        /// Paper confetti only.
        let color: Color
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
                let crestImage: GraphicsContext.ResolvedImage? = if logo.isEmpty {
                    {
                        var ball = canvas.resolve(Image(systemName: "soccerball"))
                        ball.shading = .color(.white)
                        return ball
                    }()
                } else {
                    crest.map { canvas.resolve(Image(nsImage: $0)) }
                }
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
                    if p.kind == .paper {
                        ctx.fill(Path(CGRect(x: -p.size / 2, y: -p.size / 4, width: p.size, height: p.size / 2)), with: .color(p.color))
                    } else if let crestImage {
                        ctx.draw(crestImage, in: Self.aspectFit(crestImage.size, in: box))
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

    /// Per corner: crests with paper confetti around them.
    private static let mix: [Kind] =
        Array(repeating: .crest, count: 14) + Array(repeating: .paper, count: 34)
    private static let paperColors: [Color] = [.yellow, .green, .blue, .pink, .orange, .white, .red]

    private static func makeBursts(in size: CGSize) -> [Particle] {
        var all: [Particle] = []
        // Spawn just outside the bottom-left and bottom-right corners and
        // launch up and inward, so each burst reaches toward the middle of
        // the screen before it falls.
        let corners: [(CGPoint, Double)] = [
            (CGPoint(x: -24, y: size.height + 24), 1.0),
            (CGPoint(x: size.width + 24, y: size.height + 24), -1.0),
        ]
        for (corner, dir) in corners {
            for kind in mix {
                let angle = Double.random(in: 0.9...1.35) // up and inward
                let speed = Double.random(in: 320...620)
                all.append(Particle(
                    kind: kind,
                    origin: corner,
                    velocity: CGVector(dx: cos(angle) * speed * dir, dy: -sin(angle) * speed),
                    spin: Double.random(in: kind == .paper ? -6...6 : -4...4),
                    size: kind == .paper ? CGFloat.random(in: 10...16) : CGFloat.random(in: 28...44),
                    color: paperColors.randomElement()!,
                    delay: Double.random(in: 0...0.5)
                ))
            }
        }
        return all
    }
}
