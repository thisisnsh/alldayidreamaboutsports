import FirebaseRemoteConfig
import Foundation
import SwiftUI

struct AnimationParams: Codable {
    var ballDropSeconds: Double = 1.5
    var tapWindowSeconds: Double = 5
    var countHoldSeconds: Double = 4
    var pillHoldSeconds: Double = 5
    var maxQueuedAnimations: Int = 3
}

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
    /// How many teams a user can follow — remote-tunable, fetched at app
    /// start alongside the rest of the config.
    @Published var maxFanTeams = 10

    var pollingIntervalSeconds: Double = 30

    private var backupTimer: Timer?

    func start() {
        if FirebaseConfigured.isConfigured {
            let rc = RemoteConfig.remoteConfig()
            let settings = RemoteConfigSettings()
            settings.minimumFetchInterval = 1800
            rc.configSettings = settings
            rc.fetchAndActivate { [weak self] _, _ in
                Task { @MainActor in self?.apply(rc) }
            }
            rc.addOnConfigUpdateListener { [weak self] _, error in
                guard error == nil else { return }
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
        killSwitch = rc["kill_switch"].boolValue
        killMessage = rc["kill_message"].stringValue
        celebrationEnabled = rc["celebration_enabled"].boolValue
        let minBuild = rc["min_build"].numberValue.intValue
        if minBuild > 0 {
            updateRequired = AppEnvironment.buildNumber < minBuild
        }
        if rc["polling_interval_s"].numberValue.doubleValue > 0 {
            pollingIntervalSeconds = rc["polling_interval_s"].numberValue.doubleValue
        }
        if rc["max_fan_teams"].numberValue.intValue > 0 {
            maxFanTeams = rc["max_fan_teams"].numberValue.intValue
        }
        if let data = rc["animation_params"].stringValue.data(using: .utf8),
           let params = try? JSONDecoder().decode(AnimationParams.self, from: data) {
            animationParams = params
        }
        reactToState()
    }

    private func checkBackupConfig() async {
        guard let config = try? await Services.scores.fetchBackupConfig() else { return }
        if let kill = config.killSwitch, kill {
            killSwitch = true
            killMessage = config.message ?? killMessage
        }
        if let minBuild = config.minBuild, AppEnvironment.buildNumber < minBuild {
            updateRequired = true
        }
        if let max = config.maxFanTeams, max > 0 {
            maxFanTeams = max
        }
        reactToState()
    }

    private func reactToState() {
        if killSwitch || updateRequired {
            OverlayManager.shared.dismissAll()
            openWindow(WindowID.gate)
        }
    }

    var isOperational: Bool { !killSwitch && !updateRequired }
}
