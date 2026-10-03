#if DEV_BACKEND
import AppKit
import Foundation

// Fake service layer for development: compiled only when DEV_BACKEND is set
// (Debug builds). Match reads return seeded in-memory data without spending
// API-Football quota. The catalog alone uses the public CDN. Each parallel match's
// score is walked through DevConfig.timeline by DemoEngine, so what the popover
// shows always matches the events that have fired.

/// Per-match live state the demo timeline mutates. The per-side event arrays
/// mirror what the backend stores on a real fixture — the capsule's hover
/// timeline is rebuilt from them, so without them the demo would show scores
/// but an empty event history.
struct LiveMatchState {
    var homeGoals = 0
    var awayGoals = 0
    var minute: Int?
    /// Stoppage minutes (the `+3` in `90+3`); nil outside added time.
    var extra: Int?
    var status = "SCHEDULED"
    var rawStatus = "NS"
    // Set once a shootout starts so the scoreboard can show the pen tally.
    var penHome: Int?
    var penAway: Int?
    var homeGoalEvents: [MatchTimelineEvent] = []
    var awayGoalEvents: [MatchTimelineEvent] = []
    var homeYellows: [MatchTimelineEvent] = []
    var awayYellows: [MatchTimelineEvent] = []
    var homeReds: [MatchTimelineEvent] = []
    var awayReds: [MatchTimelineEvent] = []
    var homeSubs: [SubstitutionRecord] = []
    var awaySubs: [SubstitutionRecord] = []
    var varEvents: [VarRecord] = []
    var kicks: [PenaltyKickRecord] = []
}

/// Shared mutable state behind all the fakes.
@MainActor
final class FakeStore {
    static let shared = FakeStore()

    // Live state per match, keyed by fixture id. DemoEngine walks each one
    // through the script so every scoreboard stays in step with its pills.
    // `eventSeq` is monotonic (never reset) so replays within a run keep
    // producing fresh eventIds that EventRouter won't dedupe away.
    var states: [Int: LiveMatchState] = FakeStore.freshStates()
    var eventSeq = 0

    // EventRouter's dedupe list persists in UserDefaults, but Debug demo event
    // ids restart on every app launch. Stamp each launch so the showcase always
    // routes, even if the same timeline played in a previous run.
    let launchToken = UUID().uuidString.prefix(8)

    private static func freshStates() -> [Int: LiveMatchState] {
        Dictionary(uniqueKeysWithValues: DemoFixture.demoMatches.map { ($0.id, LiveMatchState()) })
    }

    /// Back to kickoff-minus-one: every match 0–0, not started.
    /// Called at the top of each play-through. `eventSeq`
    /// deliberately survives so replayed events still look new.
    func resetMatches() {
        states = FakeStore.freshStates()
    }

    func addGoal(_ side: DemoSide, in id: Int, player: String?, minute: Int?, extra: Int? = nil, kind: String? = nil) {
        guard var state = states[id] else { return }
        let event = MatchTimelineEvent(player: player, minute: minute, extra: extra, kind: kind)
        if side == .home {
            state.homeGoals += 1
            state.homeGoalEvents.append(event)
        } else {
            state.awayGoals += 1
            state.awayGoalEvents.append(event)
        }
        states[id] = state
    }

    func removeGoal(_ side: DemoSide, in id: Int) {
        guard var state = states[id] else { return }
        if side == .home {
            state.homeGoals = max(state.homeGoals - 1, 0)
            if !state.homeGoalEvents.isEmpty { state.homeGoalEvents.removeLast() }
        } else {
            state.awayGoals = max(state.awayGoals - 1, 0)
            if !state.awayGoalEvents.isEmpty { state.awayGoalEvents.removeLast() }
        }
        states[id] = state
    }

    /// Models the window right after a VAR/offside disallow: API-Football drops
    /// the authoritative aggregate `goals` immediately but leaves the reversed
    /// goal lingering in `events[]` for minutes, so `goalEvents.count > goals`.
    /// The capsule timeline strikes that surplus (most-recent) goal through.
    func disallowGoalKeepingEvent(_ side: DemoSide, in id: Int) {
        guard var state = states[id] else { return }
        if side == .home {
            state.homeGoals = max(state.homeGoals - 1, 0)
        } else {
            state.awayGoals = max(state.awayGoals - 1, 0)
        }
        states[id] = state
    }

