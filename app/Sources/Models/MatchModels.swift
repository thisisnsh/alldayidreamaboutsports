import Foundation

enum MatchEventType: String, Codable, CaseIterable {
    case kickoff = "KICKOFF"
    case goal = "GOAL"
    case goalCancelled = "GOAL_CANCELLED"
    case yellowCard = "YELLOW_CARD"
    case redCard = "RED_CARD"
    case halfTime = "HALF_TIME"
    case fullTime = "FULL_TIME"
    case extraTime = "EXTRA_TIME"
    case penaltyShootout = "PENALTY_SHOOTOUT"
    case penaltyKick = "PENALTY_KICK"
    // Local-only: the post-goal celebration count pill. Never arrives as a
    // backend match_event; exists so Settings → Events can toggle it.
    case celebration = "CELEBRATION"
}

struct MatchEvent: Identifiable {
    let eventId: String
    let type: MatchEventType
    let fixtureId: Int
    let leagueId: Int
    let teamId: Int?
    let player: String?
    let minute: Int?
    let homeTeamId: Int
    let awayTeamId: Int
    let homeName: String
    let awayName: String
    let homeGoals: Int
    let awayGoals: Int
    /// Penalty-shootout tally, present on shootout/full-time events.
    let penHome: Int?
    let penAway: Int?
    /// Whether a penalty kick was converted (PENALTY_KICK only).
    let scored: Bool?

    var id: String { eventId }

    /// Decodes the all-strings FCM data payload published by the backend.
    init?(fcmData: [String: Any]) {
        guard
            let eventId = fcmData["eventId"] as? String,
            let typeRaw = fcmData["type"] as? String,
            let type = MatchEventType(rawValue: typeRaw),
            let fixtureId = Int(fcmData["fixtureId"] as? String ?? ""),
            let homeTeamId = Int(fcmData["homeTeamId"] as? String ?? ""),
            let awayTeamId = Int(fcmData["awayTeamId"] as? String ?? "")
        else { return nil }
        self.eventId = eventId
        self.type = type
        self.fixtureId = fixtureId
        self.leagueId = Int(fcmData["leagueId"] as? String ?? "") ?? 1
        let team = fcmData["teamId"] as? String
        self.teamId = (team?.isEmpty ?? true) ? nil : Int(team ?? "")
        let player = fcmData["player"] as? String
        self.player = (player?.isEmpty ?? true) ? nil : player
        self.minute = Int(fcmData["minute"] as? String ?? "")
        self.homeName = fcmData["homeName"] as? String ?? String(homeTeamId)
        self.awayName = fcmData["awayName"] as? String ?? String(awayTeamId)
        self.homeTeamId = homeTeamId
        self.awayTeamId = awayTeamId
        self.homeGoals = Int(fcmData["homeGoals"] as? String ?? "") ?? 0
        self.awayGoals = Int(fcmData["awayGoals"] as? String ?? "") ?? 0
        self.penHome = Int(fcmData["penHome"] as? String ?? "")
        self.penAway = Int(fcmData["penAway"] as? String ?? "")
        self.scored = (fcmData["scored"] as? String).flatMap {
            $0.isEmpty ? nil : ($0 == "true")
        }
    }
}

// fixtures-{date}.json payloads (backend MatchState shape).

struct ScoreboardTeam: Codable, Hashable {
    let id: Int
    let name: String
    let goals: Int
}

/// Penalty-shootout result on a fixture (backend MatchState.shootout). Only
/// the running counts matter to the scoreboard; the kick list is unused here.
struct Shootout: Codable, Hashable {
    let home: Int
    let away: Int
}

struct Fixture: Codable, Identifiable, Hashable {
    let fixtureId: Int
    let leagueId: Int
    let round: String?
    let kickoffISO: String
    let status: String // SCHEDULED | LIVE | HALF_TIME | FINISHED | OTHER
    let minute: Int?
    let home: ScoreboardTeam
    let away: ScoreboardTeam
    let shootout: Shootout?

    var id: Int { fixtureId }
    var isLive: Bool { status == "LIVE" || status == "HALF_TIME" }
    var kickoff: Date? { ISO8601DateFormatter().date(from: kickoffISO) }

    /// Competition stage from API-Football's `league.round`.
    /// "Group A - 1" → "Group A · MD1"; knockout rounds ("Round of 16",
    /// "Final", …) pass through unchanged. nil when the round is absent.
    var stageLabel: String? {
        guard let round, !round.isEmpty else { return nil }
        let parts = round.components(separatedBy: " - ")
        if parts.count == 2, parts[0].hasPrefix("Group"), Int(parts[1]) != nil {
            return "\(parts[0]) · MD\(parts[1])"
        }
        return round
    }

    /// FIFA.com match page (the official destination for details).
    var fifaURL: URL {
        URL(string: "https://www.fifa.com/en/tournaments/mens/worldcup/canadamexicousa2026/scores-fixtures")!
    }

    func involves(_ ids: Set<Int>) -> Bool {
        ids.contains(home.id) || ids.contains(away.id)
    }
}

struct FixturesPayload: Codable {
    let generatedAt: String
    let matches: [Fixture]
}

struct CelebrationTotals: Codable {
    let totals: [String: Int]
}
