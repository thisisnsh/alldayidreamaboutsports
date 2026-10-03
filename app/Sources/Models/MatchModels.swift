import Foundation

extension String {
    /// The string trimmed of surrounding whitespace/newlines, or nil if it's
    /// empty afterwards. The live feed sometimes sends `""`/`"  "` player names
    /// before the scorer/carded player is filled in — normalize them to nil at
    /// decode time so `??` fallbacks (pill titles, timeline, MatchDiff) engage.
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum MatchEventType: String, Codable, CaseIterable {
    case kickoff = "KICKOFF"
    case goal = "GOAL"
    case goalCancelled = "GOAL_CANCELLED"
    case yellowCard = "YELLOW_CARD"
    case redCard = "RED_CARD"
    case halfTime = "HALF_TIME"
    case secondHalf = "SECOND_HALF"
    case fullTime = "FULL_TIME"
    case extraTime = "EXTRA_TIME"
    case penaltyShootout = "PENALTY_SHOOTOUT"
    case penaltyKick = "PENALTY_KICK"
    case substitution = "SUBSTITUTION"
    case varDecision = "VAR_DECISION"
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
    /// Goal manner: "own" / "penalty" (GOAL only; nil for a normal goal).
    let goalKind: String?
    /// Player leaving the pitch (SUBSTITUTION only; `player` is the one coming on).
    let playerOut: String?
    /// VAR outcome text, e.g. "Penalty confirmed" (VAR_DECISION only).
    let varDetail: String?

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
        scored: Bool? = nil,
        goalKind: String? = nil,
        playerOut: String? = nil,
        varDetail: String? = nil
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
        self.goalKind = goalKind
        self.playerOut = playerOut
        self.varDetail = varDetail
    }
}

// matches/{id}.json + fixtures-{date}.json payloads (backend MatchState shape).

/// One goal/card event on a team, ordered as issued; index 0 = first. Carries
/// the scorer/carded player, the official minute, and any stoppage `extra`.
struct MatchTimelineEvent: Codable, Hashable {
    let player: String?
    let minute: Int?
    let extra: Int?
    /// Goal manner ("own"/"penalty"); only present on goal events, nil for cards.
    let kind: String?

    init(player: String?, minute: Int?, extra: Int?, kind: String? = nil) {
        self.player = player
        self.minute = minute
        self.extra = extra
        self.kind = kind
    }

    enum CodingKeys: String, CodingKey { case player, minute, extra, kind }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        player = try c.decodeIfPresent(String.self, forKey: .player)?.trimmedNonEmpty
        minute = try c.decodeIfPresent(Int.self, forKey: .minute)
        extra = try c.decodeIfPresent(Int.self, forKey: .extra)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
    }
}

/// One substitution (backend `SubEvent`): `playerOut` leaves, `playerIn` enters.
struct SubstitutionRecord: Codable, Hashable {
    let playerOut: String?
    let playerIn: String?
    let minute: Int?
    let extra: Int?

    init(playerOut: String?, playerIn: String?, minute: Int?, extra: Int?) {
        self.playerOut = playerOut
        self.playerIn = playerIn
        self.minute = minute
        self.extra = extra
    }

    enum CodingKeys: String, CodingKey { case playerOut, playerIn, minute, extra }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        playerOut = try c.decodeIfPresent(String.self, forKey: .playerOut)?.trimmedNonEmpty
        playerIn = try c.decodeIfPresent(String.self, forKey: .playerIn)?.trimmedNonEmpty
        minute = try c.decodeIfPresent(Int.self, forKey: .minute)
        extra = try c.decodeIfPresent(Int.self, forKey: .extra)
    }
}

/// One VAR review outcome (backend `VarEvent`).
struct VarRecord: Codable, Hashable {
    let teamId: Int
    let detail: String
    let player: String?
    let minute: Int?
    let extra: Int?

    init(teamId: Int, detail: String, player: String?, minute: Int?, extra: Int?) {
        self.teamId = teamId
        self.detail = detail
        self.player = player
        self.minute = minute
        self.extra = extra
    }

