import Foundation
#if !DEV_BACKEND
import FirebaseAnalytics
#endif

/// Anonymous product analytics via Firebase Analytics (free, unlimited, and
/// anonymous — it identifies an *app instance* by a random id; the app has no
/// accounts). App version, OS version, device model, first_open and
/// session counts are collected automatically; this layer adds the product, UI
/// and pipeline events we actually want to learn from (do people follow teams?
/// do they tap celebrations? which settings do they toggle? did the goal reach
/// the screen?).
///
/// ANONYMITY IS THE CONTRACT: `Analytics.setUserID` is deliberately never
/// called, and no event carries a team or player name, or an error's `localizedDescription` (which can carry a URL with a
/// token in it). Identity in this file is numeric ids and coarse labels only —
/// if you are about to add anything else, that is the line you are crossing.
///
/// No-ops in Debug (`DEV_BACKEND`) builds and whenever Firebase isn't configured,
/// so local UI work never pollutes the data. Staging + Release both report — to
/// watch staging events live, launch with the `-FIRDebugEnabled` argument and
/// open Firebase → Analytics → DebugView.
///
/// NOTHING HERE FIRES ON A POLL TICK. The live loop re-reads every followed
/// match every 5 seconds for the length of a game; every pipeline event
/// below is gated on something having actually happened (a diff producing
/// events, a snapshot rejected, a set displayed, a fetch failing), so a quiet
/// match emits nothing at all.
@MainActor
enum AppAnalytics {
    // The two reserved names/parameters we use come from FirebaseAnalytics,
    // which a Debug build doesn't link — the literals are the same strings.
    #if DEV_BACKEND
    private static let appOpenEvent = "app_open"
    private static let screenViewEvent = "screen_view"
    private static let screenNameParameter = "screen_name"
    #else
    private static let appOpenEvent = AnalyticsEventAppOpen
    private static let screenViewEvent = AnalyticsEventScreenView
    private static let screenNameParameter = AnalyticsParameterScreenName
    #endif

    // MARK: App metadata

    /// Firebase collects its own app version automatically, but this publishes
    /// the exact marketing.build value we use for releases.
    static func configureAppMetadata() {
        let version = AppEnvironment.fullAppVersion
        setUserProperty(version, forName: "app_version_full")
        setDefaultEventParameters(["app_version_full": version])
    }

    // MARK: UI primitives

    /// Fired once per launch from `applicationDidFinishLaunching`, immediately
    /// after `FirebaseApp.configure()`.
    static func appOpen() {
        log(appOpenEvent)
    }

    /// One per surface, from `.onAppear` (or, for the reused menu popover, from
    /// the controller that shows it).
    static func screenView(_ screen: String, _ parameters: [String: Any] = [:]) {
        log(screenViewEvent, parameters.merging([screenNameParameter: screen]) { _, name in name })
    }

    /// How long the menu popover stayed open — whether people read the board or
    /// bounce off it.
    static func menuClosed(openSeconds: Double) {
        log("menu_closed", ["open_seconds": Int(openSeconds.rounded())])
    }

    // MARK: Controls
    //
    // ONE EVENT PER QUESTION, named for what the user did — the shape
    // `team_follow` and `celebration_tap` already set. Not a single
    // `button_click` carrying a `button_name`: an event name shows up in the
    // console's Events list with its own count and can be marked a key event on
    // its own, whereas a parameter is invisible in every standard report until
    // it is registered as a custom dimension. At ~20 controls the 500-name
    // budget is nowhere near binding, so the reporting wins for free.
    //
    // A parameter appears only where the SAME action has several entry points
    // and both the total and the split are worth having — `app_quit`'s
    // `source`. A control whose click is
    // already reported by the thing it triggers gets no event of its own:
    // "Preview animation" is `celebration_preview`.

    /// The last onboarding step's "Show me". `fan_count` = teams followed by
    /// then; the step funnel itself is the `onboarding_*` screen views.
    static func onboardingCompleted(fanCount: Int) {
        log("onboarding_completed", ["fan_count": fanCount])
    }

    static func teamPickerOpened() {
        log("team_picker_opened")
    }

    static func settingsOpened() {
        log("settings_opened")
    }

    static func featureRequested() {
        log("feature_requested")
    }

    static func bugReported() {
        log("bug_reported")
    }

