#if DEV_BACKEND
import AppKit
import Foundation

// Fake service layer for development: compiled only when DEV_BACKEND is set
// (Debug builds). GETs return seeded hardcoded data; POSTs mutate that data in
// memory, so round-trips behave like the real system — without touching the
// network, your API-Football quota, or Google sign-in. Each parallel match's
// score is walked through DevConfig.timeline by DemoEngine, so what the popover
// shows always matches the events that have fired.

/// Per-match live state the demo timeline mutates.
struct LiveMatchState {
    var homeGoals = 0
    var awayGoals = 0
    var minute: Int?
    var status = "SCHEDULED"
    // Set once a shootout starts so the scoreboard can show the pen tally.
    var penHome: Int?
    var penAway: Int?
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

    // Unique per app launch. EventRouter's dedupe list (handledEventIds)
    // persists in UserDefaults, but `eventSeq` restarts at 0 each launch — so
    // without this every fresh run regenerates ids it already saw last run and
    // they all get rejected as duplicates. Stamping the launch keeps each run's
    // events new.
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

    func addGoal(_ side: DemoSide, in id: Int) {
        if side == .home { states[id]?.homeGoals += 1 } else { states[id]?.awayGoals += 1 }
    }

    func removeGoal(_ side: DemoSide, in id: Int) {
        guard var state = states[id] else { return }
        if side == .home { state.homeGoals = max(state.homeGoals - 1, 0) }
        else { state.awayGoals = max(state.awayGoals - 1, 0) }
        states[id] = state
    }

    /// Record a shootout kick: a scored kick bumps that side's pen tally; the
    /// pens always become non-nil so the scoreboard switches to showing them.
    func addPenalty(_ side: DemoSide, scored: Bool, in id: Int) {
        guard var state = states[id] else { return }
        state.penHome = state.penHome ?? 0
        state.penAway = state.penAway ?? 0
        if scored {
            if side == .home { state.penHome! += 1 } else { state.penAway! += 1 }
        }
        states[id] = state
    }

    /// A fixture rebuilt from its current demo state — kickoff is back-dated
    /// to match the on-screen minute.
    func fixture(_ def: DemoFixture) -> Fixture {
        let s = states[def.id] ?? LiveMatchState()
        let kickoff = Date().addingTimeInterval(-Double(s.minute ?? 0) * 60)
        let shootout = (s.penHome != nil || s.penAway != nil)
            ? Shootout(home: s.penHome ?? 0, away: s.penAway ?? 0) : nil
        let running = s.status == "LIVE"
        let period: MatchPeriod = {
            switch s.status {
            case "LIVE": return .first
            case "HALF_TIME": return .half
            case "FINISHED": return .finished
            default: return .notStarted
            }
        }()
        let rawStatus: String = {
            switch s.status {
            case "LIVE": return "1H"
            case "HALF_TIME": return "HT"
            case "FINISHED": return "FT"
            default: return "NS"
            }
        }()
        return Fixture(
            fixtureId: def.id, leagueId: def.leagueId, round: def.round,
            kickoffISO: ISO8601DateFormatter().string(from: kickoff),
            status: s.status, rawStatus: rawStatus, minute: s.minute,
            extra: nil, period: period, running: running,
            home: ScoreboardTeam(id: def.home.id, name: def.home.name, goals: s.homeGoals),
            away: ScoreboardTeam(id: def.away.id, name: def.away.name, goals: s.awayGoals),
            shootout: shootout
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
                    team(6, "Brazil", "BRA", 1), team(26, "Argentina", "ARG", 1),
                    team(10, "England", "ENG", 1), team(2384, "United States", "USA", 1),
                    team(2, "France", "FRA", 1), team(25, "Germany", "GER", 1),
                    team(9, "Spain", "ESP", 1), team(27, "Portugal", "POR", 1),
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
        for beat in beats {
            if Task.isCancelled { return }
            fire(beat)
            try? await Task.sleep(for: .seconds(DevConfig.showcaseSpacing))
        }
    }

    private func playThrough() async {
        FakeStore.shared.resetMatches()
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
            store.states[id]?.minute = moment.minute
            push(.kickoff, def, minute: moment.minute)
        case let .goal(side, player):
            store.states[id]?.status = "LIVE"
            store.states[id]?.minute = moment.minute
            store.addGoal(side, in: id)
            push(.goal, def, side: side, player: player, minute: moment.minute)
        case let .goalDisallowed(side):
            store.states[id]?.minute = moment.minute
            store.removeGoal(side, in: id)
            push(.goalCancelled, def, side: side, minute: moment.minute)
        case let .yellowCard(side, player):
            store.states[id]?.minute = moment.minute
            push(.yellowCard, def, side: side, player: player, minute: moment.minute)
        case let .redCard(side, player):
            store.states[id]?.minute = moment.minute
            push(.redCard, def, side: side, player: player, minute: moment.minute)
        case .halfTime:
            store.states[id]?.status = "HALF_TIME"
            store.states[id]?.minute = moment.minute
            push(.halfTime, def, minute: moment.minute)
        case .fullTime:
            store.states[id]?.status = "FINISHED"
            store.states[id]?.minute = moment.minute
            push(.fullTime, def, minute: moment.minute)
        case .extraTime:
            store.states[id]?.minute = moment.minute
            push(.extraTime, def, minute: moment.minute)
        case .penaltyShootout:
            store.states[id]?.minute = moment.minute
            push(.penaltyShootout, def, minute: moment.minute)
        case let .penaltyKick(side, player, scored):
            store.states[id]?.minute = moment.minute
            store.addPenalty(side, scored: scored, in: id)
            push(.penaltyKick, def, side: side, player: player, minute: moment.minute, scored: scored)
        case let .celebrationSurge(totals):
            store.celebrations[id] = totals
            AppSession.shared.mergeCelebrationTotals(totals, fixtureId: id)
        }
    }

    /// Build the `MatchEvent` the poll-diff would have produced for this moment
    /// and route it straight to the overlays (the dev fake stands in for the
    /// poll loop). The scoreline comes from the store, which `fire` already
    /// updated.
    private func push(_ type: MatchEventType, _ def: DemoFixture,
                      side: DemoSide? = nil, player: String? = nil, minute: Int,
                      scored: Bool? = nil) {
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
            scored: scored
        )
        store.eventSeq += 1
        EventRouter.shared.route(event)
    }
}
#endif
