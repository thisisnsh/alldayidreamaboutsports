import FirebaseMessaging
import Foundation

/// FCM registration + topic management. Topics are `l{league}_{TEAM}`; the
/// backend fans match events out to them — free at any scale. Pushes are
/// data-only (the notch pill is the notification), so no UN permission needed.
final class PushService: NSObject, MessagingDelegate {
    static let shared = PushService()

    private var subscribed: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "subscribedTopics") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "subscribedTopics") }
    }

    func syncTopics(to teamIds: Set<Int>) {
        guard FirebaseConfigured.isConfigured else { return }
        let wanted = Set(teamIds.map { "l\(AppEnvironment.leagueId)_\($0)" })
        let current = subscribed
        for topic in current.subtracting(wanted) {
            Messaging.messaging().unsubscribe(fromTopic: topic)
        }
        for topic in wanted.subtracting(current) {
            Messaging.messaging().subscribe(toTopic: topic)
        }
        subscribed = wanted
    }

    // MARK: MessagingDelegate

    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        // Re-assert topic subscriptions whenever the registration token rotates.
        syncTopics(to: AppSessionTopicsSnapshot.current())
    }
}

enum FirebaseConfigured {
    static var isConfigured: Bool {
        Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil
    }
}

/// Read the followed teams without hopping to the main actor. Signed out
/// (no stored profile) reads as no teams, so a token rotation while signed
/// out never resubscribes.
enum AppSessionTopicsSnapshot {
    static func current() -> Set<Int> {
        guard UserDefaults.standard.data(forKey: "profile") != nil,
              let data = UserDefaults.standard.data(forKey: "prefs"),
              let prefs = try? JSONDecoder().decode(UserPrefs.self, from: data)
        else { return [] }
        return Set((prefs.fanOf["football"]?[String(AppEnvironment.leagueId)] ?? []).compactMap(Int.init))
    }
}
