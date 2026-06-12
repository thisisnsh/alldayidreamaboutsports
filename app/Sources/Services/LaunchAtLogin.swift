import Foundation
import ServiceManagement

/// Launch-at-login is ON by default — the app only matters if it's already
/// running when the goal happens. Users can switch it off in Settings.
enum LaunchAtLogin {
    private static let appliedKey = "launchAtLoginApplied"

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func registerByDefault() {
        guard !UserDefaults.standard.bool(forKey: appliedKey) else { return }
        try? SMAppService.mainApp.register()
        UserDefaults.standard.set(true, forKey: appliedKey)
    }

    static func set(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Launch at login toggle failed: \(error.localizedDescription)")
        }
    }
}
