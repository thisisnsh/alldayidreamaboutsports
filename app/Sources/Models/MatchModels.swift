import Foundation

enum MatchEventType: String, Codable, CaseIterable {
    case kickoff = "KICKOFF"
    case goal = "GOAL"
    case goalCancelled = "GOAL_CANCELLED"
    case yellowCard = "YELLOW_CARD"
    case redCard = "RED_CARD"
    case halfTime = "HALF_TIME"
    case fullTime = "FULL_TIME"
    case penaltyShootout = "PENALTY_SHOOTOUT"
}

struct MatchEvent: Identifiable {
    let eventId: String
    let type: MatchEventType
    let fixtureId: Int
    let leagueId: Int
    let teamCode: String?
    let player: String?
    let minute: Int?
    let homeTeam: String
    let awayTeam: String
    let homeName: String
    let awayName: String
    let homeGoals: Int
    let awayGoals: Int

    var id: String { eventId }

    /// Decodes the all-strings FCM data payload published by the backend.
    init?(fcmData: [String: Any]) {
        guard
            let eventId = fcmData["eventId"] as? String,
            let typeRaw = fcmData["type"] as? String,
            let type = MatchEventType(rawValue: typeRaw),
            let fixtureId = Int(fcmData["fixtureId"] as? String ?? ""),
            let homeTeam = fcmData["homeTeam"] as? String,
            let awayTeam = fcmData["awayTeam"] as? String
        else { return nil }
        self.eventId = eventId
        self.type = type
        self.fixtureId = fixtureId
        self.leagueId = Int(fcmData["leagueId"] as? String ?? "") ?? 1
        let team = fcmData["teamCode"] as? String
        self.teamCode = (team?.isEmpty ?? true) ? nil : team
        let player = fcmData["player"] as? String
        self.player = (player?.isEmpty ?? true) ? nil : player
        self.minute = Int(fcmData["minute"] as? String ?? "")
        self.homeName = fcmData["homeName"] as? String ?? homeTeam
        self.awayName = fcmData["awayName"] as? String ?? awayTeam
        self.homeTeam = homeTeam
        self.awayTeam = awayTeam
        self.homeGoals = Int(fcmData["homeGoals"] as? String ?? "") ?? 0
        self.awayGoals = Int(fcmData["awayGoals"] as? String ?? "") ?? 0
    }
}

// live.json / fixtures-{date}.json payloads (backend MatchState shape).

struct ScoreboardTeam: Codable, Hashable {
    let code: String
    let name: String
    let goals: Int
}

struct Fixture: Codable, Identifiable, Hashable {
    let fixtureId: Int
    let leagueId: Int
    let kickoffISO: String
    let status: String // SCHEDULED | LIVE | HALF_TIME | FINISHED | OTHER
    let minute: Int?
    let home: ScoreboardTeam
    let away: ScoreboardTeam

    var id: Int { fixtureId }
    var isLive: Bool { status == "LIVE" || status == "HALF_TIME" }
    var kickoff: Date? { ISO8601DateFormatter().date(from: kickoffISO) }

    /// FIFA.com match page (the official destination for details).
    var fifaURL: URL {
        URL(string: "https://www.fifa.com/en/tournaments/mens/worldcup/canadamexicousa2026/scores-fixtures")!
    }

    func involves(_ codes: Set<String>) -> Bool {
        codes.contains(home.code) || codes.contains(away.code)
    }
}

struct FixturesPayload: Codable {
    let generatedAt: String
    let matches: [Fixture]
}

struct CelebrationTotals: Codable {
    let totals: [String: Int]
}
