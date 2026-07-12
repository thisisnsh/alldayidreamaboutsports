import Foundation
#if !DEV_BACKEND
import FirebaseAnalytics
#endif

/// Anonymous product analytics via Firebase Analytics (free, unlimited, and
/// anonymous — it identifies an *app instance* by a random id, never the Google
/// sign-in identity). App version, OS version, device model, first_open and
/// session counts are collected automatically; this layer adds the handful of
/// product events we actually want to learn from (do people follow teams? do
/// they tap celebrations? which settings do they toggle?).
///
/// No-ops in Debug (`DEV_BACKEND`) builds and whenever Firebase isn't configured,
/// so local UI work never pollutes the data. Staging + Release both report — to
/// watch staging events live, launch with the `-FIRDebugEnabled` argument and
/// open Firebase → Analytics → DebugView.
@MainActor
enum AppAnalytics {
    // MARK: App metadata

    /// Firebase collects its own app version automatically, but this publishes
    /// the exact marketing.build value we use for releases.
    static func configureAppMetadata() {
        let version = AppEnvironment.fullAppVersion
        setUserProperty(version, forName: "app_version_full")
        setDefaultEventParameters(["app_version_full": version])
    }

    // MARK: Fan teams

    static func teamFollow(teamId: String, fanCount: Int) {
        log("team_follow", ["team_id": teamId, "fan_count": fanCount])
    }

    static func teamUnfollow(teamId: String, fanCount: Int) {
        log("team_unfollow", ["team_id": teamId, "fan_count": fanCount])
    }

    // MARK: Celebrations

    /// Did the user tap the celebration while it was up? Just the yes/no signal.
    static func celebrationTap(tapped: Bool) {
        log("celebration_tap", ["tapped": tapped ? "yes" : "no"])
    }

    // MARK: Settings

    /// A boolean setting was flipped. Also mirrored to a user property so the
    /// *current* state of every install is segmentable, not just the changes.
    static func settingChanged(key: String, enabled: Bool) {
        log("setting_changed", ["key": key, "enabled": enabled ? "yes" : "no"])
        setUserProperty(enabled ? "on" : "off", forName: "pref_\(key)")
    }

    static func themeChanged(_ value: String) {
        log("setting_changed", ["key": "theme", "value": value])
        setUserProperty(value, forName: "pref_theme")
    }

    // MARK: Dev clock-walk verification

    /// Fired only by the Debug demo's `runClockLabelWalk` when the rendered
    /// clock label doesn't match that step's expectation. No-ops against real
    /// Firebase like every other event in a Debug (`DEV_BACKEND`) build — see
    /// the type doc — but still surfaces via the `AppLog.debug` fallback in
    /// `log(_:_:)` so a mismatch is visible without a separate log call.
    static func clockWalkMismatch(raw: String, shown: String, expect: String) {
        log("clock_walk_mismatch", ["raw": raw, "shown": shown, "expect": expect])
    }

    /// Push the current settings up as user properties (called at launch) so an
    /// install that never opens Settings is still counted in "% with confetti on".
    static func syncSettingProperties(_ s: PrefSettings) {
        setUserProperty((s.launchAtLogin ?? true) ? "on" : "off", forName: "pref_launch_at_login")
        setUserProperty((s.goalCenter ?? true) ? "on" : "off", forName: "pref_goal_center")
        setUserProperty((s.confetti ?? true) ? "on" : "off", forName: "pref_confetti")
        setUserProperty((s.confettiSound ?? true) ? "on" : "off", forName: "pref_confetti_sound")
        setUserProperty((s.theme ?? .system).rawValue, forName: "pref_theme")
    }

    // MARK: Plumbing

    private static func setUserProperty(_ value: String?, forName name: String) {
        #if !DEV_BACKEND
        guard FirebaseConfigured.isConfigured else { return }
        Analytics.setUserProperty(value, forName: name)
        #endif
    }

    private static func setDefaultEventParameters(_ parameters: [String: Any]) {
        #if !DEV_BACKEND
        guard FirebaseConfigured.isConfigured else { return }
        Analytics.setDefaultEventParameters(parameters)
        #endif
    }

    private static func log(_ name: String, _ parameters: [String: Any]) {
        #if !DEV_BACKEND
        guard FirebaseConfigured.isConfigured else { return }
        Analytics.logEvent(name, parameters: parameters)
        #endif
        AppLog.debug(.app, "analytics_event name=\(name) params=\(parameters)")
    }
}
