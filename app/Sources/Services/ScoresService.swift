import Foundation

/// Real ScoresProviding: reads CDN-cached JSON from the configured environment's
/// R2 custom domain behind Cloudflare. Cheap at any scale — requests hit edge
/// cache, not our origin.
@MainActor
struct CDNScoresClient: ScoresProviding {
    private func fetch<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        let url = AppEnvironment.scoresBase.appending(path: path)
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData // CDN handles caching
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode
        if status == 404 { throw ScoresError.notFound }
        guard status == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func fetchCatalog() async throws -> Catalog {
        try await fetch("catalog.json", as: Catalog.self)
    }

    func fetchFixtures(date: Date) async throws -> [Fixture] {
        let day = ISO8601DateFormatter.dateOnly.string(from: date)
        return try await fetch("fixtures-\(day).json", as: FixturesPayload.self).matches
    }

    func fetchCelebrations(fixtureId: Int) async throws -> [String: Int] {
        do {
            return try await fetch("celebrate/\(fixtureId).json", as: CelebrationTotals.self).totals
        } catch ScoresError.notFound {
            return [:]
        }
    }

    func fetchBackupConfig() async throws -> BackupConfig {
        try await fetch("config.json", as: BackupConfig.self)
    }
}

private enum ScoresError: Error {
    case notFound
}

struct BackupConfig: Codable {
    let killSwitch: Bool?
    let message: String?
    let minBuild: Int?
    let autoRefreshEnabled: Bool?
    let autoRefreshSeconds: Double?
}

extension ISO8601DateFormatter {
    static let dateOnly: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f
    }()
}
