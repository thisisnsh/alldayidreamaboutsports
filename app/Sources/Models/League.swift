import Foundation

/// A competition in the catalog. `active` = users can follow its teams now;
/// everything else shows in the picker as "Coming soon". `scheduled` = it has
/// an ongoing or upcoming season (so it has teams); false → "Not scheduled".
struct League: Codable, Identifiable, Hashable {
    let id: Int
    let name: String
    let logo: String
    let active: Bool
    let scheduled: Bool
    let season: Int?
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