    /// A followed-team win hit the review cadence (1st, 7th, 13th, …) and we
    /// asked StoreKit — which may still decline to show the sheet.
    static func reviewRequested(wins: Int) {
        log("review_requested", ["wins": wins])
    }

    /// Every Quit in the app. `source` says which one: `settings` or
    /// `status_menu` (the status item's right-click menu).
    static func appQuit(source: String) {
        log("app_quit", ["source": source])
    }

    /// The menu's My Teams / All Teams switch.
    static func fixtureScopeChanged(_ value: String) {
        log("fixture_scope_changed", ["value": value])
    }

    // MARK: Capsules

    static func capsulePinned(fixtureId: Int) {
        log("capsule_pinned", ["fixture_id": fixtureId])
    }

    static func capsuleUnpinned(fixtureId: Int) {
        log("capsule_unpinned", ["fixture_id": fixtureId])
    }

    // MARK: Fan teams

    static func teamFollow(teamId: String, fanCount: Int) {
        log("team_follow", ["team_id": teamId, "fan_count": fanCount])
    }

    static func teamUnfollow(teamId: String, fanCount: Int) {
        log("team_unfollow", ["team_id": teamId, "fan_count": fanCount])
    }

    /// "Follow all" / "Unfollow all" on a league header. The per-team
    /// `team_follow` / `team_unfollow` events still fire; these are the marker
    /// that says they came from one bulk action rather than N taps.
    static func leagueFollowAll(leagueId: Int, count: Int) {
        log("league_follow_all", ["league_id": leagueId, "count": count])
    }

    static func leagueUnfollowAll(leagueId: Int, count: Int) {
        log("league_unfollow_all", ["league_id": leagueId, "count": count])
    }

    // MARK: Celebrations

    /// Did the user tap the celebration while it was up? Just the yes/no signal.
    static func celebrationTap(tapped: Bool) {
        log("celebration_tap", ["tapped": tapped ? "yes" : "no"])
    }

    /// A followed team scored and the celebration fired — the denominator the
    /// tap rate is measured against.
    static func celebrationShown() {
        log("celebration_shown", [:])
    }

    /// Settings → "Preview animation".
    static func celebrationPreview() {
        log("celebration_preview", [:])
    }

    // MARK: Settings
    //
    // One event per setting, for the same reason the controls above are
    // individual: "how many settings got changed" is a number nobody asks for,
    // while every real question — do people turn confetti off, does anyone move
    // the capsule to the bottom — is about ONE setting. A single
    // `setting_changed` made all of them one console row that says nothing
    // until you register `key` as a custom dimension.
    //
    // The per-event-type notification toggles are the deliberate exception
    // below: "which events do people mute" is a ranking across the thirteen,
    // and a ranking wants one table, not thirteen rows to hunt down.

    /// Every setting the app reports, and the two names it owns: the event
    /// (`setting_<key>_changed`) and the user property (`pref_<key>`). One case
    /// per setting, so the whole reportable settings surface is this list — and
    /// so the event and the property can never drift apart the way two loose
    /// string literals could. The shared `setting_` prefix sorts all of them
    /// together in the console's Events list.
    enum Setting: String {
        case launchAtLogin = "launch_at_login"
        case goalCenter = "goal_center"
        case confetti
        case theme
        case capsuleSize = "capsule_size"
        case capsulePosition = "capsule_position"
        case notchDropSize = "notch_drop_size"

        var event: String { "setting_\(rawValue)_changed" }
        var property: String { "pref_\(rawValue)" }
    }

    /// A boolean setting was flipped. Also mirrored to a user property so the
    /// *current* state of every install is segmentable, not just the changes.
    static func settingChanged(_ setting: Setting, enabled: Bool) {
        log(setting.event, ["enabled": enabled ? "yes" : "no"])
        setUserProperty(enabled ? "on" : "off", forName: setting.property)
    }

    /// The enum-valued twin of the above (theme, capsule size, …): the choice
    /// rides in `value` rather than a yes/no.
    static func settingChanged(_ setting: Setting, value: String) {
        log(setting.event, ["value": value])
        setUserProperty(value, forName: setting.property)
    }

    /// One of the thirteen per-event-type notification switches. Grouped on
    /// purpose — see the note above.
    static func eventTypeToggled(type: String, enabled: Bool) {
        log("setting_event_type_toggled", ["type": type, "enabled": enabled ? "yes" : "no"])
        setUserProperty(enabled ? "on" : "off", forName: "pref_event_\(type)")
    }

