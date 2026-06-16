import FirebaseRemoteConfig
import Foundation
import SwiftUI

struct AnimationParams: Codable {
    var ballDropSeconds: Double = 1.5
    /// How long each notification set (and the ball with it) stays on screen.
    var pillHoldSeconds: Double = 7
    /// Notification set size — how many pills display at once.
    var notchStackMax: Int = 10
}

private let defaultAnimationParams = AnimationParams()
private let defaultPollSeconds: Double = 5
private let defaultCelebrationSamplePercent: Double = 1.0

/// Kill switch + forced updates + remote tunables, via Firebase Remote Config
/// with real-time listeners (seconds to propagate).
@MainActor
final class ControlPlane: ObservableObject {
    static let shared = ControlPlane()

    @Published var killSwitch = false
    @Published var killMessage = ""
    @Published var updateRequired = false
    @Published var celebrationEnabled = true
    @Published var animationParams = AnimationParams()
    /// Live poll interval in seconds (≈5). Drives LiveStore's loop.
    @Published var pollSeconds: Double = 5
    /// Probability [0,1] a client reports its real celebration taps. 1.0 =
    /// everyone reports (exact); lower samples, and the server multiplies back.
    @Published var celebrationSamplePercent: Double = 1.0

    private var remoteConfig: RemoteConfig?
    private var firebaseKillSwitch = false
    private var firebaseUpdateRequired = false
    private var firebaseKillMessage = ""
    private var firebasePollSeconds = defaultPollSeconds
    private var firebaseCelebrationSamplePercent = defaultCelebrationSamplePercent

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
                "celebration_enabled": true as NSNumber,
                "animation_params": #"{"ballDropSeconds":1.5,"pillHoldSeconds":7,"notchStackMax":10}"# as NSString,
                "poll_seconds": 5 as NSNumber,
                "celebration_sample_percent": 1.0 as NSNumber,
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
        let minBuild = rc["min_build"].numberValue.intValue
        firebaseUpdateRequired = minBuild > 0 && AppEnvironment.buildNumber < minBuild
        if let data = rc["animation_params"].stringValue.data(using: .utf8),
           let params = try? JSONDecoder().decode(AnimationParams.self, from: data) {
            animationParams = params
        } else {
            animationParams = defaultAnimationParams
        }
        applyEffectiveState()
        AppLog.info(.remoteConfig, "firebase_state_applied kill_switch=\(firebaseKillSwitch) update_required=\(firebaseUpdateRequired) celebration_enabled=\(celebrationEnabled) poll_seconds=\(firebasePollSeconds) celebration_sample=\(firebaseCelebrationSamplePercent)")
    }

    private func applyEffectiveState() {
        let wasKilled = killSwitch
        let wasUpdateRequired = updateRequired
        killSwitch = firebaseKillSwitch
        updateRequired = firebaseUpdateRequired
        killMessage = firebaseKillMessage
        pollSeconds = firebasePollSeconds
        celebrationSamplePercent = firebaseCelebrationSamplePercent

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
