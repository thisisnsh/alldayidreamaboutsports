import Foundation

struct Team: Codable, Identifiable, Hashable {
    let code: String // FIFA trigram — FCM topic suffix (l1_BRA)
    let name: String
    let flag: String // emoji

    var id: String { code }
}

enum TeamCatalog {
    /// Bundled fallback — the CDN's teams.json (refreshed after the March 2026
    /// playoffs) overrides this at runtime via ScoresService.
    static let fallback: [Team] = [
        Team(code: "ALG", name: "Algeria", flag: "🇩🇿"),
        Team(code: "ARG", name: "Argentina", flag: "🇦🇷"),
        Team(code: "AUS", name: "Australia", flag: "🇦🇺"),
        Team(code: "AUT", name: "Austria", flag: "🇦🇹"),
        Team(code: "BEL", name: "Belgium", flag: "🇧🇪"),
        Team(code: "BRA", name: "Brazil", flag: "🇧🇷"),
        Team(code: "CAN", name: "Canada", flag: "🇨🇦"),
        Team(code: "CPV", name: "Cape Verde", flag: "🇨🇻"),
        Team(code: "CIV", name: "Côte d'Ivoire", flag: "🇨🇮"),
        Team(code: "COL", name: "Colombia", flag: "🇨🇴"),
        Team(code: "CRO", name: "Croatia", flag: "🇭🇷"),
        Team(code: "CUW", name: "Curaçao", flag: "🇨🇼"),
        Team(code: "ECU", name: "Ecuador", flag: "🇪🇨"),
        Team(code: "EGY", name: "Egypt", flag: "🇪🇬"),
        Team(code: "ENG", name: "England", flag: "🏴󠁧󠁢󠁥󠁮󠁧󠁿"),
        Team(code: "FRA", name: "France", flag: "🇫🇷"),
        Team(code: "GER", name: "Germany", flag: "🇩🇪"),
        Team(code: "GHA", name: "Ghana", flag: "🇬🇭"),
        Team(code: "HAI", name: "Haiti", flag: "🇭🇹"),
        Team(code: "IRN", name: "Iran", flag: "🇮🇷"),
        Team(code: "JPN", name: "Japan", flag: "🇯🇵"),
        Team(code: "JOR", name: "Jordan", flag: "🇯🇴"),
        Team(code: "KOR", name: "South Korea", flag: "🇰🇷"),
        Team(code: "KSA", name: "Saudi Arabia", flag: "🇸🇦"),
        Team(code: "MAR", name: "Morocco", flag: "🇲🇦"),
        Team(code: "MEX", name: "Mexico", flag: "🇲🇽"),
        Team(code: "NED", name: "Netherlands", flag: "🇳🇱"),
        Team(code: "NOR", name: "Norway", flag: "🇳🇴"),
        Team(code: "NZL", name: "New Zealand", flag: "🇳🇿"),
        Team(code: "PAN", name: "Panama", flag: "🇵🇦"),
        Team(code: "PAR", name: "Paraguay", flag: "🇵🇾"),
        Team(code: "POR", name: "Portugal", flag: "🇵🇹"),
        Team(code: "QAT", name: "Qatar", flag: "🇶🇦"),
        Team(code: "RSA", name: "South Africa", flag: "🇿🇦"),
        Team(code: "SCO", name: "Scotland", flag: "🏴󠁧󠁢󠁳󠁣󠁴󠁿"),
        Team(code: "SEN", name: "Senegal", flag: "🇸🇳"),
        Team(code: "ESP", name: "Spain", flag: "🇪🇸"),
        Team(code: "SUI", name: "Switzerland", flag: "🇨🇭"),
        Team(code: "TUN", name: "Tunisia", flag: "🇹🇳"),
        Team(code: "USA", name: "United States", flag: "🇺🇸"),
        Team(code: "URU", name: "Uruguay", flag: "🇺🇾"),
        Team(code: "UZB", name: "Uzbekistan", flag: "🇺🇿"),
    ]

    /// Placeholder teams for the Settings preview — generic on purpose so the
    /// preview reads as an example, never as a real match.
    static let previewHome = Team(code: "TMA", name: "Team A", flag: "🏳️")
    static let previewAway = Team(code: "TMB", name: "Team B", flag: "🏳️")

    static func team(for code: String, in teams: [Team]) -> Team {
        if code == previewHome.code { return previewHome }
        if code == previewAway.code { return previewAway }
        return teams.first { $0.code == code }
            ?? Team(code: code, name: code, flag: "⚽")
    }
}
