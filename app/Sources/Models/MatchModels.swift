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
    /// Added/stoppage time, e.g. the `+3` in a `90+3` goal. nil for whole minutes.
    let extra: Int?
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

    init(
        eventId: String,
        type: MatchEventType,
        fixtureId: Int,
        leagueId: Int,
        teamId: Int? = nil,
        player: String? = nil,
        minute: Int? = nil,
        extra: Int? = nil,
        homeTeamId: Int,
        awayTeamId: Int,
        homeName: String,
        awayName: String,
        homeGoals: Int,
        awayGoals: Int,
        penHome: Int? = nil,
        penAway: Int? = nil,
        scored: Bool? = nil
    ) {
        self.eventId = eventId
        self.type = type
        self.fixtureId = fixtureId
        self.leagueId = leagueId
        self.teamId = teamId
        self.player = player
        self.minute = minute
        self.extra = extra
        self.homeTeamId = homeTeamId
        self.awayTeamId = awayTeamId
        self.homeName = homeName
        self.awayName = awayName
        self.homeGoals = homeGoals
        self.awayGoals = awayGoals
        self.penHome = penHome
        self.penAway = penAway
        self.scored = scored
    }
}

// matches/{id}.json + fixtures-{date}.json payloads (backend MatchState shape).

/// One goal/card event on a team, ordered as issued; index 0 = first. Carries
/// the scorer/carded player, the official minute, and any stoppage `extra`.
struct MatchTimelineEvent: Codable, Hashable {
    let player: String?
    let minute: Int?
    let extra: Int?
}

struct ScoreboardTeam: Codable, Hashable {
    let id: Int
    let name: String
    let goals: Int
    let yellowCards: Int
    let redCards: Int
    let goalEvents: [MatchTimelineEvent]
    let yellowCardEvents: [MatchTimelineEvent]
    let redCardEvents: [MatchTimelineEvent]

    enum CodingKeys: String, CodingKey {
        case id, name, goals, yellowCards, redCards
        case goalEvents, yellowCardEvents, redCardEvents
    }

    init(
        id: Int,
        name: String,
        goals: Int,
        yellowCards: Int = 0,
        redCards: Int = 0,
        goalEvents: [MatchTimelineEvent] = [],
        yellowCardEvents: [MatchTimelineEvent] = [],
        redCardEvents: [MatchTimelineEvent] = []
    ) {
        self.id = id
        self.name = name
        self.goals = goals
        self.yellowCards = yellowCards
        self.redCards = redCards
        self.goalEvents = goalEvents
        self.yellowCardEvents = yellowCardEvents
        self.redCardEvents = redCardEvents
    }

    // Older/partial payloads (e.g. the fixtures bootstrap file) may omit the
    // event arrays and card counts — default them so decoding never fails.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        goals = try c.decode(Int.self, forKey: .goals)
        yellowCards = try c.decodeIfPresent(Int.self, forKey: .yellowCards) ?? 0
        redCards = try c.decodeIfPresent(Int.self, forKey: .redCards) ?? 0
        goalEvents = try c.decodeIfPresent([MatchTimelineEvent].self, forKey: .goalEvents) ?? []
        yellowCardEvents = try c.decodeIfPresent([MatchTimelineEvent].self, forKey: .yellowCardEvents) ?? []
        redCardEvents = try c.decodeIfPresent([MatchTimelineEvent].self, forKey: .redCardEvents) ?? []
    }
}

/// One penalty-shootout kick, in the order taken.
struct PenaltyKickRecord: Codable, Hashable {
    let teamId: Int
    let player: String?
    let scored: Bool
}

/// Penalty-shootout result on a fixture (backend MatchState.shootout). The
/// running counts feed the scoreboard; `kicks` drives per-kick diff events.
struct Shootout: Codable, Hashable {
    let home: Int
    let away: Int
    let kicks: [PenaltyKickRecord]

    enum CodingKeys: String, CodingKey {
        case home, away, kicks
    }

    init(home: Int, away: Int, kicks: [PenaltyKickRecord] = []) {
        self.home = home
        self.away = away
        self.kicks = kicks
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        home = try c.decode(Int.self, forKey: .home)
        away = try c.decode(Int.self, forKey: .away)
        kicks = try c.decodeIfPresent([PenaltyKickRecord].self, forKey: .kicks) ?? []
    }
}

/// Coarse phase of the match clock, mirrored from the backend `period` enum
/// (`backend/src/types.ts`). Raw values MUST match the wire strings exactly.
enum MatchPeriod: String, Codable {
    case notStarted = "PRE"
    case first = "FIRST"
    case half = "HALF"
    case second = "SECOND"
    case extraFirst = "EXTRA_FIRST"
    case extraSecond = "EXTRA_SECOND"
    case extraBreak = "EXTRA_BREAK"
    case pens = "PENALTIES"
    case finished = "FINISHED"
    case other = "OTHER"

    /// Tolerate an unknown/future phase rather than failing the whole fixture
    /// decode — an unrecognized string degrades to `.other`.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MatchPeriod(rawValue: raw) ?? .other
    }
}