    func addCard(_ side: DemoSide, red: Bool, in id: Int, player: String?, minute: Int?, extra: Int? = nil) {
        guard var state = states[id] else { return }
        let event = MatchTimelineEvent(player: player, minute: minute, extra: extra)
        switch (side, red) {
        case (.home, false): state.homeYellows.append(event)
        case (.home, true): state.homeReds.append(event)
        case (.away, false): state.awayYellows.append(event)
        case (.away, true): state.awayReds.append(event)
        }
        states[id] = state
    }

    func addSub(_ side: DemoSide, in id: Int, playerIn: String, playerOut: String, minute: Int?, extra: Int? = nil) {
        guard var state = states[id] else { return }
        let record = SubstitutionRecord(playerOut: playerOut, playerIn: playerIn, minute: minute, extra: extra)
        if side == .home { state.homeSubs.append(record) } else { state.awaySubs.append(record) }
        states[id] = state
    }

    func addVar(in id: Int, teamId: Int, detail: String, minute: Int?, extra: Int? = nil) {
        states[id]?.varEvents.append(
            VarRecord(teamId: teamId, detail: detail, player: nil, minute: minute, extra: extra)
        )
    }

    /// Record a shootout kick: a scored kick bumps that side's pen tally; the
    /// pens always become non-nil so the scoreboard switches to showing them.
    func beginShootout(in id: Int) {
        guard var state = states[id] else { return }
        state.penHome = state.penHome ?? 0
        state.penAway = state.penAway ?? 0
        states[id] = state
    }

    func addPenalty(_ side: DemoSide, scored: Bool, in id: Int, teamId: Int, player: String?) {
        guard var state = states[id] else { return }
        state.penHome = state.penHome ?? 0
        state.penAway = state.penAway ?? 0
        if scored {
            if side == .home { state.penHome! += 1 } else { state.penAway! += 1 }
        }
        state.kicks.append(PenaltyKickRecord(teamId: teamId, player: player, scored: scored))
        states[id] = state
    }

    /// A fixture rebuilt from its current demo state.
    func fixture(_ def: DemoFixture) -> Fixture {
        let s = states[def.id] ?? LiveMatchState()
        // A FIXED fake kickoff — today at the fixture's own scheduled time (see
        // DemoFixture.kickoffTime), never derived from the wall clock or from
        // how far the reel has run. That's what makes the "All Teams" list read
        // like a printed matchday, an hour between kickoffs, no matter when you
        // hit Play. The live minute label doesn't come from here: it's driven by
        // the half changes the timeline fires (LiveStore's local clock).
        let shootout = (s.penHome != nil || s.penAway != nil)
            ? Shootout(home: s.penHome ?? 0, away: s.penAway ?? 0, kicks: s.kicks) : nil
        let kickoff = def.kickoffTime
        let running = s.rawStatus == "1H" || s.rawStatus == "2H" || s.rawStatus == "ET"
        let period: MatchPeriod = {
            switch s.rawStatus {
            case "1H": return .first
            case "2H": return .second
            case "HT": return .half
            case "ET": return (s.minute ?? 0) <= 105 ? .extraFirst : .extraSecond
            // BT (Break Time): "BT" for the ET setup break (≤90'), "ET HT"
            // between the ET halves (91–105'), "PENS" once ET is over (>105').
            case "BT":
                if (s.minute ?? 0) <= 90 { return .breakInPlay }
                return (s.minute ?? 0) > 105 ? .pens : .extraBreak
            case "P": return .pens
            case "PEN", "FT", "AET": return .finished
            default: return .notStarted
            }
        }()
        return Fixture(
            fixtureId: def.id, leagueId: def.leagueId, round: def.round,
            kickoffISO: ISO8601DateFormatter().string(from: kickoff),
            status: s.status, rawStatus: s.rawStatus, minute: s.minute,
            extra: s.extra, period: period, running: running,
            home: ScoreboardTeam(
                id: def.home.id, name: def.home.name, goals: s.homeGoals,
                yellowCards: s.homeYellows.count, redCards: s.homeReds.count,
                goalEvents: s.homeGoalEvents, yellowCardEvents: s.homeYellows,
                redCardEvents: s.homeReds, subs: s.homeSubs
            ),
            away: ScoreboardTeam(
                id: def.away.id, name: def.away.name, goals: s.awayGoals,
                yellowCards: s.awayYellows.count, redCards: s.awayReds.count,
                goalEvents: s.awayGoalEvents, yellowCardEvents: s.awayYellows,
                redCardEvents: s.awayReds, subs: s.awaySubs
            ),
            shootout: shootout,
            varEvents: s.varEvents
        )
    }

