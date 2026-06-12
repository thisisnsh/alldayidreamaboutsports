import Foundation

enum AppEnvironment {
    static let apiBase = URL(string: "https://api.alldayidreamaboutsports.com")!
    static let scoresBase = URL(string: "https://scores.alldayidreamaboutsports.com")!
    static let website = URL(string: "https://alldayidreamaboutsports.com")!
    static let leagueId = 1 // FIFA World Cup

    static var buildNumber: Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1") ?? 1
    }
}
