import SwiftUI
import UserNotifications

/// Local alerts while active; remote alerts while suspended. Both respect event preferences.
@MainActor
final class MatchNotifications: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = MatchNotifications()
    @Published private(set) var permissionMessage = "Enable notifications to receive match alerts while this app is open."
    var isForeground = false
    private let center = UNUserNotificationCenter.current()

    func configure() { center.delegate = self }

    func refreshPermission() async {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            permissionMessage = "Notifications allowed. Foreground alerts come from polling; background alerts require a connected push service."
        case .denied:
            permissionMessage = "Notifications are blocked. Allow them in system settings."
        default:
            permissionMessage = "Enable notifications to receive match alerts while this app is open."
        }
    }

    func enable() async {
        do {
            let allowed = try await center.requestAuthorization(options: [.alert, .sound])
            AppDefaults.shared.set(allowed, forKey: "mobileMatchAlerts")
            PushRegistration.shared.start()
            PushRegistration.shared.requestSync()
            await refreshPermission()
        } catch {
            permissionMessage = "Couldn't enable notifications. Try again in system settings."
            AppLog.error(.app, "notification_permission_failed", error: error)
        }
    }

    func post(_ event: MatchEvent) {
        guard isForeground, AppDefaults.shared.bool(forKey: "mobileMatchAlerts") else { return }
        Task {
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional,
                  isForeground, AppDefaults.shared.bool(forKey: "mobileMatchAlerts") else { return }
            let content = UNMutableNotificationContent()
            content.title = "\(event.type.displayName) · \(event.homeName) vs \(event.awayName)"
            let score = ScorelineFormatter.text(homeGoals: event.homeGoals, awayGoals: event.awayGoals,
                                               penHome: event.penHome, penAway: event.penAway)
            let minute = event.minute.map { "\($0)\(event.extra.map { "+\($0)" } ?? "")′" }
            content.body = [minute, event.player, event.varDetail, score].compactMap { $0 }.joined(separator: " · ")
            content.sound = .default
            content.threadIdentifier = "match-\(event.fixtureId)"
            content.userInfo = ["fixtureId": event.fixtureId]
            do {
                try await center.add(UNNotificationRequest(identifier: event.eventId, content: content, trigger: nil))
            } catch {
                AppLog.error(.app, "local_match_notification_failed", error: error)
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let remote = notification.request.trigger is UNPushNotificationTrigger
        Task { @MainActor in
            // Polling owns foreground alerts, so a matching server push must not double-alert.
            if remote { completionHandler([]); return }
            completionHandler(AppDefaults.shared.bool(forKey: "mobileMatchAlerts") ? [.banner, .list, .sound] : [])
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            PopoverRouter.shared.reset()
            completionHandler()
        }
    }
}
