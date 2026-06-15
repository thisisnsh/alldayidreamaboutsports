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
private let defaultAutoRefreshEnabled = false
private let defaultAutoRefreshSeconds: Double = 5

/// Kill switch + forced updates + remote tunables.
/// Primary: Firebase Remote Config with real-time listeners (seconds to
/// propagate). Backup: config.json on the scores CDN every 15 min, so the app
/// stays controllable even if Firebase itself is the outage.
@MainActor
final class ControlPlane: ObservableObject {
    static let shared = ControlPlane()

    @Published var killSwitch = false
    @Published var killMessage = ""
    @Published var updateRequired = false
    @Published var celebrationEnabled = true
    @Published var animationParams = AnimationParams()
    @Published var autoRefreshEnabled = false
    @Published var autoRefreshSeconds: Double = 5

    private var backupTimer: Timer?
    private var remoteConfig: RemoteConfig?
    private var firebaseKillSwitch = false
    private var backupKillSwitch = false
    private var firebaseUpdateRequired = false
    private var backupUpdateRequired = false
    private var firebaseKillMessage = ""
    private var backupKillMessage = ""
    private var firebaseAutoRefreshEnabled = defaultAutoRefreshEnabled
    private var firebaseAutoRefreshSeconds = defaultAutoRefreshSeconds
    private var backupAutoRefreshEnabled: Bool?
    private var backupAutoRefreshSeconds: Double?

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
                "auto_refresh_enabled": false as NSNumber,
                "auto_refresh_seconds": 5 as NSNumber,
            ])
            // Apply the last activated values before session bootstrap can let
            // a previously-killed install make authenticated requests.
            apply(rc)
            rc.fetchAndActivate { [weak self] _, _ in
                Task { @MainActor in self?.apply(rc) }
            }
            rc.addOnConfigUpdateListener { [weak self] _, error in
                if let error {
                    NSLog("Remote Config listener failed: %@", error.localizedDescription)
                    return
                }
                rc.activate { _, _ in
                    Task { @MainActor in self?.apply(rc) }
                }
            }
        }

        backupTimer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { _ in
            Task { @MainActor in await ControlPlane.shared.checkBackupConfig() }
        }
        Task { await checkBackupConfig() }
    }

    private func apply(_ rc: RemoteConfig) {
        firebaseKillSwitch = rc["kill_switch"].boolValue
        firebaseKillMessage = rc["kill_message"].stringValue
        celebrationEnabled = rc["celebration_enabled"].boolValue
        firebaseAutoRefreshEnabled = rc["auto_refresh_enabled"].boolValue
        let secs = rc["auto_refresh_seconds"].numberValue.doubleValue
        firebaseAutoRefreshSeconds = secs >= 1 ? secs : defaultAutoRefreshSeconds
        let minBuild = rc["min_build"].numberValue.intValue
        firebaseUpdateRequired = minBuild > 0 && AppEnvironment.buildNumber < minBuild
        if let data = rc["animation_params"].stringValue.data(using: .utf8),
           let params = try? JSONDecoder().decode(AnimationParams.self, from: data) {
            animationParams = params
        } else {
            animationParams = defaultAnimationParams
        }
        applyEffectiveState()
    }

    private func checkBackupConfig() async {
        guard let config = try? await Services.scores.fetchBackupConfig() else { return }
        backupKillSwitch = config.killSwitch ?? false
        backupKillMessage = config.message ?? ""
        let minBuild = config.minBuild ?? 0
        backupUpdateRequired = minBuild > 0 && AppEnvironment.buildNumber < minBuild
        backupAutoRefreshEnabled = config.autoRefreshEnabled
        backupAutoRefreshSeconds = config.autoRefreshSeconds.flatMap { $0 >= 1 ? $0 : nil }
        applyEffectiveState()
    }

    private func applyEffectiveState() {
        let wasKilled = killSwitch
        let wasUpdateRequired = updateRequired
        killSwitch = firebaseKillSwitch || backupKillSwitch
        updateRequired = firebaseUpdateRequired || backupUpdateRequired
        killMessage = backupKillSwitch && !backupKillMessage.isEmpty
            ? backupKillMessage
            : firebaseKillMessage
        autoRefreshEnabled = backupAutoRefreshEnabled ?? firebaseAutoRefreshEnabled
        autoRefreshSeconds = backupAutoRefreshSeconds ?? firebaseAutoRefreshSeconds

        if killSwitch {
            OverlayManager.shared.dismissAll()
            if !wasKilled || AppSession.shared.isSignedIn {
                AppSession.shared.clearSession(showLogin: false)
            }
            closeUtilityWindows()
            MenuPopoverController.shared.controlPlaneDidChange()
            return
        }
        if updateRequired {
            OverlayManager.shared.dismissAll()
            AppSession.shared.stopAllActivity()
            closeUtilityWindows(titles: ["Sign In", "Become a Fan", "Settings"])
            if !wasUpdateRequired || wasKilled {
                openWindow(WindowID.gate)
            }
        } else {
            closeUtilityWindows(titles: ["Update Required"])
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
                NSLog("Remote Config refresh failed: %@", error.localizedDescription)
                return
            }
            Task { @MainActor in self?.apply(rc) }
        }
        if ignoreCache {
            rc.fetch(withExpirationDuration: 0) { [weak self] _, error in
                if let error {
                    NSLog("Remote Config refresh failed: %@", error.localizedDescription)
                    return
                }
                rc.activate { _, error in
                    if let error {
                        NSLog("Remote Config activation failed: %@", error.localizedDescription)
                        return
                    }
                    Task { @MainActor in self?.apply(rc) }
                }
            }
        } else {
            rc.fetchAndActivate(completionHandler: completion)
        }
    }

    /// For app termination only — the kill switch must keep polling to recover.
    func stop() {
        backupTimer?.invalidate()
        backupTimer = nil
        remoteConfig = nil
    }
}
