import AppKit
import SwiftUI

/// The real-time notification stack hanging off the notch: every match event
/// appears the moment it arrives — newest at the bottom, oldest sliding up
/// and out at the top. Styled to read as an extension of the notch hardware.
///
/// Hosted in its OWN fixed-size non-click-through panel pinned under the notch,
/// so it can use SwiftUI `.onHover` to reveal the set's ✕ — the same reliable
/// mechanism the celebration ball uses, instead of polling the cursor against a
/// rect. Laid out like `OverlayDisplayView`: a `GeometryReader` gives the root
/// an explicit frame so the content fills the panel and renders dependably.
struct NotchStackHost: View {
    @EnvironmentObject var overlay: OverlayManager
    @State private var hovering = false

    private var topInset: CGFloat {
        let inset = NSScreen.main?.safeAreaInsets.top ?? 0
        return inset > 0 ? inset : 26 // just below the menu bar when no notch
    }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 8) {
                VStack(spacing: 8) {
                    ForEach(overlay.activeSet) { item in
                        NotchPillRow(item: item)
                            // Drop down out of the notch; rise back into it.
                            // (Each new pill is inserted at the top, so the ones
                            // already showing get pushed down by the layout.)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }

                // The ✕ sits just below the stack and only while hovering —
                // moving onto it stays within the panel, so the hover holds.
                if hovering, !overlay.activeSet.isEmpty {
                    DismissCrossButton { overlay.endSet() }
                        .transition(.opacity)
                }

                Spacer(minLength: 0)
            }
            .padding(.top, topInset + 6)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            // Track hover across the whole panel, including the transparent gaps
            // around the pills (the pills themselves aren't interactive).
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
        }
        .ignoresSafeArea()
    }
}

private struct NotchPillRow: View {
    let item: NotchItem
    // Black pill in dark mode, white pill in light mode; text/icons use
    // `.primary` so they always invert against the fill.
    @Environment(\.colorScheme) private var scheme

    var body: some View {
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
