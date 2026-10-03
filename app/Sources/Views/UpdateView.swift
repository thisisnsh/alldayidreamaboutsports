import SwiftUI

/// Forced/optional update window. The menu-bar popover only opens this window
/// (same as the "Sign in" flow); "Update now" hands off to the App Store.
struct UpdateView: View {
    @EnvironmentObject var session: AppSession
    @ObservedObject private var control = ControlPlane.shared
    @Environment(\.dismiss) private var dismiss
    private static let screen = "update_gate"

    var body: some View {
        ZStack {
            AppBackground()
            content
        }
        .frame(width: 380, height: 360)
        .installsWindowOpener()
        .appTheme(session.prefs.settings.theme ?? .system)
        // Forced and optional updates land in the same window; `required` is
        // what tells the two apart.
        .onAppear {
            AppAnalytics.screenView(Self.screen, ["required": control.updateRequired ? "yes" : "no"])
        }
    }

    private var content: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.primary)
                .shadow(radius: 8)
            Text(control.updateRequired ? "Update required" : "Update available")
                .font(.system(size: 24, weight: .heavy, design: .rounded))
            Text(control.updateRequired
                 ? "This version is too old to keep up with the matches. Update to keep celebrating."
                 : "A newer version is ready. Update now to get the latest.")
                .font(.system(size: 14))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 280)
                .opacity(0.8)
            Button {
                AppAnalytics.updateCheckStarted(source: "update_gate")
                AppUpdater.checkForUpdates()
            } label: {
                Label("Update now", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.primaryPill)
            // A forced update can only be resolved or quit; an optional one can
            // be dismissed for later.
            if control.updateRequired {
                Button("Quit") {
                    AppAnalytics.appQuit(source: "update_gate")
                    NSApp.terminate(nil)
                }
                .buttonStyle(.hoverHighlight)
                .font(.caption)
            } else {
                Button("Later") {
                    AppAnalytics.updateDeferred()
                    dismiss()
                }
                .buttonStyle(.hoverHighlight)
                .font(.caption)
            }
            Spacer()
        }
        .padding(28)
    }
}
