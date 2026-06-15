import FirebaseMessaging
import Foundation

/// Confirmed FCM topic state. Failures remain pending and retry whenever the
/// app, APNs token, FCM token, sign-in, or followed teams change.
final class PushService: NSObject, MessagingDelegate {
    static let shared = PushService()
    private let queue = DispatchQueue(label: "PushService.topics")
    private var inFlight: Set<String> = []

    private var subscribed: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "subscribedTopics") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "subscribedTopics") }
    }

    private var desired: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "desiredTopics") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "desiredTopics") }
    }

    func syncTopics(to teamIds: Set<Int>) {
        guard FirebaseConfigured.isConfigured else {
            AppLog.debug(.fcm, "topic_sync_skipped firebase_unconfigured")
            return
        }
        queue.async {
            self.desired = Set(teamIds.map { "l\(AppEnvironment.leagueId)_\($0)" })
            AppLog.info(.fcm, "topic_sync desired=\(self.desired.sorted()) current=\(self.subscribed.sorted())")
            self.retryPending()
        }
    }

    func retryPending() {
        guard FirebaseConfigured.isConfigured else { return }
        queue.async {
            let wanted = self.desired
            let current = self.subscribed
            AppLog.debug(.fcm, "topic_retry desired=\(wanted.sorted()) current=\(current.sorted()) in_flight=\(self.inFlight.sorted())")
            for topic in current.subtracting(wanted).subtracting(self.inFlight) {
                self.inFlight.insert(topic)
                AppLog.info(.fcm, "topic_unsubscribe_start topic=\(topic)")
                Messaging.messaging().unsubscribe(fromTopic: topic) { error in
                    self.queue.async {
                        self.inFlight.remove(topic)
                        if let error {
                            AppLog.error(.fcm, "topic_unsubscribe_failed topic=\(topic)", error: error)
                        } else {
                            var confirmed = self.subscribed
                            confirmed.remove(topic)
                            self.subscribed = confirmed
                            AppLog.info(.fcm, "topic_unsubscribe_complete topic=\(topic)")
                            self.retryPending()
                        }
                    }
                }
            }
            for topic in wanted.subtracting(current).subtracting(self.inFlight) {
                self.inFlight.insert(topic)
                AppLog.info(.fcm, "topic_subscribe_start topic=\(topic)")
                Messaging.messaging().subscribe(toTopic: topic) { error in
                    self.queue.async {
                        self.inFlight.remove(topic)
                        if let error {
                            AppLog.error(.fcm, "topic_subscribe_failed topic=\(topic)", error: error)
                        } else {
                            var confirmed = self.subscribed
                            confirmed.insert(topic)
                            self.subscribed = confirmed
                            AppLog.info(.fcm, "topic_subscribe_complete topic=\(topic)")
                            self.retryPending()
                        }
                    }
                }
            }
        }
    }

    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        AppLog.info(.fcm, "registration_token_received present=\(fcmToken != nil) length=\(fcmToken?.count ?? 0)")
        syncTopics(to: AppSessionTopicsSnapshot.current())
    }
}

enum FirebaseConfigured {
    static var isConfigured: Bool {
        Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil
    }
}

enum AppSessionTopicsSnapshot {
    static func current() -> Set<Int> {
        guard UserDefaults.standard.data(forKey: "profile") != nil,
              let data = UserDefaults.standard.data(forKey: "prefs"),
              let prefs = try? JSONDecoder().decode(UserPrefs.self, from: data)
        else { return [] }
        return Set((prefs.fanOf["football"]?[String(AppEnvironment.leagueId)] ?? []).compactMap(Int.init))
    }
}