    var allFixtures: [Fixture] { DemoFixture.demoMatches.map(fixture) }
    var liveFixtures: [Fixture] { allFixtures.filter { $0.isLive } }
    var todayFixtures: [Fixture] { allFixtures }
}

@MainActor
final class FakeScores: ScoresProviding {
    // ╔════════════════════════════════════════════════════════════════╗
    // ║  WHERE THE TEAMS COME FROM — flip these two lines.              ║
    // ║  LIVE (default): the same `catalog.json` the shipped app reads, ║
    // ║    off the production CDN, so "Become a Fan" lists the real     ║
    // ║    current leagues and squads. A public, edge-cached, read-only ║
    // ║    file: no auth, no API-Football quota.                        ║
    // ║  HARD-CODED: comment out the fetch, uncomment the return below, ║
    // ║    and the picker runs off `hardcodedCatalog` — offline, frozen.║
    // ║  Nothing else in this file ever touches the network.            ║
    // ╚════════════════════════════════════════════════════════════════╝
    func fetchCatalog() async throws -> Catalog {
        // return FakeScores.hardcodedCatalog

        let catalog = try await CDNScoresClient().fetchCatalog()
        NSLog("🧪 FakeBackend: live catalog from %@ — %d leagues, %d teams",
              AppEnvironment.scoresBase.absoluteString,
              catalog.leagues.count,
              catalog.teams.values.reduce(0) { $0 + $1.count })
        return catalog
    }

    func fetchFixtures(date: Date) async throws -> [Fixture] {
        FakeStore.shared.allFixtures
    }
    func fetchFixture(fixtureId: Int) async throws -> Fixture {
        guard let fixture = FakeStore.shared.allFixtures.first(where: { $0.fixtureId == fixtureId }) else {
            throw URLError(.fileDoesNotExist)
        }
        return fixture
    }

    /// Offline fallback for `fetchCatalog()`, and the one to switch to when you
    /// want a catalog that never changes. A trimmed snapshot of the live
    /// `catalog.json` (fetched 29 Aug 2026): the five club leagues the app
    /// follows, each with its best-known sides — including every team the demo
    /// timeline fields — plus the archived World Cup, which is what exercises
    /// the picker's "Ended" section. Ids, codes and names are the real ones, so
    /// crests and short labels resolve exactly as they do in production.
    static let hardcodedCatalog: Catalog = {
        func team(_ id: Int, _ name: String, _ code: String, _ league: Int) -> Team {
            Team(id: id, name: name, code: code, logo: TeamCatalog.logoURL(id), leagueId: league)
        }
        func leagueLogo(_ id: Int) -> String { "https://media.api-sports.io/football/leagues/\(id).png" }
        return Catalog(
            leagues: [
                League(id: 39, name: "Premier League", logo: leagueLogo(39), country: "England",
                       active: true, scheduled: true, season: 2026),
                League(id: 140, name: "La Liga", logo: leagueLogo(140), country: "Spain",
                       active: true, scheduled: true, season: 2026),
                League(id: 135, name: "Serie A", logo: leagueLogo(135), country: "Italy",
                       active: true, scheduled: true, season: 2026),
                League(id: 78, name: "Bundesliga", logo: leagueLogo(78), country: "Germany",
                       active: true, scheduled: true, season: 2026),
                League(id: 61, name: "Ligue 1", logo: leagueLogo(61), country: "France",
                       active: true, scheduled: true, season: 2026),
                League(id: 1, name: "World Cup", logo: leagueLogo(1), country: "World",
                       active: false, scheduled: true, season: 2026, ended: true),
            ],
            teams: [
                "39": [
                    team(50, "Manchester City", "MCI", 39), team(42, "Arsenal", "ARS", 39),
                    team(40, "Liverpool", "LIV", 39), team(33, "Manchester United", "MUN", 39),
                    team(49, "Chelsea", "CHE", 39), team(47, "Tottenham", "TOT", 39),
                ],
                "140": [
                    team(541, "Real Madrid", "REA", 140), team(529, "Barcelona", "BAR", 140),
                    team(530, "Atletico Madrid", "ATM", 140), team(536, "Sevilla", "SEV", 140),
                    team(533, "Villarreal", "VIL", 140),
                ],
                "135": [
                    team(505, "Inter", "INT", 135), team(489, "AC Milan", "MIL", 135),
                    team(496, "Juventus", "JUV", 135), team(492, "Napoli", "NAP", 135),
                    team(497, "AS Roma", "ROM", 135),
                ],
                "78": [
                    team(157, "Bayern München", "BAY", 78), team(165, "Borussia Dortmund", "DOR", 78),
                    team(168, "Bayer Leverkusen", "BAY", 78), team(173, "RB Leipzig", "LEI", 78),
                ],
                "61": [
                    team(85, "Paris Saint Germain", "PSG", 61), team(81, "Marseille", "MAR", 61),
                    team(80, "Lyon", "LYO", 61), team(91, "Monaco", "MON", 61),
                ],
                "1": [
                    team(6,  "Brazil",    "BRA", 1), team(26, "Argentina", "ARG", 1),
                    team(2,  "France",    "FRA", 1), team(10, "England",   "ENG", 1),
                    team(9,  "Spain",     "ESP", 1), team(25, "Germany",   "GER", 1),
                    team(27, "Portugal",  "POR", 1), team(2384, "USA",     "USA", 1),
                ],
            ],
        )
    }()
}

