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
    /// Goal confetti on fan-team goals (the scorer's crest + paper from
    /// the bottom corners). Off = fan goals use the notch pill like every
    /// other event. The key keeps its old "center" name so saved prefs carry over.
    var goalCenter: Bool?
    /// Size of pinned score capsules (fonts + logos). nil = medium.
    var capsuleSize: CapsuleSize?
    /// Size of the notch-drop event pills (fonts + padding). nil = medium.
    var notchDropSize: CapsuleSize?
    /// How long each set of notch alerts stays down. nil = medium.
    var alertDuration: OverlayDuration?
    /// How long goal confetti keeps bursting. nil = medium.
    var confettiDuration: OverlayDuration?
}

/// How long an overlay stays on screen: notch alerts and goal confetti each
/// get their own.
enum OverlayDuration: String, CaseIterable, Codable {
    case short, medium, long

    var label: String {
        switch self {
        case .short: "Short"
        case .medium: "Medium"
        case .long: "Long"
        }
    }

    /// Seconds a set of notch alerts stays down once the last one lands.
    var alertHoldSeconds: TimeInterval {
        switch self {
        case .short: 4
        case .medium: 7
        case .long: 12
        }
    }

    /// Confetti bursts per goal, a few seconds apart. One burst is a single
    /// physical throw, so longer confetti means more throws, not slower ones.
    var confettiWaves: Int {
        switch self {
        case .short: 1
        case .medium: 2
        case .long: 3
        }
    }
}


/// One-tap alert levels over the twelve per-event switches. A preset just
/// writes those switches; the switches stay the source of truth, so a mix
/// that matches no preset reads as "Custom".
enum AlertPreset: String, CaseIterable {
    case goals, keyMoments, everything

    var label: String {
        switch self {
        case .goals: "Goals only"
        case .keyMoments: "Key moments"
        case .everything: "Everything"
        }
    }

    var summary: String {
        switch self {
        case .goals: "Goals and disallowed goals only."
        case .keyMoments: "Goals, VAR, red cards, kickoff, breaks and full-time."
        case .everything: "Every event, including yellow cards and substitutions."
        }
    }

    var events: Set<MatchEventType> {
        switch self {
        case .goals: [.goal, .goalCancelled]
        case .keyMoments: [.kickoff, .goal, .goalCancelled, .varDecision, .redCard, .halfTime,
                           .extraTime, .penaltyShootout, .penaltyKick, .fullTime]
        case .everything: Set(MatchEventType.settingsOrder)
        }
    }

    /// The alert shown when the preset is picked: the loudest thing it adds
    /// over the preset below it, so each choice previews something different.
    var sampleEvent: MatchEventType {
        switch self {
        case .goals: .goal
        case .keyMoments: .redCard
        case .everything: .yellowCard
        }
    }

    func apply(to settings: inout PrefSettings) {
        var notifications = settings.notifications ?? [:]
        for type in MatchEventType.settingsOrder {
            notifications[type.settingsKey] = events.contains(type)
        }
        settings.notifications = notifications
    }

    static func matching(_ settings: PrefSettings) -> AlertPreset? {
        let enabled = Set(MatchEventType.settingsOrder.filter { settings.eventEnabled($0) })
        return allCases.first { $0.events == enabled }
    }
}
