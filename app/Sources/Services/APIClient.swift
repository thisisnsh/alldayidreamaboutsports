import Foundation

struct Profile: Codable, Equatable {
    let sub: String
    let email: String?
    let name: String?
    let photoURL: String?
}

struct UserPrefs: Codable, Equatable {
    var fanOf: [String: [String: [String]]] // game -> leagueId -> team codes
    var settings: PrefSettings

    static var empty: UserPrefs {
        UserPrefs(fanOf: ["football": ["1": []]], settings: PrefSettings())
    }

    var footballTeams: [String] {
        get { fanOf["football"]?[String(AppEnvironment.leagueId)] ?? [] }
        set { fanOf["football", default: [:]][String(AppEnvironment.leagueId)] = newValue }
    }
}

struct PrefSettings: Codable, Equatable {
    var launchAtLogin: Bool?
    var theme: ThemeChoice?
    /// Per-event-type switches for the notch pills; missing key = enabled.
    var notifications: [String: Bool]?
    /// The ball + scoreboard centerpiece on fan-team goals; off = fan goals
    /// use the notch pill like every other event.
    var goalCenter: Bool?
    /// Confetti burst on fan-team goals (with either style).
    var confetti: Bool?
}

struct SignInResponse: Codable {
    let token: String
    let profile: Profile
    let prefs: UserPrefs
}

enum APIError: LocalizedError {
    case http(Int, String)
    var errorDescription: String? {
        if case let .http(code, body) = self { return "HTTP \(code): \(body)" }
        return nil
    }
}

/// Real BackendAPI: thin client for the Cloud Run backend. Session token
/// comes from Keychain.
@MainActor
struct APIClient: BackendAPI {
    var base: URL = AppEnvironment.apiBase

    private func request(_ path: String, method: String = "GET", body: Encodable? = nil,
                         authorized: Bool = true) async throws -> Data {
        var req = URLRequest(url: base.appending(path: path))
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authorized, let token = Keychain.get("sessionToken") {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            req.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw APIError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    func signIn(googleIdToken: String) async throws -> SignInResponse {
        struct Body: Encodable { let idToken: String }
        let data = try await request("/auth/signin", method: "POST",
                                     body: Body(idToken: googleIdToken), authorized: false)
        return try JSONDecoder().decode(SignInResponse.self, from: data)
    }

    func fetchPrefs() async throws -> UserPrefs {
        struct Wrapper: Codable { let prefs: UserPrefs }
        let data = try await request("/me/prefs")
        return try JSONDecoder().decode(Wrapper.self, from: data).prefs
    }

    func putPrefs(_ prefs: UserPrefs) async throws {
        _ = try await request("/me/prefs", method: "PUT", body: prefs)
    }

    func celebrate(fixtureId: Int, teamCode: String, taps: Int) async throws {
        struct Body: Encodable { let fixtureId: Int; let teamCode: String; let taps: Int }
        _ = try await request("/celebrate", method: "POST",
                              body: Body(fixtureId: fixtureId, teamCode: teamCode, taps: taps))
    }

    func deleteAccount() async throws {
        _ = try await request("/me", method: "DELETE")
    }
}
