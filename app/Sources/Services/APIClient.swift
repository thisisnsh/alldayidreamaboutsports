import Foundation

struct Profile: Codable, Equatable {
    let sub: String
    let email: String?
    let name: String?
    let photoURL: String?
}

struct AppPrefs: Equatable {
    var fanTeamIds: [String]
    var settings: PrefSettings

    static var empty: AppPrefs {
        AppPrefs(fanTeamIds: [], settings: PrefSettings())
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
    /// Pop sound riding along with the confetti burst; only meaningful while
    /// `confetti` is on. off = silent confetti. Preserved across confetti
    /// toggles so re-enabling confetti restores the user's last choice.
    var confettiSound: Bool?
    /// Size of pinned score capsules (fonts + logos). nil = medium.
    var capsuleSize: CapsuleSize?
    /// Vertical screen edge for pinned capsules. nil = top.
    var capsulePosition: CapsulePosition?
}

struct SignInResponse: Codable {
    let token: String
    let profile: Profile
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
        let started = ContinuousClock.now
        AppLog.debug(.api, "request_start method=\(method) host=\(req.url?.host ?? "unknown") path=\(path) authorized=\(authorized)")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let duration = started.duration(to: .now).milliseconds
            guard (200..<300).contains(status) else {
                let error = APIError.http(status, String(data: data, encoding: .utf8) ?? "")
                AppLog.error(.api, "request_failed method=\(method) path=\(path) status=\(status) duration_ms=\(duration) bytes=\(data.count)", error: error)
                throw error
            }
            AppLog.info(.api, "request_complete method=\(method) path=\(path) status=\(status) duration_ms=\(duration) bytes=\(data.count)")
            return data
        } catch {
            if error is APIError { throw error }
            AppLog.error(.api, "request_failed method=\(method) path=\(path) duration_ms=\(started.duration(to: .now).milliseconds)", error: error)
            throw error
        }
    }

    func signIn(googleIdToken: String) async throws -> SignInResponse {
        struct Body: Encodable { let idToken: String }
        let data = try await request("/auth/signin", method: "POST",
                                     body: Body(idToken: googleIdToken), authorized: false)
        return try JSONDecoder().decode(SignInResponse.self, from: data)
    }

    func celebrate(fixtureId: Int, teamId: String, taps: Int) async throws {
        struct Body: Encodable { let fixtureId: Int; let teamId: String; let taps: Int }
        _ = try await request("/celebrate", method: "POST",
                              body: Body(fixtureId: fixtureId, teamId: teamId, taps: taps))
    }

    func deleteAccount() async throws {
        _ = try await request("/me", method: "DELETE")
    }
}
