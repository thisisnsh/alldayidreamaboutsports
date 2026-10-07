import Foundation

// This standalone target exercises the real models/diff engine without app
// services. Kickoff parsing is an unrelated dependency of Fixture's UI helpers.
extension ISO8601DateFormatter {
    static func parseKickoff(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }
}

@main
struct MatchSecurityTests {
    static let wire = """
    {"fixtureId":1,"leagueId":39,"kickoffISO":"2026-10-04T12:00:00Z","status":"LIVE","minute":1,"home":{"id":1,"name":"A","goals":0,"yellowCards":0,"redCards":0},"away":{"id":2,"name":"B","goals":0,"yellowCards":0,"redCards":0}}
    """

    static func fixture(goals: Int = 0, cards: Int = 0, minute: Int = 1,
                        status: String = "LIVE", rawStatus: String = "1H",
                        subs: [SubstitutionRecord] = [], shootout: Shootout? = nil) -> Fixture {
        Fixture(fixtureId: 1, leagueId: 39, round: nil, kickoffISO: "2026-10-04T12:00:00Z",
                status: status, rawStatus: rawStatus, minute: minute,
                home: ScoreboardTeam(id: 1, name: "A", goals: goals, yellowCards: cards, subs: subs),
                away: ScoreboardTeam(id: 2, name: "B", goals: 0), shootout: shootout)
    }

    static func rejects(_ change: (inout [String: Any]) -> Void) throws {
        var object = try JSONSerialization.jsonObject(with: Data(wire.utf8)) as! [String: Any]
        change(&object)
        let data = try JSONSerialization.data(withJSONObject: object)
        do {
            _ = try JSONDecoder().decode(Fixture.self, from: data)
            preconditionFailure("invalid fixture accepted: \(object)")
        } catch DecodingError.dataCorrupted {}
        // Cached fixtures use the same decoder, so a bad old cache cannot
        // bypass the network boundary after upgrading the app.
        do {
            _ = try JSONDecoder().decode([Fixture].self, from: Data("[".utf8) + data + Data("]".utf8))
            preconditionFailure("invalid persisted fixture accepted")
        } catch DecodingError.dataCorrupted {}
    }

