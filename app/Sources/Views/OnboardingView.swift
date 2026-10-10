import AppKit
import SwiftUI

/// The app's only windows. First-run setup walks a new user from hello to
/// their teams to how loud alerts should be, then closes and opens the menu
/// bar popover so they see where the app lives; after that it never opens
/// again. Opening the app later gets a small "I'm up here" window instead,
/// pointing at the menu bar — everything else is in the popover.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindowController()
    private var window: NSWindow?
    /// Which window is up, so asking for the same one again just fronts it
    /// (keeping setup on its current step).
    private var showing: Kind?

    private enum Kind { case onboarding, welcomeBack }

    private static let completeKey = "onboardingComplete"

    /// A fresh install. Someone who already follows a team set the app up
    /// before onboarding existed (or quit after picking teams), so they skip it.
    var isNeeded: Bool {
        !AppDefaults.shared.bool(forKey: Self.completeKey) && AppSession.shared.fanTeamIds.isEmpty
    }

    func show() {
        present(.onboarding, OnboardingView(), size: OnboardingView.size)
    }

    /// Opening an already-set-up app: without this, a menu bar app looks like
    /// it failed to open.
    func showWelcomeBack() {
        present(.welcomeBack, WelcomeBackView(), size: WelcomeBackView.size)
    }

    private func present(_ kind: Kind, _ view: some View, size: CGSize) {
        NSApp.activate(ignoringOtherApps: true)
        if let window, showing == kind {
            window.makeKeyAndOrderFront(nil)
            return
        }
        // Swap the other window for this one.
        window?.close()
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        // Fixed size: left to size itself, the hosting controller resizes the
        // window after `center()`, knocking it off centre.
        let hosting = NSHostingController(rootView: view.environmentObject(AppSession.shared))
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(size)
        window.center()
        window.makeKeyAndOrderFront(nil)
        // An accessory app's window doesn't reliably come above other apps on
        // its own.
        window.orderFrontRegardless()
        self.window = window
        showing = kind
    }

    /// The last step's button: remember setup is done, swap the window for
    /// the popover.
    func finish() {
        AppDefaults.shared.set(true, forKey: Self.completeKey)
        AppAnalytics.onboardingCompleted(fanCount: AppSession.shared.fanTeamIds.count)
        openMenu()
    }

    /// Close the window, then drop the popover from the menu bar.
    func openMenu() {
        window?.close()
        // Let the window's close animation clear before the popover drops.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            MenuPopoverController.shared.showMenu()
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        window = nil
        showing = nil
    }
}

/// What a set-up user sees on opening the app from Finder or Spotlight: the
/// crest marquee and where the app actually lives.
struct WelcomeBackView: View {
    @EnvironmentObject var session: AppSession
    static let size = CGSize(width: 440, height: 400)

    var body: some View {
        ZStack(alignment: .bottom) {
            LogoMarquee(logos: session.allTeams.map(\.logo), columnCount: 6, fadeTo: 0.65)
            VStack(spacing: 12) {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 30, weight: .bold))
                    .opacity(0.8)
                Text("Hey, I'm up here")
                    .font(.system(size: 26, weight: .heavy, design: .rounded))
                Text("Click the \(Image(systemName: "soccerball")) in your menu bar any time for scores, teams and settings.")
                    .font(.system(size: 14, design: .rounded))
                    .multilineTextAlignment(.center)
                    .opacity(0.7)
                    .frame(maxWidth: 340)
                Button("Open") { OnboardingWindowController.shared.openMenu() }
                    .buttonStyle(.primaryPill)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(28)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(AppBackground())
        .appTheme(session.prefs.settings.theme ?? .system)
        .respectReducedMotion()
        .onAppear { AppAnalytics.screenView("welcome_back") }
        .task { TeamLogoStore.shared.warm(session.allTeams.map(\.logo)) }
    }
}

struct OnboardingView: View {
    @EnvironmentObject var session: AppSession
    @State private var step: Step = .hello
    @State private var query = ""
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var movingForward = true
    static let size = CGSize(width: 580, height: 500)

    enum Step: Int, CaseIterable {
        case hello, teams, alerts, done

        var screen: String {
            switch self {
            case .hello: "onboarding_hello"
            case .teams: "onboarding_teams"
            case .alerts: "onboarding_alerts"
            case .done: "onboarding_done"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .hello: hello
                case .teams: teams
                case .alerts: alerts
                case .done: done
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.asymmetric(
                insertion: .move(edge: movingForward ? .trailing : .leading).combined(with: .opacity),
                removal: .move(edge: movingForward ? .leading : .trailing).combined(with: .opacity)
            ))
            .id(step)
            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipped()
        .background(AppBackground())
        .appTheme(session.prefs.settings.theme ?? .system)
        .respectReducedMotion()
        .onAppear { AppAnalytics.screenView(step.screen) }
        .onChange(of: step) { _, step in AppAnalytics.screenView(step.screen) }
        .task { TeamLogoStore.shared.warm(session.leagues.map(\.logo) + session.allTeams.map(\.logo)) }
    }

