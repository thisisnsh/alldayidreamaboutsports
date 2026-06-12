import Foundation

/// Real ScoresProviding: reads CDN-cached JSON from
/// scores.alldayidreamaboutsports.com (R2 behind Cloudflare). Cheap at any
/// scale — requests hit edge cache, not our origin.
@MainActor
struct CDNScoresClient: ScoresProviding {
    private func fetch<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        let url = AppEnvironment.scoresBase.appending(path: path)
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData // CDN handles caching
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func fetchTeams() async throws -> [Team] {
        struct Payload: Codable { let teams: [Team] }
        return try await fetch("teams.json", as: Payload.self).teams
    }

    func fetchLive() async throws -> [Fixture] {
        try await fetch("live.json", as: FixturesPayload.self).matches
    }

    func fetchTodayFixtures() async throws -> [Fixture] {
        let day = ISO8601DateFormatter.dateOnly.string(from: Date())
        return try await fetch("fixtures-\(day).json", as: FixturesPayload.self).matches
    }

    func fetchCelebrations(fixtureId: Int) async throws -> [String: Int] {
        try await fetch("celebrate/\(fixtureId).json", as: CelebrationTotals.self).totals
    }

    func fetchBackupConfig() async throws -> BackupConfig {
        try await fetch("config.json", as: BackupConfig.self)
    }
}

struct BackupConfig: Codable {
    let killSwitch: Bool?
    let message: String?
    let minBuild: Int?
    let maxFanTeams: Int?
}

extension ISO8601DateFormatter {
    static let dateOnly: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f
    }()
}
