import Sparkle
import SwiftUI

struct SettingsView: View {
    let updater: SPUUpdater
    @EnvironmentObject var session: AppSession
    @Environment(\.colorScheme) private var scheme
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    // Sparkle persists this flag in UserDefaults itself; we just mirror it.
    @State private var autoCheck = true
    // Local mirror so the SwiftUI content reacts synchronously while the
    // deferred session write updates the application-level AppKit appearance.
    @State private var activeTheme: ThemeChoice = .system
    @ObservedObject private var displayTarget = OverlayDisplayTarget.shared
    private static let screen = "settings"

    var body: some View {
        ZStack {
            AppBackground()
            settingsContent
        }
        .frame(width: 440, height: 640)
        .installsWindowOpener()
        .appTheme(activeTheme)
        .onAppear {
            AppAnalytics.screenView(Self.screen)
            activeTheme = session.prefs.settings.theme ?? .system
            autoCheck = updater.automaticallyChecksForUpdates
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
                    if let profile = session.profile {
                        profileCard(profile)
                    }

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
                        ForEach(MatchEventType.settingsOrder, id: \.self) { type in
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
                            // The pop rides along with the confetti, so it only
                            // makes sense while confetti is on; hide it otherwise.
                            // Its value is preserved so re-enabling confetti brings
                            // back whatever the user last set (default on).
                            if session.prefs.settings.confetti ?? true {
                                toggleRow("Play confetti sound", isOn: confettiSoundBinding)
                            }
                            Button {
                                // No event here: `OverlayManager.preview()`
                                // reports the same click as
                                // `celebration_preview`.
                                OverlayManager.shared.preview()
                            } label: {
                                Text("Preview animation").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.cardButton)
                            caption("Choose how your team’s goals are celebrated with animations and sound. You’ll always see the notch drop on goal like every other event. Preview shows exactly what you picked.")
                        }
                    }

                    SettingsCard("Appearance") {
                        pickerRow("Theme", selection: themeBinding, cases: ThemeChoice.allCases) { $0.label }
                        pickerRow("Capsule size", selection: capsuleSizeBinding, cases: CapsuleSize.allCases) { $0.label }
                        pickerRow("Capsule position", selection: capsulePositionBinding, cases: CapsulePosition.allCases) { $0.label }
                        pickerRow("Notch drop size", selection: notchDropSizeBinding, cases: CapsuleSize.allCases) { $0.label }
                        if displayTarget.displays.count > 1 {
                            screenPickerRow
                        }
                        caption("Capsules and notifications appear on the selected screen. Pin a match from the menu to float its live score; hover it to see the event timeline.")
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
                                // Sparkle owns this flag, so it never passes
                                // through `AppSession.updateSettings` and needs
                                // reporting from here.
                                AppAnalytics.settingChanged(.autoCheckUpdates, enabled: on)
                            }
                        ))
                        CheckForUpdatesButton(updater: updater, source: "settings")
                            .buttonStyle(.cardButton)
                        caption("\(AppEnvironment.profileName) v\(AppEnvironment.appVersion) (Build \(AppEnvironment.buildNumber))")
                    }

                    Button {
                        AppAnalytics.appQuit(source: "settings")
                        NSApp.terminate(nil)
                    } label: {
                        Text("Quit").foregroundStyle(.red).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.cardButton)
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

    // MARK: Profile

    /// Account header card: who you're signed in as, plus the sign-out and
    /// quit actions that used to live in the menu bar dropdown.
    private func profileCard(_ profile: Profile) -> some View {
        SettingsCard("Account") {
            HStack(spacing: 12) {
                CachedProfilePhoto(url: profile.photoURL, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name ?? "Fan")
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Text(profile.email ?? "")
                        .font(.caption)
                        .opacity(0.7)
                        .lineLimit(1)
                }
                Spacer()
                // No event here either: this is the only user path into
                // `clearSession`, which reports it as `sign_out reason=user`.
                Button("Sign out") { session.signOut() }
                    .buttonStyle(.cardButton)
            }
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
                    // Symbols vary in width (arrow.left.arrow.right vs the
                    // card rectangle) — a fixed column keeps the names aligned.
                    .frame(width: 16)
                Text(type.displayName)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(scheme == .dark ? Color.black : Color.white))
            Spacer()
            Toggle("", isOn: eventBinding(type))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    /// A labeled segmented picker — the Appearance card stacks two of these,
    /// so each needs its own visible label and a shared control width so the
    /// segments line up as one column.
    private func pickerRow<Choice: Hashable>(_ label: String, selection: Binding<Choice>,
                                             cases: [Choice], caseLabel: @escaping (Choice) -> String) -> some View {
        HStack {
            Text(label).font(.system(size: 13))
            Spacer()
            Picker(label, selection: selection) {
                ForEach(cases, id: \.self) { Text(caseLabel($0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .frame(width: 220, alignment: .trailing)
        }
    }

    private var screenPickerRow: some View {
        HStack {
            Text("Screen").font(.system(size: 13))
            Spacer()
            Picker("Screen", selection: displayBinding) {
                ForEach(displayTarget.displays) { display in
                    Text(display.name).tag(Optional(display.id))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .frame(width: 220, alignment: .trailing)
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
                    // Muting goals mutes the celebration with it; unmuting
                    // restores all of them so the section never reappears all-off.
                    if type == .goal {
                        $0.goalCenter = on
                        $0.confetti = on
                        // confettiSound is intentionally left untouched — it
                        // rides on confetti's visibility and keeps its value so
                        // re-enabling brings back the user's last choice.
                    }
                }
            }
        )
    }

    private var confettiSoundBinding: Binding<Bool> {
        Binding(
            get: { session.prefs.settings.confettiSound ?? true },
            set: { on in
                session.updateSettings { $0.confettiSound = on }
                // Pop once when switching it on so the user hears what they
                // enabled — a preview of the confetti sound.
                if on {
                    ConfettiSoundPlayer.play()
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

    private var capsuleSizeBinding: Binding<CapsuleSize> {
        Binding(
            get: { session.prefs.settings.capsuleSize ?? .medium },
            set: { choice in
                // Deferred like `themeBinding` to avoid "Publishing changes from
                // within view updates" when the segmented control flips.
                DispatchQueue.main.async {
                    session.updateSettings { $0.capsuleSize = choice }
                }
            }
        )
    }

    private var notchDropSizeBinding: Binding<CapsuleSize> {
        Binding(
            get: { session.prefs.settings.notchDropSize ?? .medium },
            set: { choice in
                // Deferred like `capsuleSizeBinding` to avoid "Publishing
                // changes from within view updates" when the segmented
                // control flips.
                DispatchQueue.main.async {
                    session.updateSettings { $0.notchDropSize = choice }
                }
            }
        )
    }

    private var capsulePositionBinding: Binding<CapsulePosition> {
        Binding(
            get: { session.prefs.settings.capsulePosition ?? .top },
            set: { choice in
                DispatchQueue.main.async {
                    session.updateSettings { $0.capsulePosition = choice }
                }
            }
        )
    }

    private var themeBinding: Binding<ThemeChoice> {
        Binding(
            get: { activeTheme },
            set: { choice in
                activeTheme = choice
                // Defer the @Published mutation to avoid "Publishing changes
                // from within view updates" — the @State update above is safe
                // to do synchronously and drives the immediate visual change.
                DispatchQueue.main.async {
                    session.updateSettings { $0.theme = choice }
                }
            }
        )
    }

    private var displayBinding: Binding<CGDirectDisplayID?> {
        Binding(
            get: { displayTarget.selectedDisplayID },
            set: { displayID in
                guard let displayID, displayID != displayTarget.selectedDisplayID else { return }
                // The COUNT, never the display id — that identifies a machine
                // and means nothing off it.
                AppAnalytics.overlayDisplayChanged(displayCount: displayTarget.displays.count)
                displayTarget.select(displayID)
            }
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
    static let settingsOrder: [MatchEventType] = [
        .kickoff, .goal, .goalCancelled, .varDecision, .yellowCard, .redCard,
        .substitution, .halfTime, .extraTime, .penaltyShootout, .penaltyKick,
        .fullTime, .celebration,
    ]

    var displayName: String {
        switch self {
        case .kickoff: "Kickoff"
        case .goal: "Goal"
        case .goalCancelled: "Goal disallowed"
        case .varDecision: "VAR decisions"
        case .yellowCard: "Yellow card"
        case .redCard: "Red card"
        case .substitution: "Substitution"
        case .halfTime: "Half-time"
        case .secondHalf: "Second half"
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
            Button("Restart") {
                AppAnalytics.demoRestart()
                DemoEngine.shared.restart()
            }
            .buttonStyle(.cardButton)
            Button(engine.isPlaying ? "Stop" : "Play") {
                AppAnalytics.demoPlayStop(action: engine.isPlaying ? "stop" : "play")
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
    /// Which entry point this button is, for `update_check_started`'s `source`
    /// — the update window's "Update now" runs the same Sparkle check.
    private let source: String

    init(updater: SPUUpdater, source: String) {
        self.updater = updater
        self.source = source
        self.model = CheckForUpdatesModel(updater: updater)
    }

    var body: some View {
        Button {
            AppAnalytics.updateCheckStarted(source: source)
            updater.checkForUpdates()
        } label: {
            Text("Check for Updates…").frame(maxWidth: .infinity)
        }
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
