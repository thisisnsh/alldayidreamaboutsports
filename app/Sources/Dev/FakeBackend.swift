#if DEV_BACKEND
import AppKit
import Foundation

// Fake service layer for development: compiled only when DEV_BACKEND is set
// (Debug builds). GETs return seeded hardcoded data; POSTs mutate that data in
// memory, so round-trips behave like the real system — without touching the
// network, your API-Football quota, or Google sign-in.

/// Shared mutable state behind all the fakes.
@MainActor
final class FakeStore {
    static let shared = FakeStore()

    var prefs = UserPrefs(
        fanOf: ["football": ["1": DevConfig.fanTeams]],
        settings: PrefSettings(theme: .system, notifications: ["goals": true])
    )

    /// Seeded so the popover/counts have something to show immediately.
    var celebrations: [Int: [String: Int]] = [
        1001: ["BRA": 2_340_000, "USA": 412_000],
    ]

    let liveFixture = Fixture(
        fixtureId: 1001, leagueId: 1,
        kickoffISO: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-73 * 60)),
        status: "LIVE", minute: 73,
        home: ScoreboardTeam(code: "BRA", name: "Brazil", goals: 2),
        away: ScoreboardTeam(code: "USA", name: "United States", goals: 1)
    )

    var todayFixtures: [Fixture] {
        [
            liveFixture,
            Fixture(fixtureId: 1002, leagueId: 1,
                    kickoffISO: ISO8601DateFormatter().string(from: Date().addingTimeInterval(2 * 3600)),
                    status: "SCHEDULED", minute: nil,
                    home: ScoreboardTeam(code: "GER", name: "Germany", goals: 0),
                    away: ScoreboardTeam(code: "JPN", name: "Japan", goals: 0)),
            Fixture(fixtureId: 1003, leagueId: 1,
                    kickoffISO: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-5 * 3600)),
                    status: "FINISHED", minute: 90,
                    home: ScoreboardTeam(code: "ARG", name: "Argentina", goals: 3),
                    away: ScoreboardTeam(code: "MEX", name: "Mexico", goals: 0)),
        ]
    }
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

    func celebrate(fixtureId: Int, teamCode: String, taps: Int) async throws {
        try? await Task.sleep(for: .milliseconds(250)) // feel like a network hop
        // POST appends to the fake data — visible on the next GET.
        FakeStore.shared.celebrations[fixtureId, default: [:]][teamCode, default: 0] += taps
        NSLog("🧪 FakeBackend: +%d celebrations for %@ in fixture %d (total %d)",
              taps, teamCode, fixtureId,
              FakeStore.shared.celebrations[fixtureId]?[teamCode] ?? 0)
    }

    func deleteAccount() async throws {
        FakeStore.shared.prefs = .empty
        FakeStore.shared.celebrations = [:]
    }
}

@MainActor
final class FakeScores: ScoresProviding {
    func fetchTeams() async throws -> [Team] { TeamCatalog.fallback }
    func fetchLive() async throws -> [Fixture] { [FakeStore.shared.liveFixture] }
    func fetchTodayFixtures() async throws -> [Fixture] { FakeStore.shared.todayFixtures }
    func fetchCelebrations(fixtureId: Int) async throws -> [String: Int] {
        // Production fetches this from the CDN after the batched POST lands
        // in the DB — simulate that beat so dev timing matches reality.
        try? await Task.sleep(for: .milliseconds(450))
        return FakeStore.shared.celebrations[fixtureId] ?? [:]
    }
    func fetchBackupConfig() async throws -> BackupConfig {
        BackupConfig(killSwitch: false, message: nil, minBuild: nil)
    }
}

/// Buttons in Settings → Developer. Simulates the FCM pushes the backend would
/// send, exercising the full EventRouter → OverlayManager pipeline.
@MainActor
enum DevSimulator {
    private static var goalCount = 2

    private static func base(_ type: String, team: String?, player: String?, minute: Int) -> [String: Any] {
        let fixture = FakeStore.shared.liveFixture
        var data: [String: Any] = [
            "kind": "match_event",
            "eventId": "dev:\(type):\(Date().timeIntervalSince1970)",
            "type": type,
            "fixtureId": String(fixture.fixtureId),
            "leagueId": "1",
            "homeTeam": fixture.home.code, "awayTeam": fixture.away.code,
            "homeName": fixture.home.name, "awayName": fixture.away.name,
            "homeGoals": String(goalCount), "awayGoals": "1",
            "minute": String(minute),
        ]
        data["teamCode"] = team ?? ""
        data["player"] = player ?? ""
        return data
    }

    /// Goal for the user's first followed team (so the full celebration runs).
    static func fanGoal() {
        goalCount += 1
        let team = AppSession.shared.prefs.footballTeams.first ?? "BRA"
        EventRouter.shared.handlePush(base("GOAL", team: team, player: "Vinícius Jr", minute: 73))
    }

    static func opponentGoal() {
        EventRouter.shared.handlePush(base("GOAL", team: "USA", player: "Pulisic", minute: 74))
    }

    static func yellowCard() {
        EventRouter.shared.handlePush(base("YELLOW_CARD", team: "USA", player: "Adams", minute: 38))
    }

    static func varCancelled() {
        goalCount = max(goalCount - 1, 0)
        let team = AppSession.shared.prefs.footballTeams.first ?? "BRA"
        EventRouter.shared.handlePush(base("GOAL_CANCELLED", team: team, player: nil, minute: 75))
    }

    static func fullTime() {
        EventRouter.shared.handlePush(base("FULL_TIME", team: nil, player: nil, minute: 90))
    }

    static func countPush() {
        let fixture = FakeStore.shared.liveFixture
        EventRouter.shared.handlePush([
            "kind": "celebration_count",
            "fixtureId": String(fixture.fixtureId),
            "totals": "{\"BRA\": \(Int.random(in: 2_000_000...9_000_000)), \"USA\": 412000}",
        ])
    }

    // MARK: Auto loop — random events on a timer (knobs in DevConfig)

    private static var autoTimer: Timer?
    static private(set) var autoLoopRunning = false

    static func startAutoLoop() {
        guard !autoLoopRunning else { return }
        autoLoopRunning = true
        scheduleNext(after: DevConfig.firstAutoEventAfterSeconds)
        NSLog("🧪 DevSimulator: auto events ON (first in %.0fs, then every %.0f–%.0fs)",
              DevConfig.firstAutoEventAfterSeconds,
              DevConfig.autoEventIntervalSeconds.lowerBound,
              DevConfig.autoEventIntervalSeconds.upperBound)
    }

    static func stopAutoLoop() {
        autoTimer?.invalidate()
        autoTimer = nil
        autoLoopRunning = false
        NSLog("🧪 DevSimulator: auto events OFF")
    }

    private static func scheduleNext(after seconds: Double? = nil) {
        let delay = seconds ?? Double.random(in: DevConfig.autoEventIntervalSeconds)
        autoTimer?.invalidate()
        autoTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            Task { @MainActor in
                guard autoLoopRunning else { return }
                fireWeightedRandomEvent()
                scheduleNext()
            }
        }
    }

    private static func fireWeightedRandomEvent() {
        let total = DevConfig.autoEventWeights.reduce(0) { $0 + $1.weight }
        var roll = Int.random(in: 0 ..< max(total, 1))
        for entry in DevConfig.autoEventWeights {
            roll -= entry.weight
            if roll < 0 {
                entry.fire()
                return
            }
        }
    }
}
#endif