    enum CodingKeys: String, CodingKey { case teamId, detail, player, minute, extra }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        teamId = try c.decode(Int.self, forKey: .teamId)
        detail = try c.decode(String.self, forKey: .detail)
        player = try c.decodeIfPresent(String.self, forKey: .player)?.trimmedNonEmpty
        minute = try c.decodeIfPresent(Int.self, forKey: .minute)
        extra = try c.decodeIfPresent(Int.self, forKey: .extra)
    }
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
    let subs: [SubstitutionRecord]

    enum CodingKeys: String, CodingKey {
        case id, name, goals, yellowCards, redCards
        case goalEvents, yellowCardEvents, redCardEvents, subs
    }

    init(
        id: Int,
        name: String,
        goals: Int,
        yellowCards: Int = 0,
        redCards: Int = 0,
        goalEvents: [MatchTimelineEvent] = [],
        yellowCardEvents: [MatchTimelineEvent] = [],
        redCardEvents: [MatchTimelineEvent] = [],
        subs: [SubstitutionRecord] = []
    ) {
        self.id = id
        self.name = name
        self.goals = goals
        self.yellowCards = yellowCards
        self.redCards = redCards
        self.goalEvents = goalEvents
        self.yellowCardEvents = yellowCardEvents
        self.redCardEvents = redCardEvents
        self.subs = subs
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
        subs = try c.decodeIfPresent([SubstitutionRecord].self, forKey: .subs) ?? []
    }
}

/// One penalty-shootout kick, in the order taken.
struct PenaltyKickRecord: Codable, Hashable {
    let teamId: Int
    let player: String?
    let scored: Bool

    init(teamId: Int, player: String?, scored: Bool) {
        self.teamId = teamId
        self.player = player
        self.scored = scored
    }

