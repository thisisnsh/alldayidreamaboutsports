import Foundation

/// A competition in the catalog. `active` = users can follow its teams now;
/// everything else shows in the picker as "Coming soon". `scheduled` = it has
/// an ongoing or upcoming season (so it has teams); false → "Not scheduled".
/// `ended` = its season is over — archived, still listed, never polled.
struct League: Codable, Identifiable, Hashable {
    let id: Int
    let name: String
    let logo: String
    /// Where it's played — "World" for international cups. Groups the picker.
    let country: String?
    let active: Bool
    let scheduled: Bool
    let season: Int?
    /// Absent from catalogs published before the multi-league switch, which is
    /// why it decodes as optional: a stale catalog.json must not fail to parse
    /// and leave the picker empty.
    private let endedFlag: Bool?

    /// True when the competition is over. The World Cup stays in the catalog
    /// after the final so a saved national team keeps its name and crest.
    var ended: Bool { endedFlag ?? false }

    init(
        id: Int,
        name: String,
        logo: String,
        country: String? = nil,
        active: Bool,
        scheduled: Bool,
        season: Int?,
        ended: Bool = false
    ) {
        self.id = id
        self.name = name
        self.logo = logo
        self.country = country
        self.active = active
        self.scheduled = scheduled
        self.season = season
        self.endedFlag = ended
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, logo, country, active, scheduled, season
        case endedFlag = "ended"
    }

    /// Names for the supported competitions, for the moment before catalog.json
    /// lands (the menu labels every fixture row with its league, and the
    /// bundled team fallback has to resolve to something). The CDN catalog
    /// replaces these as soon as it loads.
    static let fallbackNames: [Int: String] = [
        39: "Premier League",
        140: "La Liga",
        135: "Serie A",
        78: "Bundesliga",
        61: "Ligue 1",
        1: "World Cup",
    ]
}

/// The full leagues + teams catalog (catalog.json), refreshed daily by the
/// backend from API-Football. `teams` is keyed by league id as a string to
/// match the JSON.
struct Catalog: Codable {
    let leagues: [League]
    let teams: [String: [Team]]

    enum ValidationError: Error { case duplicateLeague, duplicateTeam, excessiveRows }

    func validated() throws -> Catalog {
        guard leagues.count <= 100, teams.count <= 100,
              teams.values.allSatisfy({ $0.count <= 500 }) else { throw ValidationError.excessiveRows }
        guard Set(leagues.map(\.id)).count == leagues.count else { throw ValidationError.duplicateLeague }
        for rows in teams.values {
            guard Set(rows.map(\.id)).count == rows.count else { throw ValidationError.duplicateTeam }
        }
        return self
    }

    func teams(for leagueId: Int) -> [Team] {
        teams[String(leagueId)] ?? []
    }
}
