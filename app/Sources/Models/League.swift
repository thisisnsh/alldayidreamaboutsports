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
}

/// The full leagues + teams catalog (catalog.json), refreshed daily by the
/// backend from API-Football. `teams` is keyed by league id as a string to
/// match the JSON.
struct Catalog: Codable {
    let leagues: [League]
    let teams: [String: [Team]]

    func teams(for leagueId: Int) -> [Team] {
        teams[String(leagueId)] ?? []
    }
}
