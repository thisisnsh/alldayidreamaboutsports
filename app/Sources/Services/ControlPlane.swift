import FirebaseRemoteConfig
import Foundation
import SwiftUI

struct AnimationParams: Codable {
    /// How long each notification set (and the ball with it) stays on screen.
    var pillHoldSeconds: Double = 7
    /// Notification set size — how many pills display at once.
    var notchStackMax: Int = 5
}

private let defaultAnimationParams = AnimationParams()
private let defaultPollSeconds: Double = 5
private let defaultMaxFanTeams = 10
private let defaultEventStaleMinutes = 3
/// Bootstrap cadence for the periodic Remote Config fetch, used until the
/// template supplies its own value. It never delays startup — the initial fetch
/// still goes out immediately; this only schedules the *next* one while that
/// request is in flight or after it fails.
private let defaultRemoteConfigFetchSeconds: Double = 300
/// Safety range for `remote_config_fetch_interval_seconds`. Below the floor an
/// accidental edit becomes a tight billing loop; above the ceiling refreshes are
/// effectively off. Anything outside falls back to the 300s default.
private let minRemoteConfigFetchSeconds: Double = 60
private let maxRemoteConfigFetchSeconds: Double = 86_400

/// Kill switch + forced updates + remote tunables, via Firebase Remote Config
/// with real-time listeners (seconds to propagate).
@MainActor
final class ControlPlane: ObservableObject {
    static let shared = ControlPlane()

    @Published var killSwitch = false
    @Published var killMessage = ""
    @Published var updateRequired = false
    /// A newer build exists (below `latest_build`) but this one still works —
    /// a soft nudge, not the forced `updateRequired` block. Drives the
    /// "Update available" banner atop the menu.
    @Published var updateAvailable = false
    @Published var animationParams = AnimationParams()
    /// Live poll interval in seconds (≈5). Drives LiveStore's loop.
    @Published var pollSeconds: Double = 5
    /// Max number of teams a user can be a fan of. Config-driven so we can raise
    /// it without shipping a build; starts at 10.
    @Published var maxFanTeams: Int = 10
    /// Out-of-order staleness tolerance (minutes). A VAR event whose incident
    /// minute is more than this behind the greatest minute we've ALREADY notified
    /// for a fixture is a late/backfilled "past" decision (api-football injects it
    /// minutes after the fact) and is suppressed. Config-driven so we can tune it
    /// without shipping a build. See EventRouter's staleness guard.
    @Published var eventStaleMinutes: Int = 3
    /// Effective interval between periodic forced Remote Config fetches. The
    /// app-wide loop below is the only periodic owner — the menu has none.
    @Published private(set) var remoteConfigFetchSeconds: Double = defaultRemoteConfigFetchSeconds

    private var remoteConfig: RemoteConfig?
    /// The single periodic-fetch loop. Restarted only when the effective
    /// interval actually changes, cancelled on `stop()`.
    private var periodicFetchTask: Task<Void, Never>?
    /// Interval the running `periodicFetchTask` is sleeping on.
    private var periodicFetchInterval: Double?
    /// One Remote Config network request at a time: a periodic fetch and a
    /// foreground recovery fetch landing together would bill twice for the same
    /// template.
    private var fetchInFlight = false
    private var firebaseKillSwitch = false
    private var firebaseUpdateRequired = false
    private var firebaseUpdateAvailable = false
    private var firebaseKillMessage = ""
    private var firebasePollSeconds = defaultPollSeconds
    private var firebaseMaxFanTeams = defaultMaxFanTeams
    private var firebaseEventStaleMinutes = defaultEventStaleMinutes
    private var firebaseRemoteConfigFetchSeconds = defaultRemoteConfigFetchSeconds

