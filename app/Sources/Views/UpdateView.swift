import Sparkle
import SwiftUI

/// Forced-update window. The menu-bar popover only opens this window (same as
/// the "Sign in" flow); the actual Sparkle check runs from here. The popover is
/// a transient panel with no key window for Sparkle to attach its update UI to,
/// so for an accessory app the check appeared to "do nothing" — a real,
/// activated window fixes that.
struct UpdateView: View {
    @EnvironmentObject var session: AppSession
    let updater: SPUUpdater

    var body: some View {
        ZStack {
            AppBackground()
            content
        }
        .frame(width: 380, height: 360)
        .installsWindowOpener()
        .appTheme(session.prefs.settings.theme ?? .system)
    }

    private var content: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.primary)
                .shadow(radius: 8)
            Text("Update required")
                .font(.system(size: 24, weight: .heavy, design: .rounded))
            Text("This version is too old to keep up with the matches. Update to keep celebrating.")
                .font(.system(size: 14))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 280)
                .opacity(0.8)
            Button {
                updater.checkForUpdates()
            } label: {
                Label("Update now", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.primaryPill)
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.hoverHighlight)
                .font(.caption)
            Spacer()
        }
        .padding(28)
    }
}
