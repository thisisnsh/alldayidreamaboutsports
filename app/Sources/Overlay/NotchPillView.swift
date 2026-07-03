import AppKit
import SwiftUI

/// The real-time notification stack hanging off the notch: every match event
/// appears in a displayed set, ordered oldest at the top and newest at the
/// bottom. Styled to read as an extension of the notch hardware.
struct NotchStackView: View {
    let items: [NotchItem]

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: OverlayLayout.stackSpacing) {
                ForEach(items) { item in
                    NotchPillRow(item: item)
                        // Drop down out of the notch; rise back into it.
                        // (Each new pill is inserted at the top, so the ones
                        // already showing get pushed down by the layout.)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            Spacer()
        }
        .padding(.top, OverlayLayout.topMargin(on: NSScreen.main))
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
    }
}

private struct NotchPillRow: View {
    let item: NotchItem
    // Black pill in dark mode, white pill in light mode; text/icons use
    // `.primary` so they always invert against the fill.
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .center, spacing: 2) {
                // The SF Symbol leads the headline row instead of sitting in a left
                // rail spanning both lines — icon and the label it describes
                // ("Goal", "Yellow card") read on the same line.
                HStack(spacing: 6) {
                    Image(systemName: item.icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(item.iconColor)
                    SegmentLine(segments: item.title, size: 13, weight: .semibold, color: .primary)
                }
                if let subtitle = item.subtitle {
                    SegmentLine(segments: subtitle, size: 11, weight: .medium, color: .primary.opacity(0.8))
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(scheme == .dark ? Color.black : Color.white)
                .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
        )
    }
}

/// One pill line, built from `PillSegment`s: text runs interleaved with team
/// logos (no emoji). Kept to a single line — long names truncate.
private struct SegmentLine: View {
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
        .fixedSize(horizontal: true, vertical: false)
    }
}