    static func main() throws {
        let decoded = try JSONDecoder().decode(Fixture.self, from: Data(wire.utf8))
        precondition(decoded.hasValidBounds)
        // Older payloads omit optional collections and timing fields.
        let legacy = wire.replacingOccurrences(of: ",\"yellowCards\":0,\"redCards\":0", with: "")
        let old = try JSONDecoder().decode(Fixture.self, from: Data(legacy.utf8))
        precondition(old.hasValidBounds && old.home.goalEvents.isEmpty)

        for side in ["home", "away"] {
            for field in ["goals", "yellowCards", "redCards"] {
                for value in [Int.min, -1, 101, 50_000, Int.max] {
                    try rejects { object in
                        var team = object[side] as! [String: Any]
                        team[field] = value
                        object[side] = team
                    }
                }
            }
        }
        for field in ["minute", "extra"] {
            for value in [Int.min, -1, field == "minute" ? 301 : 61, Int.max] {
                try rejects { $0[field] = value }
            }
        }
        for field in ["goalEvents", "yellowCardEvents", "redCardEvents", "subs"] {
            try rejects { object in
                var team = object["home"] as! [String: Any]
                team[field] = [["minute": 45, "extra": Int.max]]
                object["home"] = team
            }
            try rejects { object in
                var team = object["home"] as! [String: Any]
                team[field] = Array(repeating: ["minute": 45], count: 101)
                object["home"] = team
            }
        }
        try rejects { $0["varEvents"] = [["teamId": 1, "detail": "Penalty confirmed", "minute": Int.max]] }
        try rejects { $0["varEvents"] = Array(repeating: ["teamId": 1, "detail": "Penalty confirmed"], count: 101) }
        try rejects { $0["shootout"] = ["home": Int.max, "away": 0] }
        try rejects { $0["shootout"] = ["home": 0, "away": -1] }
        try rejects { $0["shootout"] = ["home": 0, "away": 0, "kicks": Array(repeating: ["teamId": 1, "scored": true], count: 201)] }

        let schedule = "{\"matches\":[" + Array(repeating: wire, count: 513).joined(separator: ",") + "]}"
        do {
            _ = try JSONDecoder().decode(FixturesPayload.self, from: Data(schedule.utf8))
            preconditionFailure("oversized schedule accepted")
        } catch DecodingError.dataCorrupted {}

        // Direct constructors do not decode; the diff must still fail safely.
        let zero = fixture()
        for value in [Int.min, -1, 50_000, Int.max] {
            precondition(MatchDiff.diff(prev: zero, next: fixture(goals: value)).isEmpty)
            precondition(MatchDiff.diff(prev: fixture(goals: value), next: zero).isEmpty)
            precondition(MatchDiff.diff(prev: fixture(cards: value), next: fixture(cards: value)).isEmpty)
            precondition(!fixture(minute: value).hasValidBounds)
        }
        precondition(MatchDiff.diff(prev: zero, next: fixture(goals: 64)).count == 64)
        precondition(MatchDiff.diff(prev: zero, next: fixture(goals: 65)).isEmpty)
        precondition(MatchDiff.diff(prev: fixture(goals: 100), next: zero).isEmpty)
        precondition(MatchDiff.diff(prev: zero, next: fixture(goals: 40, cards: 40)).isEmpty)

        // Ordinary goals, corrections, cards, transitions, subs, and penalties survive.
        precondition(MatchDiff.diff(prev: zero, next: fixture(goals: 1)).map(\.type) == [.goal])
        precondition(MatchDiff.diff(prev: fixture(goals: 1), next: zero).map(\.type) == [.goalCancelled])
        precondition(MatchDiff.diff(prev: zero, next: fixture(cards: 1)).map(\.type) == [.yellowCard])
        precondition(MatchDiff.diff(prev: fixture(status: "SCHEDULED", rawStatus: "NS"), next: zero).map(\.type) == [.kickoff])
        precondition(MatchDiff.diff(prev: zero, next: fixture(status: "FINISHED", rawStatus: "FT")).map(\.type) == [.fullTime])
        let sub = SubstitutionRecord(playerOut: "A", playerIn: "B", minute: 60, extra: nil)
        precondition(MatchDiff.diff(prev: zero, next: fixture(subs: [sub])).map(\.type) == [.substitution])
        let shootout = Shootout(home: 1, away: 0, kicks: [PenaltyKickRecord(teamId: 1, player: "A", scored: true)])
        precondition(MatchDiff.diff(prev: zero, next: fixture(shootout: shootout)).map(\.type) == [.penaltyKick])

        // Events the feed drops are kept from the earlier snapshot; fresh ones win,
        // and a cancelled goal still leaves the timeline.
        let goal = MatchTimelineEvent(player: "A", minute: 10, extra: nil)
        func scored(_ goals: Int, _ events: [MatchTimelineEvent], subs: [SubstitutionRecord] = []) -> Fixture {
            Fixture(fixtureId: 1, leagueId: 39, round: nil, kickoffISO: "2026-10-04T12:00:00Z",
                    status: "LIVE", rawStatus: "1H", minute: 20,
                    home: ScoreboardTeam(id: 1, name: "A", goals: goals, goalEvents: events, subs: subs),
                    away: ScoreboardTeam(id: 2, name: "B", goals: 0), shootout: nil)
        }
        let seen = scored(1, [goal], subs: [sub])
        let kept = scored(1, []).keepingEvents(from: seen)
        precondition(kept.home.goalEvents == [goal] && kept.home.subs == [sub])
        precondition(MatchDiff.diff(prev: kept, next: seen).isEmpty)
        let other = MatchTimelineEvent(player: "C", minute: 12, extra: nil)
        precondition(scored(1, [other]).keepingEvents(from: seen).home.goalEvents == [other])
        precondition(scored(0, []).keepingEvents(from: seen).home.goalEvents.isEmpty)
        print("Match security checks passed: decoding bounds, cached data, exploit regressions, and normal transitions")
    }
}
