import Sparkle
import SwiftUI

struct SettingsView: View {
    let updater: SPUUpdater
    @EnvironmentObject var session: AppSession
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var confirmDelete = false
    // Sparkle persists both flags in UserDefaults itself; we just mirror them.
    @State private var autoCheck = true
    @State private var autoInstall = true

    var body: some View {
        ZStack {
            AppBackground()
            settingsContent
        }
        .frame(width: 440, height: 640)
        .installsWindowOpener()
        .appTheme(session.prefs.settings.theme ?? .system)
        .onAppear {
            autoCheck = updater.automaticallyChecksForUpdates
            autoInstall = updater.automaticallyDownloadsUpdates
        }
        .confirmationDialog(
            "Delete your account and all preferences?",
            isPresented: $confirmDelete
        ) {
            Button("Delete", role: .destructive) {
                Task { await session.deleteAccount() }
            }
        }
    }

    private var settingsContent: some View {
        VStack(spacing: 0) {
            // Fixed heading — left-aligned, tucked under the traffic lights;
            // only the cards below it scroll.
            Text("Settings")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 16)
                .padding(.top, 8)

            ScrollView {
                VStack(spacing: 14) {
                    #if DEV_BACKEND
                    Text("🧪 dev session — fake backend, hardcoded data, scripted demo")
                        .font(.caption2)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(.yellow.opacity(0.25)))

                    SettingsCard("Developer") {
                        DemoControls()
                    }
                    #endif

                    SettingsCard("Events") {
                        ForEach(MatchEventType.allCases, id: \.self) { type in
                            eventRow(type)
                        }
                        caption("Each event shows as a drop from the notch.")
                    }

                    // No goal events = nothing to celebrate; the whole
                    // section disappears (its switches were zeroed too).
                    if session.prefs.settings.eventEnabled(.goal) {
                        SettingsCard("Goal celebration") {
                            toggleRow("Show goal in center", isOn: settingsBinding(\.goalCenter, default: true))
                            toggleRow("Show confetti in corners", isOn: settingsBinding(\.confetti, default: true))
                            Button("Preview animation") {
                                OverlayManager.shared.preview()
                            }
                            .buttonStyle(.cardButton)
                            caption("Choose how your team’s goals are celebrated with animations. You’ll always see the notch drop on goal like every other event. Preview shows exactly what you picked.")
                        }
                    }

                    SettingsCard("Appearance") {
                        Picker("Theme", selection: themeBinding) {
                            ForEach(ThemeChoice.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    SettingsCard("Behavior") {
                        toggleRow("Open at login", isOn: Binding(
                            get: { launchAtLogin },
                            set: { on in
                                launchAtLogin = on
                                LaunchAtLogin.set(enabled: on)
                                session.updateSettings { $0.launchAtLogin = on }
                            }
                        ))
                        caption("On by default so you never miss a goal — the app starts silently in the menu bar. It never shows in the Dock; that's how it's designed.")
                    }

                    SettingsCard("Updates") {
                        toggleRow("Automatically check for updates", isOn: Binding(
                            get: { autoCheck },
                            set: { on in
                                autoCheck = on
                                updater.automaticallyChecksForUpdates = on
                            }
                        ))
                        toggleRow("Automatically download and install", isOn: Binding(
                            get: { autoInstall },
                            set: { on in
                                autoInstall = on
                                updater.automaticallyDownloadsUpdates = on
                            }
                        ))
                        CheckForUpdatesButton(updater: updater)
                            .buttonStyle(.cardButton)
                        caption("Build \(AppEnvironment.buildNumber)")
                    }

                    SettingsCard(nil) {
                        Button("Delete account…", role: .destructive) { confirmDelete = true }
                            .buttonStyle(.cardButton)
                            .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 16)
            }
            // Cards fade out as they slide up under the heading.
            .mask(
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: 18)
                    Rectangle()
                }
            )
        }
    }

    // MARK: Rows

    /// A toggle next to the event type's icon and name — these are event
    /// categories, not example notifications.
    private func eventRow(_ type: MatchEventType) -> some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: pillIcon(for: type))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(pillIconColor(for: type))
                Text(type.displayName)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(.black))
            Spacer()
            Toggle("", isOn: eventBinding(type))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    private func toggleRow(_ label: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(label).font(.system(size: 13))
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .opacity(0.6)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Bindings

    private func eventBinding(_ type: MatchEventType) -> Binding<Bool> {
        Binding(
            get: { session.prefs.settings.eventEnabled(type) },
            set: { on in
                session.updateSettings {
                    $0.notifications = ($0.notifications ?? [:]).merging([type.settingsKey: on]) { _, new in new }
                    // Muting goals mutes the celebration with it.
                    if type == .goal && !on {
                        $0.goalCenter = false
                        $0.confetti = false
                    }
                }
            }
        )
    }

    private func settingsBinding(_ keyPath: WritableKeyPath<PrefSettings, Bool?>,
                                 default defaultValue: Bool) -> Binding<Bool> {
        Binding(
            get: { session.prefs.settings[keyPath: keyPath] ?? defaultValue },
            set: { on in session.updateSettings { $0[keyPath: keyPath] = on } }
        )
    }

    private var themeBinding: Binding<ThemeChoice> {
        Binding(
            get: { session.prefs.settings.theme ?? .system },
            set: { choice in session.updateSettings { $0.theme = choice } }
        )
    }
}

/// Grouped card — same tone as the hover highlight in the menu, so the
/// surfaces feel related.
private struct SettingsCard<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content

    init(_ title: String?, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .textCase(.uppercase)
                    .opacity(0.55)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.primary.opacity(0.08))
        )
    }
}

extension MatchEventType {
    var displayName: String {
        switch self {
        case .kickoff: "Kickoff"
        case .goal: "Goal"
        case .goalCancelled: "VAR: Goal Disallowed"
        case .yellowCard: "Yellow card"
        case .redCard: "Red card"
        case .halfTime: "Half-time"
        case .fullTime: "Full-time"
        case .extraTime: "Extra time"
        case .penaltyShootout: "Penalty shootout"
        case .penaltyKick: "Penalty kicks"
        case .celebration: "Celebrations"
        }
    }
}

#if DEV_BACKEND
/// Hand controls for the scripted demo timeline (DevConfig.timeline).
private struct DemoControls: View {
    @ObservedObject private var engine = DemoEngine.shared

    var body: some View {
        HStack {
            Text(engine.isPlaying
                ? "Playing — beat \(engine.firedCount)/\(DevConfig.timeline.count)"
                : "Idle")
                .font(.system(size: 12))
            Spacer()
            Circle()
                .fill(engine.isPlaying ? .green : .secondary)
                .frame(width: 8, height: 8)
        }
        HStack(spacing: 8) {
            Button("Restart") { DemoEngine.shared.restart() }
                .buttonStyle(.cardButton)
            Button(engine.isPlaying ? "Stop" : "Play") {
                engine.isPlaying ? DemoEngine.shared.stop() : DemoEngine.shared.start()
            }
            .buttonStyle(.cardButton)
        }
        Text("Deterministic timeline from Dev/DevConfig.swift — the same events fire at the same seconds every run.")
            .font(.caption)
            .opacity(0.6)
            .fixedSize(horizontal: false, vertical: true)
    }
}
#endif

/// Same approach as aithing-mac's CheckForUpdatesButton: observe canCheckForUpdates.
struct CheckForUpdatesButton: View {
    @ObservedObject private var model: CheckForUpdatesModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self.model = CheckForUpdatesModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!model.canCheckForUpdates)
    }
}

final class CheckForUpdatesModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}
