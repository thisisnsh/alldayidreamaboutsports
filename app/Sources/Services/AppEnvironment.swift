import Foundation

enum AppEnvironment {
    static let apiBase = configuredURL("APIBaseURL")
    static let scoresBase = configuredURL("ScoresBaseURL")
    static let website = URL(string: "https://alldayidreamaboutsports.com")!
    static let supportEmail = "support@alldayidreamaboutsports.com"
    static let leagueId = 1 // FIFA World Cup

    static var buildNumber: Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1") ?? 1
    }

    private static func configuredURL(_ key: String) -> URL {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              let url = URL(string: value),
              url.scheme == "https" else {
            fatalError("Missing or invalid \(key) build setting")
        }
        return url
    }
}

/// Whether a Firebase config plist is bundled. Gates Remote Config + Crashlytics
/// (dev builds gitignore the plist). Firebase is no longer used for messaging.
enum FirebaseConfigured {
    static var isConfigured: Bool {
        Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil
    }
}
