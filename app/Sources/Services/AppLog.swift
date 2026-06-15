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

    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.alldayidreamaboutsports.mac"

    static func debug(_ category: Category, _ message: String) {
        write(.debug, category: category, message: message)
    }

    static func info(_ category: Category, _ message: String) {
        write(.info, category: category, message: message)
    }

    static func error(_ category: Category, _ message: String, error: Error? = nil) {
        let detail = error.map { "\(message) error=\($0.localizedDescription)" } ?? message
        write(.error, category: category, message: detail)
        #if STAGING
        guard FirebaseConfigured.isConfigured else { return }
        let nsError = NSError(
            domain: subsystem,
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: detail,
                "category": category.rawValue,
            ]
        )
        Crashlytics.crashlytics().record(error: nsError)
        #endif
    }

    static func configureFirebaseCollection() {
        guard FirebaseConfigured.isConfigured else { return }
        #if STAGING
        Crashlytics.crashlytics().setCrashlyticsCollectionEnabled(true)
        info(.app, "firebase_log_collection enabled build=staging")
        #else
        Crashlytics.crashlytics().setCrashlyticsCollectionEnabled(false)
        info(.app, "firebase_log_collection disabled build=non-staging")
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