    enum CodingKeys: String, CodingKey { case teamId, player, scored }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        teamId = try c.decode(Int.self, forKey: .teamId)
        player = try c.decodeIfPresent(String.self, forKey: .player)?.trimmedNonEmpty
        scored = try c.decode(Bool.self, forKey: .scored)
    }
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
    case breakInPlay = "BREAK"
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
    let varEvents: [VarRecord]

    enum CodingKeys: String, CodingKey {
        case fixtureId, leagueId, round, kickoffISO, status, rawStatus
        case minute, extra, period, running, home, away, shootout, varEvents
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
        shootout: Shootout?,
        varEvents: [VarRecord] = []
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
        self.varEvents = varEvents
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
        varEvents = try c.decodeIfPresent([VarRecord].self, forKey: .varEvents) ?? []
    }

    var id: Int { fixtureId }
    var isLive: Bool { status == "LIVE" || status == "HALF_TIME" }
    /// Postponed / cancelled / abandoned / awarded / walkover: the match is not
    /// (or no longer) being played, so there is nothing left to poll.
    var isCalledOff: Bool {
        status == "OTHER" && ["PST", "CANC", "ABD", "AWD", "WO"].contains(rawStatus ?? "")
    }
    var kickoff: Date? { ISO8601DateFormatter().date(from: kickoffISO) }
    var score: Score { Score(home: home.goals, away: away.goals) }

    /// Minute at which stoppage begins for a running period (the clock caps
    /// here and the overflow rides in `extra`): 45 / 90 / 105 / 120. nil for a
    /// non-playing period.
    private var periodCap: Int? {
        switch period {
        case .first: return 45
        case .second: return 90
        case .extraFirst: return 105
        case .extraSecond: return 120
        default: return nil
        }
    }

    /// Base clock seconds for the start of a running half — the anchor
    /// `LiveStore`'s local clock resets to on every half change (never taken
    /// from the backend's running-clock field).
    static func fixedBaseSeconds(for period: MatchPeriod) -> Double {
        switch period {
        case .first: return 0
        case .second: return 45 * 60
        case .extraFirst: return 90 * 60
        case .extraSecond: return 105 * 60
        default: return 0
        }
    }

    /// The right-edge clock label. `localElapsed` is our own free-running
    /// clock (seconds since the last half change — see `LiveStore`), NOT the
    /// backend's running-clock field, which is ignored here by construction.
    /// Sequence it must produce, in order:
    /// `0′ → 45′ → 45+1′ → HT → 45′ → 90′ → 90+1′ → ET → 90′ → 105′ → 105+1′
    /// → ET HT → 105′ → 120′ → 120+1′ → FT`.
    /// `running:false` → a status label (HT / ET / ET HT / PENS / FT / kickoff).
    /// `running:true`  → a plain ticking minute, folded at the half's cap
    /// (`"73′"`, `"45+2′"`) — no `ET ` prefix; extra time is distinguished by
    /// its value alone.
    func liveMinuteText(localElapsed: Double?) -> String {
        let timeFormatter: () -> String = {
            guard let kickoff else { return "" }
            let f = DateFormatter()
            f.timeStyle = .short
            f.dateStyle = .none
            return f.string(from: kickoff)
        }
        func foldedLabel(_ minute: Int) -> String {
            if let cap = periodCap, minute > cap { return "\(cap)+\(minute - cap)′" }
            return "\(minute)′"
        }
        if running == true, let localElapsed {
            let minute = localElapsed <= 0 ? 0 : Int(ceil(localElapsed / 60))
            return foldedLabel(minute)
        }
        // running == false (or unknown, or no local anchor yet): derive a
        // label from the period/status.
        switch period {
        case .half: return "HT"
        case .breakInPlay: return "ET"
        case .extraBreak: return "ET HT"
        case .pens: return "PENS"
        case .finished: return "FT"
        case .notStarted: return timeFormatter()
        case .first, .second, .extraFirst, .extraSecond:
            // running flag missing / no anchor yet but mid-half: best effort
            // on the raw minute.
            if let minute { return foldedLabel(minute) }
            return "LIVE"
        case .other, .none:
            // Fall back to the coarse status when period is absent (e.g. the
            // 12h fixtures bootstrap file that doesn't carry period/running).
            switch status {
            case "HALF_TIME": return "HT"
            case "FINISHED": return "FT"
            case "OTHER":
                switch rawStatus {
                case "PST": return "Postponed"
                case "CANC": return "Cancelled"
                case "ABD": return "Abandoned"
                case "SUSP": return "Suspended"
                case "AWD", "WO": return "Awarded"
                default: return timeFormatter()
                }
            case "LIVE":
                if let minute { return foldedLabel(minute) }
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
    /// League play sends "Regular Season - 3" → "Matchday 3"; group stages send
    /// "Group A - 1" → "Group A · MD1"; knockout rounds ("Round of 16",
    /// "Final", …) pass through unchanged. nil when the round is absent.
    /// The group and knockout cases stay for the archived World Cup rows, and
    /// for whatever cup competition comes next.
    var stageLabel: String? {
        guard let round, !round.isEmpty else { return nil }
        let parts = round.components(separatedBy: " - ")
        if parts.count == 2, let matchday = Int(parts[1]) {
            if parts[0] == "Regular Season" { return "Matchday \(matchday)" }
            if parts[0].hasPrefix("Group") { return "\(parts[0]) · MD\(matchday)" }
        }
        return round
    }

    func involves(_ ids: Set<Int>) -> Bool {
        ids.contains(home.id) || ids.contains(away.id)
    }

    var scorelineText: String {
        ScorelineFormatter.text(
            homeGoals: home.goals,
            awayGoals: away.goals,
            penHome: shootout?.home,
            penAway: shootout?.away
        )
    }
}

struct Score: Codable, Hashable {
    let home: Int
    let away: Int
}

enum ScorelineFormatter {
    static func text(
        homeGoals: Int,
        awayGoals: Int,
        penHome: Int?,
        penAway: Int?,
        separator: String = " – "
    ) -> String {
        let hasPens = penHome != nil || penAway != nil
        let home = scoreText(goals: homeGoals, pens: hasPens ? (penHome ?? 0) : nil)
        let away = scoreText(goals: awayGoals, pens: hasPens ? (penAway ?? 0) : nil)
        return "\(home)\(separator)\(away)"
    }

    private static func scoreText(goals: Int, pens: Int?) -> String {
        guard let pens else { return "\(goals)" }
        return "\(goals)+P\(pens)"
    }
}

struct FixturesPayload: Codable {
    let matches: [Fixture]
}

struct CelebrationTotals: Codable {
    let totals: [String: Int]
}
