import FirebaseCrashlytics
import Foundation
import OSLog

enum AppLog {
    enum Category: String {
        case app
        case api
        case cdn
        case catalog
        case celebrations
        case fcm
        case fixtures
        case prefs
        case remoteConfig
    }

    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.thisisnsh.alldaysports"

    static func debug(_ category: Category, _ message: String) {
        write(.debug, category: category, message: message)
    }

    static func info(_ category: Category, _ message: String) {
        write(.info, category: category, message: message)
    }

    static func error(_ category: Category, _ message: String, error: Error? = nil) {
        // The local os_log line keeps the full description — it never leaves
        // the user's Mac.
        let detail = error.map { "\(message) error=\($0.localizedDescription)" } ?? message
        write(.error, category: category, message: detail)
        // Non-fatals report from Release too (Staging and Release both), because
        // a non-fatal is exactly the signal a shipped app otherwise lacks. What
        // goes up is SCRUBBED: `localizedDescription` can carry the failing URL
        // — session token in the query — or the signed-in email, and the coarse
        // label is enough to tell a 404 from a timeout.
        #if !DEV_BACKEND
        guard FirebaseConfigured.isConfigured else { return }
        let scrubbed = error.map { "\(message) error=\(errorLabel($0))" } ?? message
        let nsError = NSError(
            domain: subsystem,
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: scrubbed,
                "category": category.rawValue,
            ]
        )
        Crashlytics.crashlytics().record(error: nsError)
        #endif
    }

    /// A coarse, non-identifying label for an error — the ONLY form in which an
    /// error may leave the machine, whether as a Crashlytics non-fatal above or
    /// an analytics parameter (`AppAnalytics`). Never `localizedDescription`.
    static func errorLabel(_ error: Error) -> String {
        if case let APIError.http(code, _) = error { return "http_\(code)" }
        if case ScoresError.notFound = error { return "http_404" }
        if case ScoresError.notModified = error { return "http_304" }
        if let urlError = error as? URLError { return "url_\(urlError.code.rawValue)" }
        if error is DecodingError { return "decode" }
        return "other"
    }

    /// One line in the Crashlytics breadcrumb trail, so a crash report carries
    /// the last few things the user did. Unlike `write`'s per-line log below —
    /// staging-only, because Release must not ship a verbose debug trail off
    /// users' machines — this runs in Release too: its callers are the bounded
    /// set of analytics event names, not every log line.
    static func breadcrumb(_ line: String) {
        #if !DEV_BACKEND
        guard FirebaseConfigured.isConfigured else { return }
        Crashlytics.crashlytics().log(line)
        #endif
    }

    /// Crash reporting is on for both shipped configurations. It used to be
    /// staging-only, which meant no crash in the ACTUAL app had ever reported.
    /// Debug stays off: a `DEV_BACKEND` build normally has no Firebase plist at
    /// all, and a developer's own crashes are not data.
    static func configureFirebaseCollection() {
        guard FirebaseConfigured.isConfigured else { return }
        #if DEV_BACKEND
        Crashlytics.crashlytics().setCrashlyticsCollectionEnabled(false)
        info(.app, "firebase_log_collection disabled build=\(AppEnvironment.profileName)")
        #else
        Crashlytics.crashlytics().setCrashlyticsCollectionEnabled(true)
        info(.app, "firebase_log_collection enabled build=\(AppEnvironment.profileName)")
        #endif
    }

    private static func write(_ level: OSLogType, category: Category, message: String) {
        let line = "level=\(level.label) category=\(category.rawValue) \(message)"
        Logger(subsystem: subsystem, category: category.rawValue).log(level: level, "\(line, privacy: .public)")
        #if STAGING
        if FirebaseConfigured.isConfigured {
            Crashlytics.crashlytics().log(line)
        }
        #endif
    }
}

extension Duration {
    var milliseconds: Int64 {
        let components = self.components
        return components.seconds * 1_000 + Int64(components.attoseconds / 1_000_000_000_000_000)
    }
}

private extension OSLogType {
    var label: String {
        switch self {
        case .debug: "debug"
        case .info: "info"
        case .error, .fault: "error"
        default: "default"
        }
    }
}
