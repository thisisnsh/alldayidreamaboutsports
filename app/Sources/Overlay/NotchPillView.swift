import AppKit
import SwiftUI

/// Black pill that slides down from the notch for non-celebration events
/// (cards, opponent goals, kickoff, HT/FT), holds, and slides back up.
/// Styled to read as an extension of the notch hardware — same idea as the
/// NotchView in aithing-mac, reduced to a one-shot toast.
struct NotchPillView: View {
    let icon: String
    let iconColor: Color
    let text: String
    @State private var shown = false

    private var topInset: CGFloat {
        let inset = NSScreen.main?.safeAreaInsets.top ?? 0
        return inset > 0 ? inset : 26
    }

    var body: some View {
        VStack {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(iconColor)
                Text(text)
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
            .offset(y: shown ? topInset + 6 : -80)
            .animation(.spring(duration: 0.55, bounce: 0.2), value: shown)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
        .onAppear {
            shown = true
            let hold = ControlPlane.shared.animationParams.pillHoldSeconds
            DispatchQueue.main.asyncAfter(deadline: .now() + hold) {
                shown = false // slides back up; OverlayManager finishes shortly after
            }
        }
    }
}
