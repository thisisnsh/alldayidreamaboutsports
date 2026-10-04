import Foundation

struct AppPrefs: Equatable {
    var fanTeamIds: [String]
    var settings: PrefSettings

    static var empty: AppPrefs {
        AppPrefs(fanTeamIds: [], settings: PrefSettings())
    }
}

struct PrefSettings: Codable, Equatable {
    var launchAtLogin: Bool?
    var theme: ThemeChoice?
    /// Per-event-type switches for the notch pills; missing key = enabled.
    var notifications: [String: Bool]?
    /// The ball + scoreboard centerpiece on fan-team goals; off = fan goals
    /// use the notch pill like every other event.
    var goalCenter: Bool?
    /// Confetti burst on fan-team goals (with either style).
    var confetti: Bool?
    /// Size of pinned score capsules (fonts + logos). nil = medium.
    var capsuleSize: CapsuleSize?
    /// Vertical screen edge for pinned capsules. nil = top.
    var capsulePosition: CapsulePosition?
    /// Size of the notch-drop event pills (fonts + padding). nil = medium.
    var notchDropSize: CapsuleSize?
}