struct Fixture: Codable, Identifiable, Hashable {
    let fixtureId: Int
    let leagueId: Int
    let round: String?
    let kickoffISO: String
    let status: String // SCHEDULED | LIVE | HALF_TIME | FINISHED | OTHER
    /// API-Football short code (1H, HT, FT, ...). Drives the precise diff.
    let rawStatus: String?
    let minute: Int? // elapsed; freezes during stoppage
    /// Added/stoppage minute (the `+2` in `45+2`). nil outside stoppage.
    let extra: Int?
    let period: MatchPeriod?
    /// Whether the clock is currently ticking (1H/2H/ET); false at HT/BT/P/FT/NS.
    let running: Bool?
    let home: ScoreboardTeam
    let away: ScoreboardTeam
    let shootout: Shootout?

    enum CodingKeys: String, CodingKey {
        case fixtureId, leagueId, round, kickoffISO, status, rawStatus
        case minute, extra, period, running, home, away, shootout
    }

    init(
        fixtureId: Int,
        leagueId: Int,
        round: String?,
        kickoffISO: String,
        status: String,
        rawStatus: String? = nil,
        minute: Int?,
        extra: Int? = nil,
        period: MatchPeriod? = nil,
        running: Bool? = nil,
        home: ScoreboardTeam,
        away: ScoreboardTeam,
        shootout: Shootout?
    ) {
        self.fixtureId = fixtureId
        self.leagueId = leagueId
        self.round = round
        self.kickoffISO = kickoffISO
        self.status = status
        self.rawStatus = rawStatus
        self.minute = minute
        self.extra = extra
        self.period = period
        self.running = running
        self.home = home
        self.away = away
        self.shootout = shootout
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fixtureId = try c.decode(Int.self, forKey: .fixtureId)
        leagueId = try c.decode(Int.self, forKey: .leagueId)
        round = try c.decodeIfPresent(String.self, forKey: .round)
        kickoffISO = try c.decode(String.self, forKey: .kickoffISO)
        status = try c.decode(String.self, forKey: .status)
        rawStatus = try c.decodeIfPresent(String.self, forKey: .rawStatus)
        minute = try c.decodeIfPresent(Int.self, forKey: .minute)
        extra = try c.decodeIfPresent(Int.self, forKey: .extra)
        period = try c.decodeIfPresent(MatchPeriod.self, forKey: .period)
        running = try c.decodeIfPresent(Bool.self, forKey: .running)
        home = try c.decode(ScoreboardTeam.self, forKey: .home)
        away = try c.decode(ScoreboardTeam.self, forKey: .away)
        shootout = try c.decodeIfPresent(Shootout.self, forKey: .shootout)
    }

    var id: Int { fixtureId }
    var isLive: Bool { status == "LIVE" || status == "HALF_TIME" }
    var kickoff: Date? { ISO8601DateFormatter().date(from: kickoffISO) }
    var score: Score { Score(home: home.goals, away: away.goals) }

    /// The right-edge clock label. Stoppage/extra-time/VAR aware — rendered
    /// straight from the polled file's `minute`/`extra`/`period`/`running`.
    /// `running:false` → a status label (HT / ET HT / PENS / FT / kickoff time).
    /// `running:true`  → `"73′"`, or `"45+2′"` when `extra` is set.
    var liveMinuteText: String {
        let timeFormatter: () -> String = {
            guard let kickoff else { return "" }
            let f = DateFormatter()
            f.timeStyle = .short
            f.dateStyle = .none
            return f.string(from: kickoff)
        }
        if running == true {
            guard let minute else { return "LIVE" }
            if let extra { return "\(minute)+\(extra)′" }
            return "\(minute)′"
        }
        // running == false (or unknown): derive a label from the period/status.
        switch period {
        case .half: return "HT"
        case .extraBreak: return "ET HT"
        case .pens: return "PENS"
        case .finished: return "FT"
        case .notStarted: return timeFormatter()
        case .first, .second, .extraFirst, .extraSecond:
            // running flag missing but mid-half: best effort on the raw minute.
            if let minute {
                return extra.map { "\(minute)+\($0)′" } ?? "\(minute)′"
            }
            return "LIVE"
        case .other, .none:
            // Fall back to the coarse status when period is absent (e.g. the
            // 12h fixtures bootstrap file that doesn't carry period/running).
            switch status {
            case "HALF_TIME": return "HT"
            case "FINISHED": return "FT"
            case "LIVE":
                if let minute { return extra.map { "\(minute)+\($0)′" } ?? "\(minute)′" }
                return "LIVE"
            default: return timeFormatter()
            }
        }
    }

    func needsFrequentRefresh(at now: Date = Date()) -> Bool {
        if isLive { return true }
        guard status == "SCHEDULED", let kickoff else { return false }
        let untilKickoff = kickoff.timeIntervalSince(now)
        return untilKickoff <= 60 && untilKickoff > -15 * 60
    }

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

    func involves(_ ids: Set<Int>) -> Bool {
        ids.contains(home.id) || ids.contains(away.id)
    }
}

struct Score: Codable, Hashable {
    let home: Int
    let away: Int
}

struct FixturesPayload: Codable {
    let matches: [Fixture]
}

struct CelebrationTotals: Codable {
    let totals: [String: Int]
}
