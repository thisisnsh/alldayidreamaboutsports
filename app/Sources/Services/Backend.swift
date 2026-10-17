import Foundation

// The app talks to the outside world only through the scores interface.
// Debug builds (SWIFT_ACTIVE_COMPILATION_CONDITIONS includes DEV_BACKEND) get
// fake in-memory implementations: no network, no API quota.
// Release builds get the real ones — except while DemoMode is on, when they
// read the same fakes. Build either flavor locally:
//   xcodebuild -configuration Debug    # fake
//   xcodebuild -configuration Release  # real

@MainActor
protocol ScoresProviding {
    func fetchCatalog() async throws -> Catalog
    func fetchFixtures(date: Date) async throws -> [Fixture]
    func fetchFixture(fixtureId: Int) async throws -> Fixture
}

/// Service locator — the single place where the flavor is decided.
@MainActor
enum Services {
    private static let demo: ScoresProviding = FakeScores()
    #if DEV_BACKEND
    static var scores: ScoresProviding { demo }
    static let isDev = true
    #else
    private static let live: ScoresProviding = CDNScoresClient()
    static var scores: ScoresProviding { DemoMode.isActive ? demo : live }
    static let isDev = false
    #endif
}
