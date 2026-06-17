import Foundation

/// Real ScoresProviding: reads CDN-cached JSON from the configured environment's
/// R2 custom domain behind Cloudflare. Cheap at any scale — requests hit edge
/// cache, not our origin. Sends `If-None-Match` so an unchanged file comes back
/// as a 304 (no body), which the live poll loop treats as "no change".
@MainActor
struct CDNScoresClient: ScoresProviding {
    private func fetch<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        let url = AppEnvironment.scoresBase.appending(path: path)
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData // CDN handles caching
        // Conditional GET: if the edge has the same object we already hold, it
        // answers 304 and sends no body — cheaper, and we skip re-decoding.
        if let etag = ScoresETagStore.shared.etag(for: path) {
            req.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        let started = ContinuousClock.now
        AppLog.debug(.cdn, "request_start host=\(url.host ?? "unknown") path=\(path)")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode
            let duration = started.duration(to: .now).milliseconds
            if status == 304 {
                AppLog.info(.cdn, "request_complete path=\(path) status=304 duration_ms=\(duration) bytes=0")
                throw ScoresError.notModified
            }
            if status == 404 {
                AppLog.info(.cdn, "request_complete path=\(path) status=404 duration_ms=\(duration) bytes=\(data.count)")
                throw ScoresError.notFound
            }
            guard status == 200 else {
                throw URLError(.badServerResponse)
            }
            let decoded = try JSONDecoder().decode(T.self, from: data)
            if let etag = http?.value(forHTTPHeaderField: "Etag") {
                ScoresETagStore.shared.set(etag, for: path)
            }
            AppLog.info(.cdn, "request_complete path=\(path) status=200 duration_ms=\(duration) bytes=\(data.count)")
            return decoded
        } catch {
            if case ScoresError.notFound = error { throw error }
            if case ScoresError.notModified = error { throw error }
            AppLog.error(.cdn, "request_failed path=\(path) duration_ms=\(started.duration(to: .now).milliseconds)", error: error)
            throw error
        }
    }

    func fetchCatalog() async throws -> Catalog {
        try await fetch("catalog.json", as: Catalog.self)
    }

    func fetchFixtures(date: Date) async throws -> [Fixture] {
        let day = ISO8601DateFormatter.dateOnly.string(from: date)
        return try await fetch("fixtures-\(day).json", as: FixturesPayload.self).matches
    }

    func fetchFixture(fixtureId: Int) async throws -> Fixture {
        try await fetch("matches/\(fixtureId).json", as: Fixture.self)
    }

    func fetchCelebrations(fixtureId: Int) async throws -> [String: Int] {
        do {
            return try await fetch("celebrate/\(fixtureId).json", as: CelebrationTotals.self).totals
        } catch ScoresError.notFound {
            return [:]
        }
    }
}

enum ScoresError: Error {
    case notFound
    /// 304 Not Modified — the file is byte-identical to the last successful read.
    case notModified
}

/// In-memory per-path ETag cache for conditional GETs. Lives for the process —
/// a fresh launch re-fetches everything (and re-seeds baselines) anyway.
@MainActor
final class ScoresETagStore {
    static let shared = ScoresETagStore()
    private var etags: [String: String] = [:]

    func etag(for path: String) -> String? { etags[path] }
    func set(_ etag: String, for path: String) { etags[path] = etag }
    /// Drop every cached ETag so the next read is a full 200 (not a 304 with no
    /// body) — required after the cached fixtures/celebrations are wiped.
    func clear() { etags.removeAll() }
}

extension ISO8601DateFormatter {
    /// Formats a date as `YYYY-MM-DD` in UTC. `fixtures-{date}.json` keys are
    /// UTC dates (the backend writes them that way), so this must stay UTC —
    /// ISO8601DateFormatter defaults to GMT, which is what we want here.
    static let dateOnly: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f
    }()
}

extension Calendar {
    /// Gregorian calendar pinned to UTC, for deriving the UTC day keys used by
    /// `fixtures-{date}.json`. Day arithmetic must happen in the same zone the
    /// keys are formatted in (`ISO8601DateFormatter.dateOnly`, also UTC) — using
    /// the local calendar can yield the wrong UTC day near midnight/DST and miss
    /// the today±1 file. (Display filtering, by contrast, uses the local zone so
    /// "today's fixtures" follows the user's wall clock.)
    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? c.timeZone
        return c
    }()
}
