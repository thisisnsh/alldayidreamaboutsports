import Foundation

/// A team, sourced from the API-Football catalog. Identity is the numeric `id`
/// (stable across leagues, used in local fan-team prefs and celebration
/// counters). Shown everywhere as its `logo` — no emoji.
struct Team: Codable, Identifiable, Hashable {
    let id: Int
    let name: String
    let code: String? // API 3-letter code (display only; not always a FIFA trigram)
    let logo: String // CDN URL
    let leagueId: Int
}

enum TeamCatalog {
    /// Bundled fallback for the active leagues before catalog.json loads. Tiny on
    /// purpose — the CDN catalog (ScoresService) replaces it at runtime; ids and
    /// logos are real so even the fallback renders correctly.
    static let fallback: [Team] = [
        // Premier League
        Team(id: 33, name: "Manchester United", code: "MUN", logo: logoURL(33), leagueId: 39),
        Team(id: 40, name: "Liverpool", code: "LIV", logo: logoURL(40), leagueId: 39),
        Team(id: 50, name: "Manchester City", code: "MCI", logo: logoURL(50), leagueId: 39),
        Team(id: 42, name: "Arsenal", code: "ARS", logo: logoURL(42), leagueId: 39),
        // La Liga
        Team(id: 541, name: "Real Madrid", code: "MAD", logo: logoURL(541), leagueId: 140),
        Team(id: 529, name: "Barcelona", code: "BAR", logo: logoURL(529), leagueId: 140),
        // Serie A
        Team(id: 496, name: "Juventus", code: "JUV", logo: logoURL(496), leagueId: 135),
        Team(id: 505, name: "Inter", code: "INT", logo: logoURL(505), leagueId: 135),
        Team(id: 489, name: "AC Milan", code: "MIL", logo: logoURL(489), leagueId: 135),
        // Bundesliga
        Team(id: 157, name: "Bayern München", code: "BAY", logo: logoURL(157), leagueId: 78),
        Team(id: 165, name: "Borussia Dortmund", code: "DOR", logo: logoURL(165), leagueId: 78),
        // Ligue 1
        Team(id: 85, name: "Paris Saint Germain", code: "PSG", logo: logoURL(85), leagueId: 61),
        Team(id: 81, name: "Marseille", code: "MAR", logo: logoURL(81), leagueId: 61),
    ]

    /// The fallback keyed the way `AppSession.teamsByLeague` wants it — by each
    /// team's own league, not a single hardcoded competition.
    static let fallbackByLeague: [Int: [Team]] = Dictionary(grouping: fallback, by: \.leagueId)

    static func logoURL(_ id: Int) -> String {
        "https://media.api-sports.io/football/teams/\(id).png"
    }

    /// Placeholder teams for the Settings preview — the most recognisable club
    /// fixture there is, so the preview reads as an example of a real match.
    static let previewHome = Team(id: 541, name: "Real Madrid", code: "MAD", logo: logoURL(541), leagueId: 140)
    static let previewAway = Team(id: 529, name: "Barcelona", code: "BAR", logo: logoURL(529), leagueId: 140)

    static func team(for id: Int, in teams: [Team]) -> Team {
        if id == previewHome.id { return previewHome }
        if id == previewAway.id { return previewAway }
        return teams.first { $0.id == id }
            ?? Team(id: id, name: String(id), code: nil, logo: "", leagueId: 0)
    }
}