/// Plays DevConfig.timeline: a fixed list of (seconds-after-start → event)
/// beats, fired through the real EventRouter → OverlayManager pipeline exactly
/// as an FCM push would be. Deterministic — same show, same timing, every run.
/// Settings → Developer drives it by hand (Play / Stop / Restart).
@MainActor
final class DemoEngine: ObservableObject {
    static let shared = DemoEngine()

    /// Whether the timeline is currently playing.
    @Published private(set) var isPlaying = false
    /// How many beats have fired in the current play-through (for the UI).
    @Published private(set) var firedCount = 0

    private var task: Task<Void, Never>?

    /// Begin playing from the top. No-op if already playing.
    func start() {
        guard !isPlaying else { return }
        isPlaying = true
        task = Task { @MainActor in
            if DevConfig.clockWalkAtStart && !Task.isCancelled {
                await runClockLabelWalk()
            }
            if DevConfig.showcaseAtStart && !Task.isCancelled {
                await runShowcase()
            }
            while !Task.isCancelled {
                await playThrough()
                if !DevConfig.loops { break }
            }
            isPlaying = false
            task = nil
        }
        NSLog("🧪 DemoEngine: playing %d-beat timeline (loops: %@)",
              DevConfig.timeline.count, DevConfig.loops ? "yes" : "no")
    }

    /// Stop wherever we are and leave the scoreboard as-is.
    func stop() {
        task?.cancel()
        task = nil
        isPlaying = false
        NSLog("🧪 DemoEngine: stopped")
    }

    /// Reset every match to 0–0 and play the whole timeline again.
    func restart() {
        stop()
        FakeStore.shared.resetMatches()
        firedCount = 0
        Task { await AppSession.shared.refreshFixtures() }
        start()
    }

    /// A one-off parade of every pill layout, fired through the real pipeline
    /// before the timeline proper. Uses one match (Bayern vs Dortmund) and only
    /// the opponent (Dortmund) side for goal-type events, so each shows as a
    /// notch PILL rather than a fan-goal celebration — the point here is to
    /// preview the pills. Unlike the timeline this is a synthetic parade, not a
    /// real match: scores are coherent so the subtitle row reads sensibly, and
    /// a shootout decides it so full-time shows the "won on pens" variant.
    private func runShowcase() async {
        let f = DemoFixture.bayDor
        let beats: [DemoMoment] = [
            DemoMoment(at: 0, f, minute: 1,   .kickoff),
            DemoMoment(at: 0, f, minute: 9,   .goal(.away, player: "Serhou Guirassy")), // DOR 0–1 → goal pill
            DemoMoment(at: 0, f, minute: 20,  .yellowCard(.away, player: "Julian Brandt")),
            DemoMoment(at: 0, f, minute: 24,  .goalDisallowed(.away)),                  // VAR → back to 0–0
            DemoMoment(at: 0, f, minute: 33,  .goal(.away, player: "Karim Adeyemi")),   // DOR 0–1 again, for a leader
            DemoMoment(at: 0, f, minute: 41,  .redCard(.away, player: "Nico Schlotterbeck")),
            DemoMoment(at: 0, f, minute: 45,  .halfTime),                               // "Dortmund ahead"
            DemoMoment(at: 0, f, minute: 91,  .extraTime),
            DemoMoment(at: 0, f, minute: 120, .penaltyShootout),
            DemoMoment(at: 0, f, minute: 120, .penaltyKick(.home, player: "Harry Kane",     scored: true)),  // pens 1–0
            DemoMoment(at: 0, f, minute: 120, .penaltyKick(.away, player: "Julian Brandt",  scored: false)), // missed ✗
            DemoMoment(at: 0, f, minute: 120, .fullTime),                               // "Bayern won on pens"
        ]
        FakeStore.shared.resetMatches()
        publishAllFixtures()
        for beat in beats {
            if Task.isCancelled { return }
            fire(beat)
            try? await Task.sleep(for: .seconds(DevConfig.showcaseSpacing))
        }
    }

