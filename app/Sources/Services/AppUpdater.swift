import AppKit
import Combine
#if !APP_STORE
import Sparkle
#endif

/// How this build updates itself. The website DMG runs Sparkle; the Mac App
/// Store build links no updater at all (App Review rejects self-updating apps),
/// so every "update" action there hands off to the App Store's Updates page.
final class AppUpdater: ObservableObject {
    @Published private(set) var canCheckForUpdates = true

    #if APP_STORE
    /// The App Store owns update checks; there is no in-app schedule to toggle.
    let managesAutomaticChecks = false
    var automaticallyChecksForUpdates = true

    init() {}

    func checkForUpdates() {
        NSWorkspace.shared.open(URL(string: "macappstore://showUpdatesPage")!)
    }
    #else
    let managesAutomaticChecks = true
    // Same pattern as aithing-mac: one standard updater for the whole app.
    private let controller: SPUStandardUpdaterController

    /// Sparkle persists this flag in UserDefaults itself.
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    init(startingUpdater: Bool) {
        controller = SPUStandardUpdaterController(
            startingUpdater: startingUpdater,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
    #endif
}