    /// The overlay display picker. The display *count* only — a display id is
    /// machine-specific and has no meaning off the user's Mac.
    static func overlayDisplayChanged(displayCount: Int) {
        log("setting_overlay_display_changed", ["display_count": displayCount])
    }

    /// Push the current settings up as user properties (called at launch) so an
    /// install that never opens Settings is still counted in "% with confetti on".
    static func syncSettingProperties(_ s: PrefSettings) {
        setUserProperty((s.launchAtLogin ?? false) ? "on" : "off", forName: Setting.launchAtLogin.property)
        setUserProperty((s.goalCenter ?? true) ? "on" : "off", forName: Setting.goalCenter.property)
        setUserProperty((s.confetti ?? true) ? "on" : "off", forName: Setting.confetti.property)
        setUserProperty((s.theme ?? .system).rawValue, forName: Setting.theme.property)
        setUserProperty((s.capsuleSize ?? .medium).rawValue, forName: Setting.capsuleSize.property)
        setUserProperty((s.capsulePosition ?? .top).rawValue, forName: Setting.capsulePosition.property)
        setUserProperty((s.notchDropSize ?? .medium).rawValue, forName: Setting.notchDropSize.property)
    }

    // MARK: Live-scores pipeline

    /// A fetch in the live pipeline failed. DEDUPED PER FIXTURE PER SESSION: a
    /// CDN outage fails on every tick, and one sustained failure would
    /// otherwise swamp every other event in the property.
    static func pollFailed(stage: String, fixtureId: Int, error: Error) {
        let key = "\(stage):\(fixtureId)"
        guard reportedPollFailures.insert(key).inserted else { return }
        log("poll_failed", ["stage": stage, "status": AppLog.errorLabel(error)])
    }

    private static var reportedPollFailures: Set<String> = []

    /// A diff produced events — once per state change, never per read.
    static func matchEventsEmitted(_ events: [MatchEvent]) {
        guard !events.isEmpty else { return }
        let types = Set(events.map(\.type.rawValue)).sorted().joined(separator: ",")
        log("match_events_emitted", ["count": events.count, "event_types": types])
    }

    /// A snapshot was thrown away rather than merged (the CDN-edge staleness
    /// branch). Near-zero on a healthy matchday, which is why it's worth watching.
    static func snapshotRejected(reason: String) {
        log("snapshot_rejected", ["reason": reason])
    }

    // MARK: Event routing

    /// A routed event never reached the screen. Together with `eventShown` this
    /// gives the whole denominator: what fraction of what the feed produced the
    /// user actually saw, and where the rest went.
    static func eventDropped(reason: String, type: String) {
        log("event_dropped", ["reason": reason, "type": type])
    }

    static func eventShown(type: String, presentation: String) {
        log("event_shown", ["type": type, "presentation": presentation])
    }

    // MARK: Overlay

    /// One per displayed set — the unit a user actually perceives.
    static func overlaySetShown(count: Int, hasFanGoal: Bool) {
        log("overlay_set_shown", ["count": count, "has_fan_goal": hasFanGoal ? "yes" : "no"])
    }

    /// `reason: user` when the ✕ ended the set, `timeout` when it aged out.
    static func overlayDismissed(reason: String) {
        log("overlay_dismissed", ["reason": reason])
    }

    // MARK: Dev demo controls

    /// Debug-only, like everything else in `Dev/` — never reaches real Firebase
    /// (see the type doc), but surfaces through the `AppLog.debug` fallback.
    static func demoRestart() {
        log("demo_restart")
    }

    static func demoPlayStop(action: String) {
        log("demo_play_stop", ["action": action])
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

    private static func log(_ name: String, _ parameters: [String: Any] = [:]) {
        #if !DEV_BACKEND
        if FirebaseConfigured.isConfigured {
            Analytics.logEvent(name, parameters: parameters.isEmpty ? nil : parameters)
        }
        #endif
        // Sorted so both the crash trail and the debug log read the same way
        // every time (dictionary order isn't stable).
        let rendered = parameters
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        let line = "analytics_event name=\(name)\(rendered.isEmpty ? "" : " \(rendered)")"
        // Mirror every event — product, UI and pipeline — into the Crashlytics
        // breadcrumb trail, so a crash report carries the last few things the
        // user did. Doing it here covers the whole event set for one call site.
        AppLog.breadcrumb(line)
        AppLog.debug(.app, line)
    }
}