    /// Steps ONE fixture through every half change so the local clock's
    /// resets + labels can be eyeballed in the menu + capsule:
    ///   0′ (kickoff) → HT → 45′ (2nd half) → ET (pre-ET break) →
    ///   90′ (ET 1st half) → ET HT → 105′ (ET 2nd half) → FT
    /// Each reset snaps the clock to its half's base and the label ticks
    /// locally from there — no `cap+` unknown-stoppage path and no `ET `
    /// prefix; the walk then fires an empty-name goal (subject falls back to
    /// the team, not a blank) and a disallow→re-award cycle (the "Goal
    /// disallowed" pill, then the re-awarded GOAL pill must actually show).
    private func runClockLabelWalk() async {
        let f = DemoFixture.mciArs
        let id = f.id
        FakeStore.shared.resetMatches()

        func statusFor(_ raw: String) -> String {
            switch raw {
            case "HT": return "HALF_TIME"
            case "FT", "AET", "PEN": return "FINISHED"
            case "NS", "TBD": return "SCHEDULED"
            default: return "LIVE"
            }
        }
        func show(_ raw: String, _ minute: Int?, extra: Int? = nil, expect: String) async {
            guard var st = FakeStore.shared.states[id] else { return }
            st.rawStatus = raw
            st.minute = minute
            st.extra = extra
            st.status = statusFor(raw)
            FakeStore.shared.states[id] = st
            publishFixture(f)
            let fixture = FakeStore.shared.fixture(f)
            let shown = fixture.liveMinuteText(localElapsed: LiveStore.shared.localElapsedSeconds(id))
            AppLog.info(.fixtures, "clock_walk_step raw=\(raw) minute=\(minute.map(String.init) ?? "-") shown=\(shown) expect=\(expect)")
            if shown != expect {
                AppAnalytics.clockWalkMismatch(raw: raw, shown: shown, expect: expect)
            }
            try? await Task.sleep(for: .seconds(DevConfig.showcaseSpacing))
        }

        // (rawStatus, minute, extra, expected label right after the reset).
        // `minute` only disambiguates BT/ET into their sub-periods now — the
        // displayed label comes from the local clock, not this value.
        let steps: [(String, Int?, Int?, String)] = [
            ("1H", 1, nil, "0′"),      // kickoff → base 0:00
            ("HT", 45, nil, "HT"),
            ("2H", 46, nil, "45′"),    // half reset → base 45:00
            ("BT", 90, nil, "ET"),     // pre-ET break (was "BT")
            ("ET", 91, nil, "90′"),    // ET 1st half reset → base 90:00
            ("BT", 100, nil, "ET HT"), // between the ET halves
            ("ET", 106, nil, "105′"),  // ET 2nd half reset → base 105:00
            ("FT", 120, nil, "FT"),
        ]
        for (raw, minute, extra, expect) in steps {
            if Task.isCancelled { return }
            await show(raw, minute, extra: extra, expect: expect)
        }

        // Empty-name goal: the pill's subject should be the TEAM, not a blank.
        if Task.isCancelled { return }
        FakeStore.shared.states[id]?.status = "LIVE"
        FakeStore.shared.states[id]?.rawStatus = "2H"
        FakeStore.shared.states[id]?.minute = 70
        FakeStore.shared.states[id]?.extra = nil
        FakeStore.shared.addGoal(.home, in: id, player: nil, minute: 70)
        push(.goal, f, side: .home, player: nil, minute: 70)
        publishFixture(f)
        try? await Task.sleep(for: .seconds(DevConfig.showcaseSpacing))

        // Disallow → re-award: the drop shows "Goal disallowed", then the
        // re-awarded GOAL pill must actually appear (not be swallowed by dedupe).
        if Task.isCancelled { return }
        FakeStore.shared.states[id]?.minute = 72
        FakeStore.shared.removeGoal(.home, in: id)
        push(.goalCancelled, f, side: .home, minute: 72)
        publishFixture(f)
        try? await Task.sleep(for: .seconds(DevConfig.showcaseSpacing))

        if Task.isCancelled { return }
        FakeStore.shared.states[id]?.minute = 74
        FakeStore.shared.addGoal(.home, in: id, player: "Haaland", minute: 74)
        push(.goal, f, side: .home, player: "Haaland", minute: 74)
        publishFixture(f)
        try? await Task.sleep(for: .seconds(DevConfig.showcaseSpacing))
    }

