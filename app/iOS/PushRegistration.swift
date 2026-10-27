import ActivityKit
import FirebaseAppCheck
import FirebaseCore
import Security
import SwiftUI
import UIKit
import UserNotifications

final class SportsAppCheckFactory: NSObject, AppCheckProviderFactory {
    func createProvider(with app: FirebaseApp) -> AppCheckProvider? { AppAttestProvider(app: app) }
}

final class MobileAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in PushRegistration.shared.setDeviceToken(deviceToken) }
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in PushRegistration.shared.registrationFailed() }
    }
}

/// Registers only with the isolated push service. Scores continue to use the existing CDN.
@MainActor
final class PushRegistration: ObservableObject {
    static let shared = PushRegistration()
    @Published private(set) var status = "Background delivery is not configured. Live updates require this app to be open."
    @Published private(set) var remoteDeliveryEnabled = false
    private var tokens: [String: String] = [:]
    private var tokenTasks: [String: Task<Void, Never>] = [:]
    private var syncTask: Task<Void, Never>?
    private var lastBody: Data?
    private var lastSync = Date.distantPast
    private var lastAttempt = Date.distantPast
    private var sending = false
    private var deviceToken: String? {
        get { AppDefaults.shared.string(forKey: "mobileDevicePushToken") }
        set { AppDefaults.shared.set(newValue, forKey: "mobileDevicePushToken") }
    }
    static var endpoint: URL? {
        #if DEV_BACKEND
        return nil // Demo fixture IDs and fake events must never reach the push service.
        #else
        guard let text = Bundle.main.object(forInfoDictionaryKey: "PushBaseURL") as? String,
              let url = URL(string: text), url.scheme == "https", let host = url.host,
              !text.contains("$("), url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              url.path.isEmpty || url.path == "/", url.query == nil, url.fragment == nil,
              host.hasSuffix(".run.app") else { return nil }
        return url
        #endif
    }
    static var isConfigured: Bool { endpoint != nil && FirebaseConfigured.isConfigured }

    func start() {
        guard Self.isConfigured else { return }
        UIApplication.shared.registerForRemoteNotifications()
        restoreActivities()
        requestSync()
    }
    func setDeviceToken(_ data: Data) {
        deviceToken = data.map { String(format: "%02x", $0) }.joined()
        requestSync()
    }
    func registrationFailed() {
        status = "Notification registration failed. Foreground polling still works; reopen the app to retry."
    }
    func restoreActivities() {
        for activity in Activity<ScoreActivityAttributes>.activities where activity.activityState == .active || activity.activityState == .stale {
            observe(activity)
        }
    }
    func observe(_ activity: Activity<ScoreActivityAttributes>) {
        guard Self.isConfigured else { return }
        if let token = activity.pushToken { tokens[activity.id] = token.map { String(format: "%02x", $0) }.joined() }
        guard tokenTasks[activity.id] == nil else { return }
        tokenTasks[activity.id] = Task { [weak self] in
            for await data in activity.pushTokenUpdates {
                guard !Task.isCancelled else { return }
                self?.tokens[activity.id] = data.map { String(format: "%02x", $0) }.joined()
                self?.requestSync()
            }
        }
        requestSync()
    }
    func removeActivity(_ id: String) {
        tokens[id] = nil
        tokenTasks.removeValue(forKey: id)?.cancel()
        requestSync()
    }
    func requestSync() {
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            await self?.synchronize()
        }
    }
    func synchronize() async {
        guard Self.isConfigured, !DemoMode.isActive, let base = Self.endpoint, !sending,
              Date().timeIntervalSince(lastAttempt) >= 5 else { return }
        let session = AppSession.shared
        let permission = await UNUserNotificationCenter.current().notificationSettings()
        let allowed = permission.authorizationStatus == .authorized || permission.authorizationStatus == .provisional
        let activities = Activity<ScoreActivityAttributes>.activities.filter {
            ($0.activityState == .active || $0.activityState == .stale) && tokens[$0.id] != nil
        }.sorted { $0.id < $1.id }.prefix(8).map {
            ["id": $0.id, "fixtureId": $0.attributes.fixtureId, "token": tokens[$0.id]!] as [String: Any]
        }
        let alerts = allowed && AppDefaults.shared.bool(forKey: "mobileMatchAlerts")
        let body: [String: Any] = [
            "deviceToken": alerts ? (deviceToken as Any? ?? NSNull()) : NSNull(),
            "teamIds": alerts ? session.fanTeamIds.sorted() : [],
            "eventTypes": MatchEventType.allCases.filter { session.prefs.settings.eventEnabled($0) }.map(\.rawValue).sorted(),
            "alertsEnabled": alerts,
            "activities": activities,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else { return }
        guard data != lastBody || Date().timeIntervalSince(lastSync) > 3600 else { return }
        sending = true; lastAttempt = Date()
        defer { sending = false }
        // Allow token changes/unpin/preferences to finish registering when the app is backgrounded.
        let background = UIApplication.shared.beginBackgroundTask(withName: "Register score subscriptions")
        defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }
        do {
            let proof = try await AppCheck.appCheck().token(forcingRefresh: false)
            var request = URLRequest(url: base.appendingPathComponent("v1/installation"))
            request.httpMethod = "PUT"; request.httpBody = data
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(try installationSecret())", forHTTPHeaderField: "Authorization")
            request.setValue(proof.token, forHTTPHeaderField: "X-Firebase-AppCheck")
            let (responseData, response) = try await RemoteData.load(request, maxBytes: 8192, hosts: [base.host!])
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            struct Reply: Decodable { let registered: Bool; let remoteDeliveryEnabled: Bool }
            let reply = try JSONDecoder().decode(Reply.self, from: responseData)
            guard reply.registered else { throw URLError(.badServerResponse) }
            remoteDeliveryEnabled = reply.remoteDeliveryEnabled
            lastBody = data; lastSync = Date()
            status = reply.remoteDeliveryEnabled
                ? "Background score delivery connected. Updates can arrive while your device is locked."
                : "Push service is in dry-run mode. Background delivery is not active yet."
        } catch {
            status = "Couldn't sync background delivery. Existing subscriptions may still work; keep the app open to retry."
            AppLog.error(.app, "push_registration_failed") // Never log tokens or attestation material.
        }
    }
    private func installationSecret() throws -> String {
        // Separate keys for each service/environment; opaque device-local identity, no account.
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "sports-push", kSecAttrAccount as String: Self.endpoint!.absoluteString]
        var item: CFTypeRef?
        let result = SecItemCopyMatching(query.merging([kSecReturnData as String: true]) { _, new in new } as CFDictionary, &item)
        if result == errSecSuccess, let data = item as? Data, let text = String(data: data, encoding: .utf8) { return text }
        guard result == errSecItemNotFound else { throw URLError(.userAuthenticationRequired) }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw URLError(.unknown) }
        let value = bytes.map { String(format: "%02x", $0) }.joined()
        let fields: [String: Any] = [kSecValueData as String: Data(value.utf8),
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        guard SecItemAdd(query.merging(fields) { _, new in new } as CFDictionary, nil) == errSecSuccess else { throw URLError(.cannotCreateFile) }
        return value
    }
}