    func start() {
        if FirebaseConfigured.isConfigured {
            // Idempotent: a second start must not add a second listener or a
            // second periodic task.
            guard remoteConfig == nil else { return }
            let rc = RemoteConfig.remoteConfig()
            remoteConfig = rc
            let settings = RemoteConfigSettings()
            // This is an operational control plane, not ordinary product config.
            // Keep launch-time fetches fresh even if the real-time connection
            // missed an update while the app was asleep or offline.
            settings.minimumFetchInterval = 60
            rc.configSettings = settings
            rc.setDefaults([
                "kill_switch": false as NSNumber,
                "kill_message": "" as NSString,
                "min_build": 1 as NSNumber,
                "latest_build": 0 as NSNumber,
                "animation_params": #"{"pillHoldSeconds":7,"notchStackMax":5}"# as NSString,
                "poll_seconds": 5 as NSNumber,
                "max_fan_teams": defaultMaxFanTeams as NSNumber,
                "event_stale_minutes": defaultEventStaleMinutes as NSNumber,
                "remote_config_fetch_interval_seconds": defaultRemoteConfigFetchSeconds as NSNumber,
            ])
            // Apply the last activated values before session bootstrap can let
            // a previously-killed install make authenticated requests. This also
            // starts the periodic loop on the bootstrap cadence; the fetch below
            // (or a real-time update) reschedules it if the template disagrees.
            apply(rc)
            fetchInFlight = true
            rc.fetchAndActivate { [weak self] _, error in
                Task { @MainActor in
                    AppLog.info(.remoteConfig, "initial_fetch_complete")
                    if let error {
                        AppAnalytics.remoteConfigFetchFailed(stage: "initial", error: error)
                    }
                    self?.fetchInFlight = false
                    self?.apply(rc)
                }
            }
            rc.addOnConfigUpdateListener { [weak self] _, error in
                if let error {
                    AppLog.error(.remoteConfig, "listener_failed", error: error)
                    return
                }
                AppLog.info(.remoteConfig, "listener_update_received")
                rc.activate { _, _ in
                    Task { @MainActor in self?.apply(rc) }
                }
            }
        }
    }

    private func apply(_ rc: RemoteConfig) {
        firebaseKillSwitch = rc["kill_switch"].boolValue
        firebaseKillMessage = rc["kill_message"].stringValue
        let secs = rc["poll_seconds"].numberValue.doubleValue
        firebasePollSeconds = secs >= 1 ? secs : defaultPollSeconds
        let maxFans = rc["max_fan_teams"].numberValue.intValue
        firebaseMaxFanTeams = maxFans >= 1 ? maxFans : defaultMaxFanTeams
        let staleMins = rc["event_stale_minutes"].numberValue.intValue
        firebaseEventStaleMinutes = staleMins >= 0 ? staleMins : defaultEventStaleMinutes
        // Missing/malformed values arrive as 0 here, so the range check covers
        // them alongside non-finite and out-of-range edits.
        let fetchSecs = rc["remote_config_fetch_interval_seconds"].numberValue.doubleValue
        let fetchSecsValid = fetchSecs.isFinite
            && fetchSecs >= minRemoteConfigFetchSeconds
            && fetchSecs <= maxRemoteConfigFetchSeconds
        firebaseRemoteConfigFetchSeconds = fetchSecsValid ? fetchSecs : defaultRemoteConfigFetchSeconds
        let minBuild = rc["min_build"].numberValue.intValue
        firebaseUpdateRequired = minBuild > 0 && AppEnvironment.buildNumber < minBuild
        let latestBuild = rc["latest_build"].numberValue.intValue
        firebaseUpdateAvailable = latestBuild > 0 && AppEnvironment.buildNumber < latestBuild
        if let data = rc["animation_params"].stringValue.data(using: .utf8),
           let params = try? JSONDecoder().decode(AnimationParams.self, from: data) {
            animationParams = params
        } else {
            animationParams = defaultAnimationParams
        }
        applyEffectiveState()
        AppLog.info(.remoteConfig, "firebase_state_applied kill_switch=\(firebaseKillSwitch) update_required=\(firebaseUpdateRequired) update_available=\(firebaseUpdateAvailable) poll_seconds=\(firebasePollSeconds) max_fan_teams=\(firebaseMaxFanTeams) event_stale_minutes=\(firebaseEventStaleMinutes) rc_fetch_seconds=\(firebaseRemoteConfigFetchSeconds)")
    }

