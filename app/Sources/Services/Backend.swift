import Foundation

// The app talks to the outside world only through the scores interface.
// Debug builds (SWIFT_ACTIVE_COMPILATION_CONDITIONS includes DEV_BACKEND) get
// fake in-memory implementations: no network, no API quota.
// Release builds get the real ones. Build either flavor locally:
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
    #if DEV_BACKEND
    static let scores: ScoresProviding = FakeScores()
    static let isDev = true
    #else
    static let scores: ScoresProviding = CDNScoresClient()
    static let isDev = false
    #endif
}
