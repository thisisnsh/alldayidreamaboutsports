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
        autoRefreshEnabled = rc["auto_refresh_enabled"].boolValue
        let secs = rc["auto_refresh_seconds"].numberValue.doubleValue
        autoRefreshSeconds = secs >= 1 ? secs : 5
        let minBuild = rc["min_build"].numberValue.intValue
        if minBuild > 0 {
            updateRequired = AppEnvironment.buildNumber < minBuild
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
        if let enabled = config.autoRefreshEnabled { autoRefreshEnabled = enabled }
        if let secs = config.autoRefreshSeconds, secs >= 1 { autoRefreshSeconds = secs }
        reactToState()
    }

    private func reactToState() {
        guard killSwitch || updateRequired else { return }
        // Stop the app, don't just show the gate. ControlPlane keeps polling so
        // it can recover when the switch clears.
        OverlayManager.shared.dismissAll()
        AppSession.shared.stopAllActivity()
        if killSwitch { AppSession.shared.clearSession(showLogin: false) }
        openWindow(WindowID.gate)
    }

    var isOperational: Bool { !killSwitch && !updateRequired }

    /// For app termination only — the kill switch must keep polling to recover.
    func stop() {
        backupTimer?.invalidate()
        backupTimer = nil
    }
}
