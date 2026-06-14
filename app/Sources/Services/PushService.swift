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
        guard FirebaseConfigured.isConfigured else { return }
        queue.async {
            self.desired = Set(teamIds.map { "l\(AppEnvironment.leagueId)_\($0)" })
            self.retryPending()
        }
    }

    func retryPending() {
        guard FirebaseConfigured.isConfigured else { return }
        queue.async {
            let wanted = self.desired
            let current = self.subscribed
            for topic in current.subtracting(wanted).subtracting(self.inFlight) {
                self.inFlight.insert(topic)
                Messaging.messaging().unsubscribe(fromTopic: topic) { error in
                    self.queue.async {
                        self.inFlight.remove(topic)
                        if let error {
                            NSLog("FCM unsubscribe failed %@: %@", topic, error.localizedDescription)
                        } else {
                            var confirmed = self.subscribed
                            confirmed.remove(topic)
                            self.subscribed = confirmed
                            NSLog("FCM unsubscribed %@", topic)
                            self.retryPending()
                        }
                    }
                }
            }
            for topic in wanted.subtracting(current).subtracting(self.inFlight) {
                self.inFlight.insert(topic)
                Messaging.messaging().subscribe(toTopic: topic) { error in
                    self.queue.async {
                        self.inFlight.remove(topic)
                        if let error {
                            NSLog("FCM subscribe failed %@: %@", topic, error.localizedDescription)
                        } else {
                            var confirmed = self.subscribed
                            confirmed.insert(topic)
                            self.subscribed = confirmed
                            NSLog("FCM subscribed %@", topic)
                            self.retryPending()
                        }
                    }
                }
            }
        }
    }

    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        NSLog("FCM registration token received: %@", fcmToken ?? "<nil>")
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
