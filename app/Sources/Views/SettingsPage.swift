import SwiftUI

/// The popover's Settings page. Every change shows on screen right away: the
/// overlays it tunes are on screen beside the popover, not behind a window.
struct SettingsPage: View {
    @EnvironmentObject var session: AppSession
    @Environment(\.colorScheme) private var scheme
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    // Local mirror so the SwiftUI content reacts synchronously while the
    // deferred session write updates the application-level AppKit appearance.
    @State private var activeTheme: ThemeChoice = .system
    /// The twelve per-event switches sit behind the presets, folded.
    @State private var customizing = false
    @ObservedObject private var displayTarget = OverlayDisplayTarget.shared
    static let screen = "settings"

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Settings")
            ScrollView {
                VStack(spacing: 12) {
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

                    SettingsCard("Alerts") {
                        Picker("Alerts", selection: presetBinding) {
                            ForEach(AlertPreset.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        caption(presetCaption)
                        Button {
                            withAnimation(.easeOut(duration: 0.15)) { customizing.toggle() }
                        } label: {
                            HStack(spacing: 4) {
                                Text("Customize events")
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .bold))
                                    .rotationEffect(.degrees(customizing ? 90 : 0))
                            }
                            .font(.system(size: 12))
                            .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                        if customizing {
                            ForEach(MatchEventType.settingsOrder, id: \.self) { type in
                                eventRow(type)
                            }
                        }
                    }

                    // No goal events = nothing to celebrate; the whole
                    // section disappears (its switches were zeroed too).
                    if session.prefs.settings.eventEnabled(.goal) {
                        SettingsCard("When your team scores") {
                            toggleRow("Goal celebration in the center", isOn: celebrationBinding)

                            Button {
                                // No event here: `OverlayManager.preview()`
                                // reports the same click as
                                // `celebration_preview`.
                                OverlayManager.shared.preview()
                            } label: {
                                Text("Preview celebration").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.cardButton)
                        }
                    }

                    SettingsCard("On screen") {
                        pickerRow("Size", selection: overlaySizeBinding, cases: CapsuleSize.allCases) { $0.label }
                        pickerRow("Pinned score", selection: capsulePositionBinding, cases: CapsulePosition.allCases) { $0.label }
                        if displayTarget.displays.count > 1 {
                            screenPickerRow
                        }
                        caption("Size applies to notch alerts and pinned scores. Pin a live match from the menu to float its score; hover it to see the timeline.")
                    }

                    SettingsCard("General") {
                        pickerRow("Theme", selection: themeBinding, cases: ThemeChoice.allCases) { $0.label }
                        toggleRow("Open at login", isOn: Binding(
                            get: { launchAtLogin },
                            set: { on in
                                launchAtLogin = on
                                LaunchAtLogin.set(enabled: on)
                                session.updateSettings { $0.launchAtLogin = on }
                            }
                        ))
                        caption("The app starts silently in the menu bar. It never shows in the Dock; that's how it's designed.")
                    }

                    footer
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 12)
            }
            // Cards fade out as they slide up under the heading.
            .mask(
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: 12)
                    Rectangle()
                }
            )
        }
        .onAppear {
            activeTheme = session.prefs.settings.theme ?? .system
            launchAtLogin = LaunchAtLogin.isEnabled
        }
    }

    /// Feedback, version and Quit — the things that used to crowd the bottom
    /// of the menu.
    private var footer: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button { Feedback.reportBug() } label: {
                    Label("Report a bug", systemImage: "ladybug").frame(maxWidth: .infinity)
                }
                Button { Feedback.requestFeature() } label: {
                    Label("Request a feature", systemImage: "lightbulb").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.cardButton)
            Text("\(AppEnvironment.profileName) v\(AppEnvironment.appVersion) (Build \(AppEnvironment.buildNumber))")
                .font(.caption)
                .opacity(0.6)
            Button {
                AppAnalytics.appQuit(source: "settings")
                NSApp.terminate(nil)
            } label: {
                Text("Quit").foregroundStyle(.red).frame(maxWidth: .infinity)
            }
            .buttonStyle(.cardButton)
        }
        .padding(.top, 4)
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

    // MARK: Presets

    /// nil when the switches match no preset — the segmented control then
    /// shows nothing selected and the caption says "Custom".
    private var presetBinding: Binding<AlertPreset?> {
        Binding(
            get: { AlertPreset.matching(session.prefs.settings) },
            set: { preset in
                guard let preset else { return }
                // Deferred like `themeBinding` to avoid "Publishing changes
                // from within view updates" when the segmented control flips.
                DispatchQueue.main.async {
                    let goalWasOn = session.prefs.settings.eventEnabled(.goal)
                    session.updateSettings {
                        preset.apply(to: &$0)
                        // Every preset includes goals: bring the celebration
                        // back if goals had been muted (which zeroed it).
                        if !goalWasOn {
                            $0.goalCenter = true
                            $0.confetti = true
                        }
                    }
                    OverlayManager.shared.previewAlert(preset.sampleEvent)
                }
            }
        )
    }

    private var presetCaption: String {
        let what = AlertPreset.matching(session.prefs.settings)?.summary ?? "Custom: your own mix of events."
        return "\(what) Each alert drops from the notch."
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

                    }
                }
            }
        )
    }

    /// The whole celebration — center ball and score plus the confetti — is one
    /// switch.
    private var celebrationBinding: Binding<Bool> {
        Binding(
            get: { session.prefs.settings.goalCenter ?? true },
            set: { on in
                session.updateSettings {
                    $0.goalCenter = on
                    $0.confetti = on
                }
            }
        )
    }

    /// One size for both overlays: the capsule and the notch drops. Reads
    /// the capsule's (they only differ if set apart by an older build), and
    /// replays a notch alert so the new size is visible straight away.
    private var overlaySizeBinding: Binding<CapsuleSize> {
        Binding(
            get: { session.prefs.settings.capsuleSize ?? .medium },
            set: { choice in
                // Deferred like `themeBinding` to avoid "Publishing changes from
                // within view updates" when the segmented control flips.
                DispatchQueue.main.async {
                    session.updateSettings {
                        $0.capsuleSize = choice
                        $0.notchDropSize = choice
                    }
                    OverlayManager.shared.previewAlert(.goal)
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
        .fullTime,
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
        Button("Show onboarding") {
            OnboardingWindowController.shared.show()
        }
        .buttonStyle(.cardButton)
        Text("Deterministic timeline from Dev/DevConfig.swift — the same events fire at the same seconds every run.")
            .font(.caption)
            .opacity(0.6)
            .fixedSize(horizontal: false, vertical: true)
    }
}
#endif
