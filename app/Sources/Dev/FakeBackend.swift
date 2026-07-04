#if DEV_BACKEND
import AppKit
import Foundation

// Fake service layer for development: compiled only when DEV_BACKEND is set
// (Debug builds). GETs return seeded hardcoded data; POSTs mutate that data in
// memory, so round-trips behave like the real system — without touching the
// network, your API-Football quota, or Google sign-in. Each parallel match's
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

    /// Celebration tap totals per fixture; surges in the timeline overwrite
    /// this and a user tapping in the app adds to it.
    var celebrations: [Int: [String: Int]] = [:]

    private static func freshStates() -> [Int: LiveMatchState] {
        Dictionary(uniqueKeysWithValues: DemoFixture.demoMatches.map { ($0.id, LiveMatchState()) })
    }

    /// Back to kickoff-minus-one: every match 0–0, not started, no
    /// celebrations. Called at the top of each play-through. `eventSeq`
    /// deliberately survives so replayed events still look new.
    func resetMatches() {
        states = FakeStore.freshStates()
        celebrations = [:]
    }

    func addGoal(_ side: DemoSide, in id: Int, player: String?, minute: Int?, kind: String? = nil) {
        guard var state = states[id] else { return }
        let event = MatchTimelineEvent(player: player, minute: minute, extra: nil, kind: kind)
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

    func addCard(_ side: DemoSide, red: Bool, in id: Int, player: String?, minute: Int?) {
        guard var state = states[id] else { return }
        let event = MatchTimelineEvent(player: player, minute: minute, extra: nil)
        switch (side, red) {
        case (.home, false): state.homeYellows.append(event)
        case (.home, true): state.homeReds.append(event)
        case (.away, false): state.awayYellows.append(event)
        case (.away, true): state.awayReds.append(event)
        }
        states[id] = state
    }

    func addSub(_ side: DemoSide, in id: Int, playerIn: String, playerOut: String, minute: Int?) {
        guard var state = states[id] else { return }
        let record = SubstitutionRecord(playerOut: playerOut, playerIn: playerIn, minute: minute, extra: nil)
        if side == .home { state.homeSubs.append(record) } else { state.awaySubs.append(record) }
        states[id] = state
    }

    func addVar(in id: Int, teamId: Int, detail: String, minute: Int?) {
        states[id]?.varEvents.append(
            VarRecord(teamId: teamId, detail: detail, player: nil, minute: minute, extra: nil)
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

    /// A fixture rebuilt from its current demo state — kickoff is back-dated
    /// to match the on-screen minute.
    func fixture(_ def: DemoFixture) -> Fixture {
        let s = states[def.id] ?? LiveMatchState()
        let kickoff = Date().addingTimeInterval(-Double(s.minute ?? 0) * 60)
        let shootout = (s.penHome != nil || s.penAway != nil)
            ? Shootout(home: s.penHome ?? 0, away: s.penAway ?? 0, kicks: s.kicks) : nil
        let running = s.rawStatus == "1H" || s.rawStatus == "2H" || s.rawStatus == "ET"
        let period: MatchPeriod = {
            switch s.rawStatus {
            case "1H": return .first
            case "HT": return .half
            case "ET": return (s.minute ?? 0) <= 105 ? .extraFirst : .extraSecond
            // BT (Break Time): "BT" for the FT→ET setup break (≤90'), "ET HT"
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
final class FakeGoogleAuth: GoogleAuthProviding {
    func signIn(presenting window: NSWindow?) async throws -> String {
        try? await Task.sleep(for: .milliseconds(300)) // feel like a network hop
        return "fake-google-id-token"
    }

    func signOut() {}
}

@MainActor
final class FakeBackendAPI: BackendAPI {
    func signIn(googleIdToken: String) async throws -> SignInResponse {
        SignInResponse(
            token: "dev-session-token",
            profile: DevConfig.profile
        )
    }

    func celebrate(fixtureId: Int, teamId: String, taps: Int) async throws {
        try? await Task.sleep(for: .milliseconds(250)) // feel like a network hop
        // POST appends to the fake data — visible on the next GET.
        FakeStore.shared.celebrations[fixtureId, default: [:]][teamId, default: 0] += taps
        NSLog("🧪 FakeBackend: +%d celebrations for %@ in fixture %d (total %d)",
              taps, teamId, fixtureId,
              FakeStore.shared.celebrations[fixtureId]?[teamId] ?? 0)
    }

    func deleteAccount() async throws {
        FakeStore.shared.celebrations = [:]
    }
}

@MainActor
final class FakeScores: ScoresProviding {
    func fetchCatalog() async throws -> Catalog { FakeScores.demoCatalog }
    func fetchFixtures(date: Date) async throws -> [Fixture] {
        FakeStore.shared.todayFixtures + FakeStore.shared.liveFixtures
    }
    func fetchFixture(fixtureId: Int) async throws -> Fixture {
        guard let fixture = FakeStore.shared.allFixtures.first(where: { $0.fixtureId == fixtureId }) else {
            throw URLError(.fileDoesNotExist)
        }
        return fixture
    }
    func fetchCelebrations(fixtureId: Int) async throws -> [String: Int] {
        // Production fetches this from the CDN after the batched POST lands
        // in the DB — simulate that beat so dev timing matches reality.
        try? await Task.sleep(for: .milliseconds(450))
        return FakeStore.shared.celebrations[fixtureId] ?? [:]
    }

    /// Multi-league catalog for the picker: World Cup is active/selectable; a
    /// coming-soon club league shows greyed; one league is "not scheduled".
    static let demoCatalog: Catalog = {
        func team(_ id: Int, _ name: String, _ code: String, _ league: Int) -> Team {
            Team(id: id, name: name, code: code, logo: TeamCatalog.logoURL(id), leagueId: league)
        }
        func leagueLogo(_ id: Int) -> String { "https://media.api-sports.io/football/leagues/\(id).png" }
        return Catalog(
            leagues: [
                League(id: 1, name: "World Cup", logo: leagueLogo(1), active: true, scheduled: true, season: 2026),
                League(id: 39, name: "Premier League", logo: leagueLogo(39), active: false, scheduled: true, season: 2025),
                League(id: 78, name: "Bundesliga", logo: leagueLogo(78), active: false, scheduled: false, season: nil),
            ],
            teams: [
                "1": [
                    team(6,    "Brazil",       "BRA", 1), team(26,   "Argentina",  "ARG", 1),
                    team(10,   "England",      "ENG", 1), team(2384, "United States", "USA", 1),
                    team(2,    "France",       "FRA", 1), team(25,   "Germany",    "GER", 1),
                    team(9,    "Spain",        "ESP", 1), team(27,   "Portugal",   "POR", 1),
                    team(3,    "Croatia",      "CRO", 1), team(775,  "Austria",    "AUT", 1),
                    team(1548, "Jordan",       "JOR", 1), team(1508, "Congo DR",   "COD", 1),
                    team(1504, "Ghana",        "GHA", 1), team(11,   "Panama",     "PAN", 1),
                    team(1568, "Uzbekistan",   "UZB", 1), team(8,   "Colombia",   "COL", 1),
                ],
                "39": [
                    team(33, "Manchester United", "MUN", 39), team(40, "Liverpool", "LIV", 39),
                    team(42, "Arsenal", "ARS", 39), team(50, "Manchester City", "MCI", 39),
                ],
                "78": [],
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
    /// before the timeline proper. Uses one match (FRA vs GER) and only the
    /// opponent (GER) side for goal-type events, so each shows as a notch PILL
    /// rather than a fan-goal celebration — the point here is to preview the
    /// pills. Scores are coherent so the subtitle row reads sensibly, and a
    /// shootout decides it so full-time shows the "won on pens" variant.
    private func runShowcase() async {
        let f = DemoFixture.fraGer
        let beats: [DemoMoment] = [
            DemoMoment(at: 0, f, minute: 1,   .kickoff),
            DemoMoment(at: 0, f, minute: 9,   .goal(.away, player: "Musiala")),       // GER 0–1 → goal pill
            DemoMoment(at: 0, f, minute: 20,  .yellowCard(.away, player: "Rüdiger")),
            DemoMoment(at: 0, f, minute: 24,  .goalDisallowed(.away)),                // VAR → back to 0–0
            DemoMoment(at: 0, f, minute: 33,  .goal(.away, player: "Havertz")),       // GER 0–1 again, for a leader
            DemoMoment(at: 0, f, minute: 41,  .redCard(.away, player: "Tah")),
            DemoMoment(at: 0, f, minute: 45,  .halfTime),                             // "Germany ahead"
            DemoMoment(at: 0, f, minute: 91,  .extraTime),
            DemoMoment(at: 0, f, minute: 120, .penaltyShootout),
            DemoMoment(at: 0, f, minute: 120, .penaltyKick(.home, player: "Mbappé", scored: true)),  // pens 1–0
            DemoMoment(at: 0, f, minute: 120, .penaltyKick(.away, player: "Sané",   scored: false)), // missed ✗
            DemoMoment(at: 0, f, minute: 120, .fullTime),                             // "France won on pens"
        ]
        FakeStore.shared.resetMatches()
        publishAllFixtures()
        for beat in beats {
            if Task.isCancelled { return }
            fire(beat)
            try? await Task.sleep(for: .seconds(DevConfig.showcaseSpacing))
        }
    }

    /// Steps ONE fixture through every right-edge clock label so the whole
    /// sequence can be eyeballed in the menu + capsule:
    ///   10′ → 45+′ → HT → 59′ → 90+1′ → 90+′ → BT → ET 92′ → ET HT → ET 116′ → ET 120+′ → FT
    /// then fires an empty-name goal (subject falls back to the team, not a
    /// blank) and a disallow→re-award cycle (the "Goal disallowed" pill, then
    /// the re-awarded GOAL pill must actually show).
    private func runClockLabelWalk() async {
        let f = DemoFixture.engCro
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
        func show(_ raw: String, _ minute: Int?, extra: Int? = nil) async {
            guard var st = FakeStore.shared.states[id] else { return }
            st.rawStatus = raw
            st.minute = minute
            st.extra = extra
            st.status = statusFor(raw)
            FakeStore.shared.states[id] = st
            publishFixture(f)
            NSLog("🧪 clock-walk: raw=%@ minute=%@ extra=%@", raw,
                  minute.map(String.init) ?? "-", extra.map(String.init) ?? "-")
            try? await Task.sleep(for: .seconds(DevConfig.showcaseSpacing))
        }

        // (rawStatus, minute, extra) → the label each row should produce.
        let steps: [(String, Int?, Int?)] = [
            ("1H", 10, nil),   // 10′
            ("1H", 45, nil),   // 45+′   (at the cap, no extra → unknown stoppage)
            ("HT", 45, nil),   // HT
            ("2H", 59, nil),   // 59′
            ("2H", 90, 1),     // 90+1′  (known stoppage)
            ("2H", 90, nil),   // 90+′   (extra cleared → unknown stoppage)
            ("BT", 90, nil),   // BT     (FT→ET setup break)
            ("ET", 92, nil),   // ET 92′
            ("BT", 105, nil),  // ET HT  (between the two ET halves)
            ("ET", 116, nil),  // ET 116′
            ("ET", 120, nil),  // ET 120+′ (at the cap, no extra)
            ("FT", 120, nil),  // FT
        ]
        for (raw, minute, extra) in steps {
            if Task.isCancelled { return }
            await show(raw, minute, extra: extra)
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
        FakeStore.shared.addGoal(.home, in: id, player: "Harry Kane", minute: 74)
        push(.goal, f, side: .home, player: "Harry Kane", minute: 74)
        publishFixture(f)
        try? await Task.sleep(for: .seconds(DevConfig.showcaseSpacing))
    }

    private func playThrough() async {
        FakeStore.shared.resetMatches()
        publishAllFixtures()
        firedCount = 0
        let start = Date()
        for moment in DevConfig.timeline {
            let wait = start.addingTimeInterval(moment.at).timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            if Task.isCancelled { return }
            fire(moment)
            firedCount += 1
        }
    }

    private func fire(_ moment: DemoMoment) {
        let store = FakeStore.shared
        let def = moment.fixture
        let id = def.id
        switch moment.action {
        case .kickoff:
            store.states[id]?.status = "LIVE"
            store.states[id]?.rawStatus = "1H"
            store.states[id]?.minute = moment.minute
            push(.kickoff, def, minute: moment.minute)
        case let .goal(side, player, kind):
            store.states[id]?.status = "LIVE"
            store.states[id]?.rawStatus = "1H"
            store.states[id]?.minute = moment.minute
            store.addGoal(side, in: id, player: player, minute: moment.minute, kind: kind)
            push(.goal, def, side: side, player: player, minute: moment.minute, goalKind: kind)
        case let .goalDisallowed(side):
            store.states[id]?.minute = moment.minute
            store.removeGoal(side, in: id)
            push(.goalCancelled, def, side: side, minute: moment.minute)
        case let .yellowCard(side, player):
            store.states[id]?.minute = moment.minute
            store.addCard(side, red: false, in: id, player: player, minute: moment.minute)
            push(.yellowCard, def, side: side, player: player, minute: moment.minute)
        case let .redCard(side, player):
            store.states[id]?.minute = moment.minute
            store.addCard(side, red: true, in: id, player: player, minute: moment.minute)
            push(.redCard, def, side: side, player: player, minute: moment.minute)
        case let .substitution(side, playerIn, playerOut):
            store.states[id]?.minute = moment.minute
            store.addSub(side, in: id, playerIn: playerIn, playerOut: playerOut, minute: moment.minute)
            push(.substitution, def, side: side, player: playerIn, minute: moment.minute,
                 playerOut: playerOut)
        case let .varDecision(side, detail):
            store.states[id]?.minute = moment.minute
            let teamId = side == .home ? def.home.id : def.away.id
            store.addVar(in: id, teamId: teamId, detail: detail, minute: moment.minute)
            push(.varDecision, def, side: side, minute: moment.minute, varDetail: detail)
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
        case let .celebrationSurge(totals):
            store.celebrations[id] = totals
            AppSession.shared.mergeCelebrationTotals(totals, fixtureId: id)
        }
        publishFixture(def)
    }

    /// Build the `MatchEvent` the poll-diff would have produced for this moment
    /// and route it straight to the overlays (the dev fake stands in for the
    /// poll loop). The scoreline comes from the store, which `fire` already
    /// updated.
    private func push(_ type: MatchEventType, _ def: DemoFixture,
                      side: DemoSide? = nil, player: String? = nil, minute: Int,
                      scored: Bool? = nil, goalKind: String? = nil,
                      playerOut: String? = nil, varDetail: String? = nil) {
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
        AppSession.shared.applyLiveFixture(FakeStore.shared.fixture(def))
        AppSession.shared.publishFixtures()
    }

    private func publishAllFixtures() {
        for fixture in FakeStore.shared.allFixtures {
            AppSession.shared.applyLiveFixture(fixture)
        }
        AppSession.shared.publishFixtures()
    }
}
#endif
