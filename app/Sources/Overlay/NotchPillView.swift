import AppKit
import SwiftUI

/// Every dimension in the notch drops and the island's match card, scaled by the
/// user's `notchDropSize` setting. Medium is the baseline; small/large step it
/// down/up proportionally. The compact pin (beside the notch) does NOT scale:
/// it has to fit the menu bar's height.
struct NotchPillMetrics {
    let icon: CGFloat
    let title: CGFloat
    let subtitle: CGFloat
    /// The tinted disc behind each drop's event icon.
    let disc: CGFloat
    let hPad: CGFloat
    let vPad: CGFloat
    /// Vertical padding inside a drop pill.
    let pillVPad: CGFloat
    let rowSpacing: CGFloat
    /// Bottom corner radius of the match card, and of each drop pill.
    let corner: CGFloat
    /// Width of the island while it shows a match card.
    let islandWidth: CGFloat

    init(_ size: CapsuleSize) {
        switch size {
        case .small:
            icon = 11; title = 11; subtitle = 9.5; disc = 24
            hPad = 14; vPad = 10; pillVPad = 8; rowSpacing = 8; corner = 18; islandWidth = 340
        case .medium:
            icon = 13; title = 13; subtitle = 11; disc = 28
            hPad = 18; vPad = 12; pillVPad = 10; rowSpacing = 10; corner = 22; islandWidth = 390
        case .large:
            icon = 15; title = 15; subtitle = 13; disc = 34
            hPad = 22; vPad = 15; pillVPad = 13; rowSpacing = 12; corner = 26; islandWidth = 460
        }
    }
}

/// One event drop's content, centered like the original notch pills: the
/// SF Symbol leads the headline ("Goal", "Yellow card") on one line, the
/// scoreline sits under it. Drops are always black (they split off the
/// notch), so this renders in the dark color scheme whatever the theme.
struct NotchDropContent: View {
    let item: NotchItem
    let metrics: NotchPillMetrics

    /// `.primary` icons (goal, sub, VAR…) are white on black; a fan goal's
    /// ball is green, the one color that says "yours".
    private var tint: Color {
        if item.fanGoal != nil { return .green }
        return item.iconColor == .primary ? .white : item.iconColor
    }

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: item.icon)
                    .font(.system(size: metrics.icon, weight: .semibold))
                    .foregroundStyle(tint)
                SegmentLine(segments: item.title, size: metrics.title, weight: .semibold, color: .primary)
            }
            if let subtitle = item.subtitle {
                SegmentLine(segments: subtitle, size: metrics.subtitle, weight: .medium, color: .secondary)
            }
        }
        .fixedSize()
        .padding(.horizontal, metrics.hPad)
        .padding(.vertical, metrics.pillVPad)
        .accessibilityElement(children: .combine)
    }
}

/// One drop line, built from `PillSegment`s: text runs interleaved with team
/// logos (no emoji). Kept to a single line.
struct SegmentLine: View {
    let segments: [PillSegment]
    let size: CGFloat
    let weight: Font.Weight
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case let .text(string, bold):
                    Text(string)
                        .font(.system(size: size, weight: bold ? .bold : weight, design: .rounded))
                        .foregroundStyle(color)
                case let .logo(url):
                    CachedTeamLogo(url: url, size: size + 4)
                }
            }
        }
        .lineLimit(1)
    }
}

// MARK: - Drops splitting off the notch

/// How far a drop is through being born: 0 = still the notch, 1 = a bar in
/// its slot. Set per drop by `NotchDropBirth`, read by its shape and content.
private struct NotchDropProgressKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

private extension EnvironmentValues {
    var notchDropProgress: CGFloat {
        get { self[NotchDropProgressKey.self] }
        set { self[NotchDropProgressKey.self] = newValue }
    }
}

/// The drops' transition. Animatable, so SwiftUI re-runs `body` every frame
/// with the in-between progress; the shape and the content both follow it.
/// Inserting runs 0 → 1 (split off the notch); removing runs 1 → 0 (pulled
/// back up into it).
private struct NotchDropBirth: ViewModifier, Animatable {
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content.environment(\.notchDropProgress, progress)
    }
}

/// One drop's black body plus the liquid neck tying it to the notch. Drawn in
/// the drop's own frame (its final slot); `top` is that slot's distance from
/// the screen's top edge, which is where the notch is. At progress 0 the body
/// IS the notch; it slides down and widens into the pill while a pinched
/// neck stretches, thins and snaps.
private struct NotchDropShape: Shape {
    let progress: CGFloat
    let top: CGFloat
    /// The notch the drop comes out of (centered on the drop).
    let source: CGSize
    let sourceCorner: CGFloat
    let corner: CGFloat

