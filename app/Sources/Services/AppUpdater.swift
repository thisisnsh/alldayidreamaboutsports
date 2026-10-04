import AppKit

/// The Mac App Store installs every update, so Settings' "Check for Updates"
/// just opens its Updates page.
enum AppUpdater {
    static func checkForUpdates() {
        NSWorkspace.shared.open(URL(string: "macappstore://showUpdatesPage")!)
    }
}