    private func playThrough() async {
        FakeStore.shared.resetMatches()
        publishAllFixtures()
        firedCount = 0
        let start = Date()
        // Play in `at` order, not source order, so the timeline can stay
        // grouped by match: an earlier beat further down the array would
        // otherwise have a negative wait and fire the moment we reached it.
        // Ties keep their source order, so same-`at` beats stay deterministic.
        let script = DevConfig.timeline.enumerated()
            .sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }
            .map(\.element)
        for moment in script {
            let wait = start.addingTimeInterval(moment.at).timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            if Task.isCancelled { return }
            fire(moment)
            firedCount += 1
        }
    }

    /// Set while a `silent` beat is applied: its state change lands on the
    /// scoreboard, but nothing is routed to the overlays. That's how a match
    /// that finished before you opened the app gets a full history without
    /// spraying its pills across the screen at t=0 — and it matches production,
    /// where a match with no followed team is never polled at all.
    private var suppressPush = false

    private func fire(_ moment: DemoMoment) {
        let store = FakeStore.shared
        suppressPush = moment.silent
        defer { suppressPush = false }
        let def = moment.fixture
        let id = def.id
        store.states[id]?.extra = moment.extra
        // Any in-play beat implies the match is running, in the half its minute
        // falls in — so a 54' goal after half-time moves the fixture out of HT
        // and into the second half, and the local clock rebases to 45:00
        // instead of snapping back to 1'. (The real backend infers the same
        // thing from API-Football's status; the demo has no `.secondHalf`
        // action, so the minute is what tells us.)
        func markRunning(_ minute: Int) {
            store.states[id]?.status = "LIVE"
            store.states[id]?.rawStatus = minute <= 45 ? "1H" : (minute <= 90 ? "2H" : "ET")
            store.states[id]?.minute = minute
        }
        switch moment.action {
        case .kickoff:
            store.states[id]?.status = "LIVE"
            store.states[id]?.rawStatus = "1H"
            store.states[id]?.minute = moment.minute
            push(.kickoff, def, minute: moment.minute)
        case let .goal(side, player, kind):
            markRunning(moment.minute)
            store.addGoal(side, in: id, player: player, minute: moment.minute, extra: moment.extra, kind: kind)
            push(.goal, def, side: side, player: player, minute: moment.minute, extra: moment.extra, goalKind: kind)
        case let .goalDisallowed(side):
            markRunning(moment.minute)
            store.removeGoal(side, in: id)
            push(.goalCancelled, def, side: side, minute: moment.minute)
        case let .goalDisallowedOffside(side):
            markRunning(moment.minute)
            store.disallowGoalKeepingEvent(side, in: id)
            push(.goalCancelled, def, side: side, minute: moment.minute)
        case let .yellowCard(side, player):
            markRunning(moment.minute)
            store.addCard(side, red: false, in: id, player: player, minute: moment.minute, extra: moment.extra)
            push(.yellowCard, def, side: side, player: player, minute: moment.minute, extra: moment.extra)
        case let .redCard(side, player):
            markRunning(moment.minute)
            store.addCard(side, red: true, in: id, player: player, minute: moment.minute, extra: moment.extra)
            push(.redCard, def, side: side, player: player, minute: moment.minute, extra: moment.extra)
        case let .substitution(side, playerIn, playerOut):
            markRunning(moment.minute)
            store.addSub(side, in: id, playerIn: playerIn, playerOut: playerOut, minute: moment.minute, extra: moment.extra)
            push(.substitution, def, side: side, player: playerIn, minute: moment.minute, extra: moment.extra,
                 playerOut: playerOut)
        case let .varDecision(side, detail):
            markRunning(moment.minute)
            let teamId = side == .home ? def.home.id : def.away.id
            store.addVar(in: id, teamId: teamId, detail: detail, minute: moment.minute, extra: moment.extra)
            push(.varDecision, def, side: side, minute: moment.minute, extra: moment.extra, varDetail: detail)
        case .halfTime:
            store.states[id]?.status = "HALF_TIME"
            store.states[id]?.rawStatus = "HT"
            store.states[id]?.minute = moment.minute
            push(.halfTime, def, minute: moment.minute)
        case .fullTime:
            let finishedAfterPens = store.states[id]?.penHome != nil || store.states[id]?.penAway != nil
            store.states[id]?.status = "FINISHED"
            store.states[id]?.rawStatus = finishedAfterPens ? "PEN" : "FT"
            store.states[id]?.minute = moment.minute
            push(.fullTime, def, minute: moment.minute)
        case .extraTime:
            store.states[id]?.status = "LIVE"
            store.states[id]?.rawStatus = "ET"
            store.states[id]?.minute = moment.minute
            push(.extraTime, def, minute: moment.minute)
        case .penaltyShootout:
            store.states[id]?.status = "LIVE"
            store.states[id]?.rawStatus = "P"
            store.states[id]?.minute = moment.minute
            store.beginShootout(in: id)
            push(.penaltyShootout, def, minute: moment.minute)
        case let .penaltyKick(side, player, scored):
            store.states[id]?.status = "LIVE"
            store.states[id]?.rawStatus = "P"
            store.states[id]?.minute = moment.minute
            store.addPenalty(side, scored: scored, in: id,
                             teamId: side == .home ? def.home.id : def.away.id, player: player)
            push(.penaltyKick, def, side: side, player: player, minute: moment.minute, scored: scored)
        }
        publishFixture(def)
    }

    /// Build the `MatchEvent` the poll-diff would have produced for this moment
    /// and route it straight to the overlays (the dev fake stands in for the
    /// poll loop). The scoreline comes from the store, which `fire` already
    /// updated.
    private func push(_ type: MatchEventType, _ def: DemoFixture,
                      side: DemoSide? = nil, player: String? = nil, minute: Int,
                      extra: Int? = nil, scored: Bool? = nil, goalKind: String? = nil,
                      playerOut: String? = nil, varDetail: String? = nil) {
        guard !suppressPush else { return }
        let store = FakeStore.shared
        let s = store.states[def.id] ?? LiveMatchState()
        let teamId = side.map { $0 == .home ? def.home.id : def.away.id }
        let event = MatchEvent(
            eventId: "demo:\(store.launchToken):\(def.id):\(type.rawValue):\(store.eventSeq)",
            type: type,
            fixtureId: def.id,
            leagueId: def.leagueId,
            teamId: teamId,
            player: player,
            minute: minute,
            extra: extra,
            homeTeamId: def.home.id,
            awayTeamId: def.away.id,
            homeName: def.home.name,
            awayName: def.away.name,
            homeGoals: s.homeGoals,
            awayGoals: s.awayGoals,
            // Carry the pen tally once a shootout exists, mirroring the backend
            // (it rides on full-time and every shootout event).
            penHome: s.penHome,
            penAway: s.penAway,
            scored: scored,
            goalKind: goalKind,
            playerOut: playerOut,
            varDetail: varDetail
        )
        store.eventSeq += 1
        EventRouter.shared.route(event)
    }

    private func publishFixture(_ def: DemoFixture) {
        let fixture = FakeStore.shared.fixture(def)
        LiveStore.shared.noteClockObservation(fixture)
        AppSession.shared.applyLiveFixture(fixture)
        AppSession.shared.publishFixtures()
    }

    private func publishAllFixtures() {
        for fixture in FakeStore.shared.allFixtures {
            LiveStore.shared.noteClockObservation(fixture)
            AppSession.shared.applyLiveFixture(fixture)
        }
        AppSession.shared.publishFixtures()
    }
}
#endif