    private func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        movingForward = true
        withAnimation(.easeOut(duration: 0.25)) { step = next }
    }

    private func goBack() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        movingForward = false
        withAnimation(.easeOut(duration: 0.25)) { step = previous }
    }

    // MARK: Steps

    private var hello: some View {
        ZStack {
            LogoMarquee(logos: marqueeLogos, fadeTo: 0.55)
            VStack(spacing: 14) {
                Text("All Day I Dream\nAbout Sports")
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .multilineTextAlignment(.center)
                Text("Live scores and goal alerts for the teams you follow, right at the top of your screen.")
                    .font(.system(size: 14, design: .rounded))
                    .multilineTextAlignment(.center)
                    .opacity(0.7)
                    .frame(maxWidth: 360)
                Button("Get started", action: advance)
                    .buttonStyle(.primaryPill)
                    .keyboardShortcut(.defaultAction)
                Text("No account needed.")
                    .font(.system(size: 12))
                    .opacity(0.5)
            }
            .padding(28)
        }
    }

    private var marqueeLogos: [String] { session.allTeams.map(\.logo) }

    private var teams: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("Who do you support?",
                    "Pick as many teams as you like. You can change them any time from the menu bar.")
            TeamSearchField(query: $query)
            ScrollView {
                TeamLeagueList(query: query, columns: 5)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 2)
            }
            .mask(
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: 10)
                    Rectangle()
                }
            )
        }
        .padding(.horizontal, 28)
        .padding(.top, 36)
    }

    private var alerts: some View {
        ZStack(alignment: .top) {
            LogoMarquee(logos: marqueeLogos, fadeTo: 1)
                .frame(height: 130)
            alertsContent
        }
    }

    private var alertsContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading("How much do you want to hear?",
                    "Alerts drop from the notch while you work. Pick one to see it.")
            ForEach(AlertPreset.allCases, id: \.self) { preset in
                presetCard(preset)
            }
            HStack {
                Text("Open at login so you never miss a goal").font(.system(size: 13))
                Spacer()
                Toggle("Open at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { on in
                        launchAtLogin = on
                        LaunchAtLogin.set(enabled: on)
                        session.updateSettings { $0.launchAtLogin = on }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            .padding(.top, 4)
            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.top, 96)
    }

    private func presetCard(_ preset: AlertPreset) -> some View {
        let selected = AlertPreset.matching(session.prefs.settings) == preset
        return Button {
            session.updateSettings { preset.apply(to: &$0) }
            OverlayManager.shared.previewAlert(preset.sampleEvent)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(preset.label).font(.system(size: 14, weight: .bold, design: .rounded))
                Text(preset.summary).font(.system(size: 12)).opacity(0.65)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.primary.opacity(selected ? 0.12 : 0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(selected ? Color.primary : .clear, lineWidth: 0.75)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverLift()
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var done: some View {
        ZStack {
            LogoMarquee(logos: marqueeLogos, fadeTo: 0.55)
            VStack(spacing: 14) {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 36, weight: .bold))
                    .opacity(0.8)
                Text("I live in your menu bar")
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                Text("Click the \(Image(systemName: "soccerball")) at the top of your screen for scores, teams and settings. When your team scores, you'll see it wherever you are.")
                    .font(.system(size: 14, design: .rounded))
                    .multilineTextAlignment(.center)
                    .opacity(0.7)
                    .frame(maxWidth: 380)
                Button("Show me") { OnboardingWindowController.shared.finish() }
                    .buttonStyle(.primaryPill)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(28)
        }
    }

    private func heading(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 22, weight: .heavy, design: .rounded))
            Text(subtitle).font(.system(size: 13)).opacity(0.65)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if step != .hello {
                Button(action: goBack) {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.hoverHighlight)
            }
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { s in
                    Circle()
                        .fill(Color.primary.opacity(s == step ? 0.9 : 0.15))
                        .frame(width: 6, height: 6)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")
            Spacer()
            switch step {
            case .teams:
                Text("\(session.fanTeamIds.count) followed").font(.system(size: 12)).opacity(0.6)
                Button("Continue", action: advance)
                    .buttonStyle(.primaryPill)
                    .disabled(session.fanTeamIds.isEmpty)
                    .opacity(session.fanTeamIds.isEmpty ? 0.35 : 1)
                    .keyboardShortcut(.defaultAction)
            case .alerts:
                Button("Continue", action: advance)
                    .buttonStyle(.primaryPill)
                    .keyboardShortcut(.defaultAction)
            case .hello:
                Link("Privacy policy", destination: URL(string: "https://alldayidreamaboutsports.com/privacy/")!)
                    .font(.system(size: 12))
                    .opacity(0.6)
            case .done:
                Text("This window won't open again").font(.system(size: 12)).opacity(0.5)
            }
        }
        .frame(height: 40)
        .padding(.horizontal, 28)
        .padding(.vertical, 12)
        .overlay(alignment: .top) { Divider() }
    }
}
