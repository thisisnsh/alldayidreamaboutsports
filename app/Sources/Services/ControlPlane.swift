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
private let defaultCelebrationSamplePercent: Double = 1.0
private let defaultMaxFanTeams = 10
private let defaultEventStaleMinutes = 3

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
    @Published var celebrationEnabled = true
    @Published var animationParams = AnimationParams()
    /// Live poll interval in seconds (≈5). Drives LiveStore's loop.
    @Published var pollSeconds: Double = 5
    /// Probability [0,1] a client reports its real celebration taps. 1.0 =
    /// everyone reports (exact); lower samples, and the server multiplies back.
    @Published var celebrationSamplePercent: Double = 1.0
    /// Max number of teams a user can be a fan of. Config-driven so we can raise
    /// it without shipping a build; starts at 10.
    @Published var maxFanTeams: Int = 10
    /// Out-of-order staleness tolerance (minutes). A VAR event whose incident
    /// minute is more than this behind the greatest minute we've ALREADY notified
    /// for a fixture is a late/backfilled "past" decision (api-football injects it
    /// minutes after the fact) and is suppressed. Config-driven so we can tune it
    /// without shipping a build. See EventRouter's staleness guard.
    @Published var eventStaleMinutes: Int = 3

    private var remoteConfig: RemoteConfig?
    private var firebaseKillSwitch = false
    private var firebaseUpdateRequired = false
    private var firebaseUpdateAvailable = false
    private var firebaseKillMessage = ""
    private var firebasePollSeconds = defaultPollSeconds
    private var firebaseCelebrationSamplePercent = defaultCelebrationSamplePercent
    private var firebaseMaxFanTeams = defaultMaxFanTeams
    private var firebaseEventStaleMinutes = defaultEventStaleMinutes

    func start() {
        if FirebaseConfigured.isConfigured {
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
                "celebration_enabled": true as NSNumber,
                "animation_params": #"{"pillHoldSeconds":7,"notchStackMax":5}"# as NSString,
                "poll_seconds": 5 as NSNumber,
                "celebration_sample_percent": 1.0 as NSNumber,
                "max_fan_teams": defaultMaxFanTeams as NSNumber,
                "event_stale_minutes": defaultEventStaleMinutes as NSNumber,
            ])
            // Apply the last activated values before session bootstrap can let
            // a previously-killed install make authenticated requests.
            apply(rc)
            rc.fetchAndActivate { [weak self] _, _ in
                Task { @MainActor in
                    AppLog.info(.remoteConfig, "initial_fetch_complete")
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
        celebrationEnabled = rc["celebration_enabled"].boolValue
        let secs = rc["poll_seconds"].numberValue.doubleValue
        firebasePollSeconds = secs >= 1 ? secs : defaultPollSeconds
        let sample = rc["celebration_sample_percent"].numberValue.doubleValue
        firebaseCelebrationSamplePercent = (sample > 0 && sample <= 1) ? sample : defaultCelebrationSamplePercent
        let maxFans = rc["max_fan_teams"].numberValue.intValue
        firebaseMaxFanTeams = maxFans >= 1 ? maxFans : defaultMaxFanTeams
        let staleMins = rc["event_stale_minutes"].numberValue.intValue
        firebaseEventStaleMinutes = staleMins >= 0 ? staleMins : defaultEventStaleMinutes
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
        AppLog.info(.remoteConfig, "firebase_state_applied kill_switch=\(firebaseKillSwitch) update_required=\(firebaseUpdateRequired) update_available=\(firebaseUpdateAvailable) celebration_enabled=\(celebrationEnabled) poll_seconds=\(firebasePollSeconds) celebration_sample=\(firebaseCelebrationSamplePercent) max_fan_teams=\(firebaseMaxFanTeams) event_stale_minutes=\(firebaseEventStaleMinutes)")
    }

    private func applyEffectiveState() {
        let wasKilled = killSwitch
        let wasUpdateRequired = updateRequired
        killSwitch = firebaseKillSwitch
        updateRequired = firebaseUpdateRequired
        updateAvailable = firebaseUpdateAvailable
        killMessage = firebaseKillMessage
        pollSeconds = firebasePollSeconds
        celebrationSamplePercent = firebaseCelebrationSamplePercent
        maxFanTeams = firebaseMaxFanTeams
        eventStaleMinutes = firebaseEventStaleMinutes

        if killSwitch {
            OverlayManager.shared.dismissAll()
            if !wasKilled || AppSession.shared.isSignedIn {
                AppSession.shared.clearSession(showLogin: false)
            }
            closeUtilityWindows()
            return
        }
        if updateRequired {
            OverlayManager.shared.dismissAll()
            if !wasUpdateRequired || AppSession.shared.isSignedIn {
                AppSession.shared.clearSession(showLogin: false)
            }
            closeUtilityWindows()
            return
        } else {
            if wasKilled || wasUpdateRequired {
                AppSession.shared.signInError = nil
            }
        }
        // A lowered max_fan_teams must shrink an already-too-long fan list, not
        // just block future adds. Operational path only (kill/update return above).
        AppSession.shared.enforceFanTeamCap()
        MenuPopoverController.shared.controlPlaneDidChange()
    }

    var isOperational: Bool { !killSwitch && !updateRequired }

    /// Real-time Remote Config is primary; this also gives a menu open an
    /// immediate recovery path after connectivity or sleep interruptions.
    func refreshRemoteConfig(ignoreCache: Bool = false) {
        guard let rc = remoteConfig else { return }
        let completion: (RemoteConfigFetchAndActivateStatus, Error?) -> Void = { [weak self] _, error in
            if let error {
                AppLog.error(.remoteConfig, "refresh_failed", error: error)
                return
            }
            AppLog.info(.remoteConfig, "refresh_complete ignore_cache=false")
            Task { @MainActor in self?.apply(rc) }
        }
        if ignoreCache {
            rc.fetch(withExpirationDuration: 0) { [weak self] _, error in
                if let error {
                    AppLog.error(.remoteConfig, "refresh_failed ignore_cache=true", error: error)
                    return
                }
                rc.activate { _, error in
                    if let error {
                        AppLog.error(.remoteConfig, "activation_failed", error: error)
                        return
                    }
                    AppLog.info(.remoteConfig, "refresh_complete ignore_cache=true")
                    Task { @MainActor in self?.apply(rc) }
                }
            }
        } else {
            rc.fetchAndActivate(completionHandler: completion)
        }
    }

    /// For app termination only.
    func stop() {
        remoteConfig = nil
    }
}
