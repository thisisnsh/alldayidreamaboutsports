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

    var prefs = UserPrefs(
        fanOf: ["football": ["1": DevConfig.fanTeams]],
        settings: PrefSettings(theme: .system, notifications: ["goals": true])
    )

    // Live state per match, keyed by fixture id. DemoEngine walks each one
    // through the script so every scoreboard stays in step with its pills.
    // `eventSeq` is monotonic (never reset) so replays keep producing fresh
    // eventIds that EventRouter won't dedupe away.
    var states: [Int: LiveMatchState] = FakeStore.freshStates()
    var eventSeq = 0

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
        return Fixture(
            fixtureId: def.id, leagueId: def.leagueId, round: def.round,
            kickoffISO: ISO8601DateFormatter().string(from: kickoff),
            status: s.status, minute: s.minute,
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
            profile: DevConfig.profile,
            prefs: FakeStore.shared.prefs
        )
    }

    func fetchPrefs() async throws -> UserPrefs {
        FakeStore.shared.prefs
    }

    func putPrefs(_ prefs: UserPrefs) async throws {
        FakeStore.shared.prefs = prefs
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
        FakeStore.shared.prefs = .empty
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
    func fetchBackupConfig() async throws -> BackupConfig {
        BackupConfig(killSwitch: false, message: nil, minBuild: nil,
                     autoRefreshEnabled: nil, autoRefreshSeconds: nil)
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
            repeat {
                await playThrough()
            } while DevConfig.loops && !Task.isCancelled
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
            EventRouter.shared.handlePush([
                "kind": "celebration_count",
                "fixtureId": String(id),
                "totals": jsonString(totals),
            ])
        }
    }

    /// Build the all-strings FCM data payload the backend publishes for a
    /// match event and hand it to the router. The scoreline comes from the
    /// store, which `fire` already updated.
    private func push(_ type: MatchEventType, _ def: DemoFixture,
                      side: DemoSide? = nil, player: String? = nil, minute: Int,
                      scored: Bool? = nil) {
        let store = FakeStore.shared
        let s = store.states[def.id] ?? LiveMatchState()
        let teamId = side.map { $0 == .home ? def.home.id : def.away.id }
        var data: [String: Any] = [
            "kind": "match_event",
            "eventId": "demo:\(def.id):\(type.rawValue):\(store.eventSeq)",
            "type": type.rawValue,
            "fixtureId": String(def.id),
            "leagueId": String(def.leagueId),
            "homeTeamId": String(def.home.id), "awayTeamId": String(def.away.id),
            "homeName": def.home.name, "awayName": def.away.name,
            "homeGoals": String(s.homeGoals), "awayGoals": String(s.awayGoals),
            "minute": String(minute),
            "teamId": teamId.map(String.init) ?? "",
            "player": player ?? "",
        ]
        // Carry the pen tally on every event once a shootout exists, mirroring
        // the backend (it rides on full-time and every shootout event).
        if let penHome = s.penHome { data["penHome"] = String(penHome) }
        if let penAway = s.penAway { data["penAway"] = String(penAway) }
        if let scored { data["scored"] = String(scored) }
        store.eventSeq += 1
        EventRouter.shared.handlePush(data)
    }

    private func jsonString(_ totals: [String: Int]) -> String {
        guard let data = try? JSONEncoder().encode(totals),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }
}
#endif
