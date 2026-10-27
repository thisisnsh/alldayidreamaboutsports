import ActivityKit
import SwiftUI

struct SettingsPage: View {
    static let screen = "settings"
    @EnvironmentObject private var session: AppSession
    @AppStorage("mobileOnboardingComplete", store: AppDefaults.shared) private var onboarded = false
    @AppStorage("mobileKeepAwake", store: AppDefaults.shared) private var keepAwake = false
    @AppStorage("mobileMatchAlerts", store: AppDefaults.shared) private var matchAlerts = false
    @ObservedObject private var push = PushRegistration.shared
    @ObservedObject private var notifications = MatchNotifications.shared
    @ObservedObject private var pins = PinnedCapsuleManager.shared

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Settings")
            Form {
                Section("Appearance") {
                    Picker("Theme", selection: Binding(
                        get: { session.prefs.settings.theme ?? .system },
                        set: { choice in session.updateSettings { $0.theme = choice } }
                    )) {
                        ForEach(ThemeChoice.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }
                Section("Live match mode") {
                    Toggle("Keep screen awake", isOn: $keepAwake)
                    Text("Keep the screen on while watching matches. Background updates use the push service when connected; foreground polling works independently. Keeping the screen awake uses more battery.")
                        .foregroundStyle(.secondary)
                }
                Section("Background delivery") {
                    Text(push.status).foregroundStyle(.secondary)
                    Text("Background alerts share your selected team IDs and event preferences with our push service. Pinning shares that match ID and its delivery token. No account is needed.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Reconnect") { PushRegistration.shared.start() }
                        .disabled(!PushRegistration.isConfigured)
                }
                Section("Match alerts") {
                    Toggle("Match notifications", isOn: Binding(
                        get: { matchAlerts },
                        set: { enabled in
                            if enabled { Task { await notifications.enable() } }
                            else { matchAlerts = false; PushRegistration.shared.requestSync() }
                        }
                    ))
                    Text(notifications.permissionMessage).foregroundStyle(.secondary)
                    ForEach(MatchEventType.settingsOrder, id: \.self) { type in
                        Toggle(type.displayName, isOn: Binding(
                            get: { session.prefs.settings.eventEnabled(type) },
                            set: { enabled in
                                session.updateSettings {
                                    var values = $0.notifications ?? [:]
                                    values[type.settingsKey] = enabled
                                    $0.notifications = values
                                }
                            }
                        ))
                    }
                }
                Section("Pinned scores") {
                    Text("Pin a live match from its score card to show it on your Lock Screen.")
                    Text("Connected background delivery updates your pinned score while the app is closed. If updates are delayed, reopen the app to refresh.")
                        .foregroundStyle(.secondary)
                    Button("Remove all pinned scores", role: .destructive) {
                        for id in pins.pinnedFixtureIds { pins.unpin(fixtureId: id) }
                    }.disabled(pins.pinnedFixtureIds.isEmpty)
                    Link("Open system settings", destination: URL(string: UIApplication.openSettingsURLString)!)
                }
                Section("About") {
                    Button("Show onboarding") { onboarded = false }
                    Link("Privacy policy", destination: URL(string: "https://alldayidreamaboutsports.com/privacy/")!)
                    Link("Contact support", destination: URL(string: "mailto:\(AppEnvironment.supportEmail)")!)
                    Text("Version \(AppEnvironment.fullAppVersion)").foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .task { await notifications.refreshPermission() }
        }
    }
}
