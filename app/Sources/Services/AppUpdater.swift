import AppKit

/// The Mac App Store installs every update, so "update" anywhere in the app
/// (Settings, the update banner, the forced-update gate) opens its Updates page.
enum AppUpdater {
    static func checkForUpdates() {
        NSWorkspace.shared.open(URL(string: "macappstore://showUpdatesPage")!)
    }
}
