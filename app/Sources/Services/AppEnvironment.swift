import Foundation

enum AppEnvironment {
    static let apiBase = configuredURL("APIBaseURL")
    static let scoresBase = configuredURL("ScoresBaseURL")
    static let website = URL(string: "https://alldayidreamaboutsports.com")!
    static let supportEmail = "hello@thisisnsh.com"

    static var buildNumber: Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1") ?? 1
    }

    /// Marketing version (CFBundleShortVersionString), e.g. "1.2.0".
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    /// Analytics/reporting version, e.g. "1.2.0.42".
    static var fullAppVersion: String {
        "\(appVersion).\(buildNumber)"
    }

    /// Build configuration name, derived from compile-time flags.
    static var profileName: String {
        #if DEBUG
        return "Debug"
        #elseif STAGING
        return "Staging"
        #else
        return "Release"
        #endif
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

/// Where the app keeps its preferences. A Debug build shares its bundle id with
/// an installed Release app, so `UserDefaults.standard` is the SAME store for
/// both: without this, a dev run reads that app's real fan teams and cached
/// matchday (and writes demo data back over them). Debug therefore gets its own
/// suite; Release is plain `.standard`, unchanged.
enum AppDefaults {
    #if DEV_BACKEND
    static let shared: UserDefaults =
        UserDefaults(suiteName: "com.thisisnsh.alldaysports.dev") ?? .standard
    #else
    static let shared: UserDefaults = .standard
    #endif
}
