import AppKit
import Foundation
import GoogleSignIn

// The app talks to the outside world only through these three interfaces.
// Debug builds (SWIFT_ACTIVE_COMPILATION_CONDITIONS includes DEV_BACKEND) get
// fake in-memory implementations: no sign-in, no network, no API quota.
// Release builds get the real ones. Build either flavor locally:
//   xcodebuild -configuration Debug    # fake
//   xcodebuild -configuration Release  # real

@MainActor
protocol GoogleAuthProviding {
    /// Runs the Google sign-in flow and returns an ID token for the backend.
    func signIn(presenting window: NSWindow?) async throws -> String
    func signOut()
}

@MainActor
protocol BackendAPI {
    func signIn(googleIdToken: String) async throws -> SignInResponse
    func fetchPrefs() async throws -> UserPrefs
    func putPrefs(_ prefs: UserPrefs) async throws
    func celebrate(fixtureId: Int, teamId: String, taps: Int) async throws
    func deleteAccount() async throws
}

@MainActor
protocol ScoresProviding {
    func fetchCatalog() async throws -> Catalog
    func fetchLive() async throws -> [Fixture]
    func fetchTodayFixtures() async throws -> [Fixture]
    func fetchCelebrations(fixtureId: Int) async throws -> [String: Int]
    func fetchBackupConfig() async throws -> BackupConfig
}

/// Service locator — the single place where the flavor is decided.
@MainActor
enum Services {
    #if DEV_BACKEND
    static let google: GoogleAuthProviding = FakeGoogleAuth()
    static let api: BackendAPI = FakeBackendAPI()
    static let scores: ScoresProviding = FakeScores()
    static let isDev = true
    #else
    static let google: GoogleAuthProviding = GoogleAuth()
    static let api: BackendAPI = APIClient()
    static let scores: ScoresProviding = CDNScoresClient()
    static let isDev = false
    #endif
}

/// Real Google sign-in via the GoogleSignIn SDK.
@MainActor
final class GoogleAuth: GoogleAuthProviding {
    func signIn(presenting window: NSWindow?) async throws -> String {
        guard let window else {
            throw APIError.http(0, "No window to present Google sign-in from")
        }
        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: window)
        guard let idToken = result.user.idToken?.tokenString else {
            throw APIError.http(0, "Google returned no ID token")
        }
        return idToken
    }

    func signOut() {
        GIDSignIn.sharedInstance.signOut()
    }
}