    private func applyEffectiveState() {
        let wasKilled = killSwitch
        let wasUpdateRequired = updateRequired
        killSwitch = firebaseKillSwitch
        updateRequired = firebaseUpdateRequired
        updateAvailable = firebaseUpdateAvailable
        killMessage = firebaseKillMessage
        pollSeconds = firebasePollSeconds
        maxFanTeams = firebaseMaxFanTeams
        eventStaleMinutes = firebaseEventStaleMinutes
        remoteConfigFetchSeconds = firebaseRemoteConfigFetchSeconds
        // Ahead of the kill/update returns below: a killed or blocked install
        // still has to keep fetching to hear that it has been recovered.
        schedulePeriodicFetch(interval: remoteConfigFetchSeconds)

        if killSwitch {
            // On the transition INTO the gate, not on every config apply — the
            // template is re-applied on every fetch and every listener update.
            if !wasKilled { AppAnalytics.controlPlaneGate("kill_switch") }
            OverlayManager.shared.dismissAll()
            if !wasKilled {
                AppSession.shared.suspendForGate()
            }
            closeUtilityWindows()
            return
        }
        if updateRequired {
            if !wasUpdateRequired { AppAnalytics.controlPlaneGate("update_required") }
            OverlayManager.shared.dismissAll()
            if !wasUpdateRequired {
                AppSession.shared.suspendForGate()
            }
            closeUtilityWindows()
            return
        }
        // A lowered max_fan_teams must shrink an already-too-long fan list, not
        // just block future adds. Operational path only (kill/update return above).
        AppSession.shared.enforceFanTeamCap()
        MenuPopoverController.shared.controlPlaneDidChange()
    }

    var isOperational: Bool { !killSwitch && !updateRequired }

    /// The app-wide periodic fetch. Real-time updates are primary, but a socket
    /// that died while the machine slept goes unnoticed, so we also force a
    /// fetch on this cadence. Idempotent — re-scheduling the interval already
    /// running leaves the current sleep alone; a changed interval cancels the
    /// sleep and starts over on the new one.
    private func schedulePeriodicFetch(interval: Double) {
        guard periodicFetchTask == nil || periodicFetchInterval != interval else { return }
        periodicFetchTask?.cancel()
        periodicFetchInterval = interval
        AppLog.info(.remoteConfig, "periodic_fetch_scheduled interval_seconds=\(interval)")
        periodicFetchTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    return // cancelled mid-sleep: no last fetch on the way out
                }
                guard !Task.isCancelled, let self else { return }
                AppLog.info(.remoteConfig, "periodic_fetch_start interval_seconds=\(interval)")
                self.refreshRemoteConfig(ignoreCache: true, stage: "periodic")
            }
        }
    }

    /// Real-time Remote Config is primary; this also gives launch, foreground
    /// recovery and the periodic loop an immediate fetch path after
    /// connectivity or sleep interruptions.
    /// `stage` only labels the analytics: `periodic` for the loop above,
    /// `refresh` for the launch / foreground-recovery calls.
    func refreshRemoteConfig(ignoreCache: Bool = false, stage: String = "refresh") {
        guard let rc = remoteConfig else { return }
        // A periodic fetch and a foreground recovery fetch can land together —
        // one request in flight is enough, and dropping the duplicate keeps the
        // billable fetch count at the configured cadence.
        guard !fetchInFlight else {
            AppLog.info(.remoteConfig, "refresh_skipped reason=fetch_in_flight")
            return
        }
        fetchInFlight = true
        let finish: (Bool) -> Void = { [weak self] applyValues in
            Task { @MainActor in
                self?.fetchInFlight = false
                if applyValues { self?.apply(rc) }
            }
        }
        if ignoreCache {
            rc.fetch(withExpirationDuration: 0) { _, error in
                if let error {
                    AppLog.error(.remoteConfig, "refresh_failed ignore_cache=true", error: error)
                    Task { @MainActor in AppAnalytics.remoteConfigFetchFailed(stage: stage, error: error) }
                    finish(false)
                    return
                }
                rc.activate { _, error in
                    if let error {
                        AppLog.error(.remoteConfig, "activation_failed", error: error)
                        Task { @MainActor in AppAnalytics.remoteConfigFetchFailed(stage: stage, error: error) }
                        finish(false)
                        return
                    }
                    AppLog.info(.remoteConfig, "refresh_complete ignore_cache=true")
                    finish(true)
                }
            }
        } else {
            rc.fetchAndActivate { _, error in
                if let error {
                    AppLog.error(.remoteConfig, "refresh_failed", error: error)
                    Task { @MainActor in AppAnalytics.remoteConfigFetchFailed(stage: stage, error: error) }
                    finish(false)
                    return
                }
                AppLog.info(.remoteConfig, "refresh_complete ignore_cache=false")
                finish(true)
            }
        }
    }

    /// For app termination only.
    func stop() {
        periodicFetchTask?.cancel()
        periodicFetchTask = nil
        periodicFetchInterval = nil
        fetchInFlight = false
        remoteConfig = nil
    }
}
