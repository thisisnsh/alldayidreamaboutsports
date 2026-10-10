import AppKit
import SwiftUI

/// Every dimension in the notch island's drops and match card, scaled by the
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
    let rowSpacing: CGFloat
    /// Bottom corner radius of the dropped island.
    let corner: CGFloat
    /// Width of the island while it shows drops or a match card.
    let islandWidth: CGFloat

    init(_ size: CapsuleSize) {
        switch size {
        case .small:
            icon = 11; title = 11; subtitle = 9.5; disc = 24
            hPad = 14; vPad = 10; rowSpacing = 8; corner = 18; islandWidth = 340
        case .medium:
            icon = 13; title = 13; subtitle = 11; disc = 28
            hPad = 18; vPad = 12; rowSpacing = 10; corner = 22; islandWidth = 390
        case .large:
            icon = 15; title = 15; subtitle = 13; disc = 34
            hPad = 22; vPad = 15; rowSpacing = 12; corner = 26; islandWidth = 460
        }
    }
}

/// One event inside the dropped notch: a tinted icon disc, then the headline
/// and the scoreline. The island is always black (it IS the notch), so this
/// renders in the dark color scheme regardless of the app's theme.
struct NotchDropRow: View {
    let item: NotchItem
    let metrics: NotchPillMetrics

    /// `.primary` icons (goal, sub, VAR…) tint white on the black island.
    private var tint: Color { item.iconColor == .primary ? .white : item.iconColor }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    // A fan goal gets a solid green disc — the loudest row.
                    .fill(item.fanGoal != nil ? Color.green : tint.opacity(0.18))
                Image(systemName: item.icon)
                    .font(.system(size: metrics.icon, weight: .semibold))
                    .foregroundStyle(item.fanGoal != nil ? Color.white : tint)
            }
            .frame(width: metrics.disc, height: metrics.disc)
            VStack(alignment: .leading, spacing: 2) {
                SegmentLine(segments: item.title, size: metrics.title, weight: .semibold, color: .primary)
                if let subtitle = item.subtitle {
                    SegmentLine(segments: subtitle, size: metrics.subtitle, weight: .medium, color: .secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// One drop line, built from `PillSegment`s: text runs interleaved with team
/// logos (no emoji). Kept to a single line — long names truncate to the
/// island's width.
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
