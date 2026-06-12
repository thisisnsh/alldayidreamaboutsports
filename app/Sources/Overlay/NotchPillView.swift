import AppKit
import SwiftUI

/// The real-time notification stack hanging off the notch: every match event
/// appears the moment it arrives — newest at the bottom, oldest sliding up
/// and out at the top. Styled to read as an extension of the notch hardware.
struct NotchStackView: View {
    let items: [NotchItem]

    private var topInset: CGFloat {
        let inset = NSScreen.main?.safeAreaInsets.top ?? 0
        return inset > 0 ? inset : 26 // just below the menu bar when no notch
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                ForEach(items) { item in
                    NotchPillRow(item: item)
                        // Drop down out of the notch; rise back into it.
                        // (Each new pill is inserted at the top, so the ones
                        // already showing get pushed down by the layout.)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            // Clip to the stack's own box so pills visibly emerge from (and
            // disappear into) the notch line instead of sliding over the bar.
            .clipped()
            Spacer()
        }
        .padding(.top, topInset + 6)
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
    }
}

private struct NotchPillRow: View {
    let item: NotchItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(item.iconColor)
            Text(item.text)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.black)
                .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
        )
    }
}
