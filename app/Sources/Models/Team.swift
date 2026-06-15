import Foundation

/// A team, sourced from the API-Football catalog. Identity is the numeric `id`
/// (stable across leagues, used in FCM topics `l{league}_{id}`, the `fanOf`
/// store and celebration counters). Shown everywhere as its `logo` — no emoji.
struct Team: Codable, Identifiable, Hashable {
    let id: Int
    let name: String
    let code: String? // API 3-letter code (display only; not always a FIFA trigram)
    let logo: String // CDN URL
    let leagueId: Int
}

enum TeamCatalog {
    /// Bundled fallback for the active league before catalog.json loads. Tiny on
    /// purpose — the CDN catalog (ScoresService) replaces it at runtime; ids and
    /// logos are real so even the fallback renders correctly.
    static let fallback: [Team] = [
        Team(id: 2, name: "France", code: "FRA", logo: logoURL(2), leagueId: 1),
        Team(id: 6, name: "Brazil", code: "BRA", logo: logoURL(6), leagueId: 1),
        Team(id: 9, name: "Spain", code: "ESP", logo: logoURL(9), leagueId: 1),
        Team(id: 10, name: "England", code: "ENG", logo: logoURL(10), leagueId: 1),
        Team(id: 25, name: "Germany", code: "GER", logo: logoURL(25), leagueId: 1),
        Team(id: 26, name: "Argentina", code: "ARG", logo: logoURL(26), leagueId: 1),
        Team(id: 27, name: "Portugal", code: "POR", logo: logoURL(27), leagueId: 1),
    ]

    static func logoURL(_ id: Int) -> String {
        "https://media.api-sports.io/football/teams/\(id).png"
    }

    /// Placeholder teams for the Settings preview — generic on purpose so the
    /// preview reads as an example, never as a real match. No logo (the logo
    /// view falls back to an SF Symbol).
    static let previewHome = Team(id: 2, name: "France", code: "FRA", logo: logoURL(2), leagueId: 1)
    static let previewAway = Team(id: 26, name: "Argentina", code: "ARG", logo: logoURL(26), leagueId: 1)

    static func team(for id: Int, in teams: [Team]) -> Team {
        if id == previewHome.id { return previewHome }
        if id == previewAway.id { return previewAway }
        return teams.first { $0.id == id }
            ?? Team(id: id, name: String(id), code: nil, logo: "", leagueId: 0)
    }
}
