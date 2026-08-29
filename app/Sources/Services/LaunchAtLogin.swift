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
        guard !AppDefaults.shared.bool(forKey: appliedKey) else { return }
        do {
            try SMAppService.mainApp.register()
            AppDefaults.shared.set(true, forKey: appliedKey)
            AppLog.info(.app, "launch_at_login_default_registered")
        } catch {
            AppLog.error(.app, "launch_at_login_default_registration_failed", error: error)
        }
    }

    static func set(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            AppLog.info(.app, "launch_at_login_changed enabled=\(enabled)")
        } catch {
            AppLog.error(.app, "launch_at_login_change_failed enabled=\(enabled)", error: error)
        }
    }
}
