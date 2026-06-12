import SwiftUI

/// Blocking window for the kill switch and forced updates. While this is the
/// state of the world, overlays and celebrations are disabled (ControlPlane
/// gates EventRouter).
struct GateView: View {
    @EnvironmentObject var session: AppSession
    @ObservedObject private var control = ControlPlane.shared

    var body: some View {
        ZStack {
            AppBackground()
            VStack(spacing: 18) {
                Image(systemName: control.updateRequired ? "arrow.down.circle.fill" : "wrench.and.screwdriver.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.primary)

                if control.updateRequired {
                    Text("Update required")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                    Text("This version is too old to keep up with the matches. Update to keep celebrating.")
                        .multilineTextAlignment(.center)
                        .font(.system(size: 13))
                        .opacity(0.8)
                    Button("Update now") {
                        // Sparkle handles download + relaunch.
                        if let appDelegate = NSApp.delegate as? AppDelegate {
                            appDelegate.updaterController.checkForUpdates(nil)
                        }
                    }
                    .buttonStyle(.primaryPill)
                } else {
                    Text("Hold on…")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                    Text(control.killMessage.isEmpty
                         ? "We're fixing something — back soon. ⚽"
                         : control.killMessage)
                        .multilineTextAlignment(.center)
                        .font(.system(size: 13))
                        .opacity(0.8)
                }
            }
            .padding(30)
        }
        .frame(width: 360, height: 300)
        .installsWindowOpener()
    }
}
