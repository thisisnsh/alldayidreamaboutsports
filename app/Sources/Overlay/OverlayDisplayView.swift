import SwiftUI

/// Full-screen, click-through layer hosting fire-and-forget goal confetti
/// bursts and passive notch pills.
struct OverlayDisplayView: View {
    @EnvironmentObject var overlay: OverlayManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Bursts overlap freely and outlive their set — each token is
                // an independent ConfettiView with its own clock.
                ForEach(reduceMotion ? [] : overlay.confettiBursts) { burst in
                    ConfettiView(size: geo.size, logo: burst.logo)
                        .id(burst.id)
                }

                NotchStackView(items: overlay.activeSet)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .respectReducedMotion()
    }
}