    func path(in rect: CGRect) -> Path {
        let p = progress
        func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * p }
        // The body, travelling from the notch (y = -top) to its slot (y = 0).
        let width = lerp(source.width, rect.width)
        let height = max(0, lerp(source.height, rect.height))
        let body = CGRect(x: rect.midX - width / 2, y: lerp(-top, rect.minY), width: width, height: height)
        let radius = min(lerp(sourceCorner, corner), height / 2, width / 2)
        let path = Path(roundedRect: body, cornerRadius: radius, style: .continuous)

        // The neck: full at the start, pinched, gone by ~75% of the way.
        let snap = smoothstep(0.15, 0.75, p)
        let neckWidth = source.width * 0.7 * (1 - snap)
        let neckTop = -top + source.height - 2
        let neckBottom = body.minY + min(radius, height / 2)
        guard neckWidth > 0.5, neckBottom > neckTop else { return path }
        let midX = rect.midX
        let midY = (neckTop + neckBottom) / 2
        // The waist narrows as the neck stretches, like a drop about to fall.
        let waist = neckWidth * (0.5 - 0.35 * snap) / 2
        var neck = Path()
        neck.move(to: CGPoint(x: midX - neckWidth / 2, y: neckTop))
        neck.addQuadCurve(to: CGPoint(x: midX - neckWidth / 2, y: neckBottom),
                          control: CGPoint(x: midX - waist, y: midY))
        neck.addLine(to: CGPoint(x: midX + neckWidth / 2, y: neckBottom))
        neck.addQuadCurve(to: CGPoint(x: midX + neckWidth / 2, y: neckTop),
                          control: CGPoint(x: midX + waist, y: midY))
        neck.closeSubpath()
        // A union, not `addPath`: overlapping subpaths that wind opposite
        // ways would leave a hole where the neck meets the body.
        return path.union(neck)
    }

    private func smoothstep(_ edge0: CGFloat, _ edge1: CGFloat, _ x: CGFloat) -> CGFloat {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

/// A drop's black body, measured against the panel (whose top is the
/// screen's top edge) so the shape knows how far up the notch is.
private struct NotchDropBody: View {
    let geometry: NotchGeometry
    let metrics: NotchPillMetrics
    @Environment(\.notchDropProgress) private var progress

    var body: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .named(NotchDropsLayer.space))
            NotchDropShape(
                progress: progress,
                top: frame.minY,
                source: geometry.dropSource(width: frame.width),
                sourceCorner: geometry.hasNotch ? 9 : 0,
                corner: metrics.corner
            )
            .fill(Color.black)
            // The shadow only once it's its own bar, never on the notch.
            .shadow(color: .black.opacity(0.4 * Double(max(0, min(1, progress)))), radius: 10, y: 4)
        }
    }
}

/// A drop's content shows once the body has mostly formed, and goes first
/// on the way back up.
private struct NotchDropReveal: ViewModifier {
    @Environment(\.notchDropProgress) private var progress

    func body(content: Content) -> some View {
        let reveal = min(max((progress - 0.55) / 0.45, 0), 1)
        content
            .opacity(Double(reveal))
            .scaleEffect(0.92 + 0.08 * reveal, anchor: .top)
    }
}

/// The current set of event drops, stacked under the notch: oldest on top,
/// newest at the bottom, each one split off the notch as it arrives. Two
/// identical stacks — black bodies below, content above — so a later drop's
/// neck, passing up through earlier drops to the notch, never covers their
/// text. Click-through: the island's panel only takes the mouse over the
/// island itself.
struct NotchDropsLayer: View {
    static let space = "notchPanel"

    @ObservedObject private var overlay = OverlayManager.shared
    @ObservedObject private var displayTarget = OverlayDisplayTarget.shared
    @EnvironmentObject private var session: AppSession

    var body: some View {
        let geometry = NotchGeometry(screen: displayTarget.selectedScreen)
        let metrics = NotchPillMetrics(session.prefs.settings.notchDropSize ?? .medium)
        ZStack(alignment: .top) {
            stack { item in
                NotchDropContent(item: item, metrics: metrics)
                    .hidden()
                    .background(NotchDropBody(geometry: geometry, metrics: metrics))
            }
            stack { item in
                NotchDropContent(item: item, metrics: metrics)
                    .modifier(NotchDropReveal())
            }
        }
        .padding(.top, geometry.bandHeight + OverlayLayout.stackSpacing)
        .allowsHitTesting(false)
        .respectReducedMotion()
    }

    private func stack<Row: View>(@ViewBuilder row: @escaping (NotchItem) -> Row) -> some View {
        VStack(spacing: OverlayLayout.stackSpacing) {
            ForEach(overlay.activeSet) { item in
                row(item)
                    .transition(.modifier(
                        active: NotchDropBirth(progress: 0),
                        identity: NotchDropBirth(progress: 1)
                    ))
            }
        }
    }
}
