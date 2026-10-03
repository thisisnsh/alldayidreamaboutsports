import Foundation
import ServiceManagement

/// Launch-at-login starts OFF: App Review (guideline 2.4.5) bars adding a login
/// item without the user's consent, so only the Settings toggle registers it.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
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
