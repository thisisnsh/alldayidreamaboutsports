import AppKit
import SwiftUI

/// One notification. `fanGoal` is set when this is a goal by a followed team —
/// that's what drives confetti and the center ball for the set it shows in.
struct NotchItem: Identifiable, Equatable {
    let id: String
    let icon: String
    let iconColor: Color
    let title: [PillSegment]
    var subtitle: [PillSegment]?
    var fanGoal: MatchEvent?

    static func == (lhs: NotchItem, rhs: NotchItem) -> Bool { lhs.id == rhs.id }
}

/// Fire-and-forget confetti token; bursts overlap freely and outlive sets.
struct ConfettiBurst: Identifiable {
    let id = UUID()
}

private struct QueuedNotchItem {
    var item: NotchItem
    let arrivalSeq: Int
    let isGoal: Bool
}

enum BallPhase {
    case hidden, showing
}

/// TWO queues of events, displayed in SETS:
/// - Goals are kept in a priority queue; every other event waits separately.
///   Each set takes goals first, then fills remaining slots with other events.
/// - The visible stack is chronological within the selected set: oldest at the
///   top, newest at the bottom, and it stays up for `pillHoldSeconds`.
/// - Fan goals start confetti and one shared center ball when their goal pill
///   drops, and the ball leaves with the set — the two are on screen for
///   exactly the same time.
@MainActor
final class OverlayManager: ObservableObject {
    static let shared = OverlayManager()

    @Published private(set) var activeSet: [NotchItem] = []
    @Published private(set) var ballEvents: [MatchEvent] = [] // fan goals of the current set
    @Published private(set) var ballPhase: BallPhase = .hidden
    @Published private(set) var confettiBursts: [ConfettiBurst] = []

    private var goalQueue: [QueuedNotchItem] = []
    private var otherQueue: [QueuedNotchItem] = []
    private var nextArrivalSeq = 0
    private var lifecycleScheduled: [DispatchWorkItem] = []
    private var queueBusy = false  // set synchronously so rapid-fire pushes can't race startNextSetIfIdle
    private var displayPanel: NSPanel?
    private var interactPanel: NSPanel?
    private var displayObserver: NSObjectProtocol?

    private init() {
        displayObserver = NotificationCenter.default.addObserver(
            forName: .overlayDisplayTargetDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.displayTargetDidChange() }
        }
    }

    /// How long each notification set (and the ball with it) stays on screen.
    private let pillHoldSeconds: TimeInterval = 7
    /// Notification set size — how many pills display at once.
    private let setSize = 5

    // MARK: Intake — two queues, goals prioritized for selection

    func submit(_ event: MatchEvent, isFanGoal: Bool) {
        enqueue(NotchItem(
            id: event.eventId,
            icon: pillIcon(for: event),
            iconColor: pillIconColor(for: event),
            title: pillTitle(for: event),
            subtitle: pillSubtitle(for: event),
            fanGoal: isFanGoal ? event : nil
        ), isGoal: event.type == .goal)
    }

    private func enqueue(_ item: NotchItem, isGoal: Bool = false) {
        guard goalQueue.allSatisfy({ $0.item.id != item.id }),
              otherQueue.allSatisfy({ $0.item.id != item.id }),
              activeSet.allSatisfy({ $0.id != item.id }) else { return }
        let queued = QueuedNotchItem(item: item, arrivalSeq: nextArrivalSeq, isGoal: isGoal)
        nextArrivalSeq += 1
        if isGoal {
            goalQueue.append(queued)
        } else {
            otherQueue.append(queued)
        }
        startNextSetIfIdle()
    }

    /// VAR cancelled a goal. The pill stays queued (it's information), but it
    /// no longer triggers ball/confetti; if the ball is showing that team, it
    /// drops it (and goes away if no teams remain).
    func cancelGoal(fixtureId: Int, teamId: Int?) {
        for index in goalQueue.indices
        where goalQueue[index].item.fanGoal?.fixtureId == fixtureId && goalQueue[index].item.fanGoal?.teamId == teamId {
            goalQueue[index].item.fanGoal = nil
        }
        guard ballPhase != .hidden else { return }
        ballEvents.removeAll { $0.fixtureId == fixtureId && $0.teamId == teamId }
        if ballEvents.isEmpty {
            // VAR took the goal back — the ball goes, but nobody dismissed it.
            hideBall()
        }
    }

    /// Preview: drop everything pending and end the current set.
    func dismissAll() {
        goalQueue.removeAll()
        otherQueue.removeAll()
        hideBall()
        endSet()
    }

    // MARK: Set lifecycle

    /// Stagger between pill drops within a set.
    private static let pillDropStagger = 0.18

    private func startNextSetIfIdle() {
        guard !queueBusy, !goalQueue.isEmpty || !otherQueue.isEmpty else { return }
        queueBusy = true
        let goalsToTake = min(setSize, goalQueue.count)
        var selected = Array(goalQueue.prefix(goalsToTake))
        goalQueue.removeFirst(goalsToTake)

        let remainingSlots = setSize - selected.count
        if remainingSlots > 0 {
            let othersToTake = min(remainingSlots, otherQueue.count)
            selected.append(contentsOf: otherQueue.prefix(othersToTake))
            otherQueue.removeFirst(othersToTake)
        }

        let set = selected
            .sorted { $0.arrivalSeq < $1.arrivalSeq }
            .map(\.item)
        showDisplayPanel()

        // Pills publish top-to-bottom in chronological order: oldest first,
        // newest last, even though goals were prioritized for selection.
        for (index, item) in set.enumerated() {
            scheduleLifecycle(after: Double(index) * Self.pillDropStagger) { [self] in
                withAnimation(.spring(duration: 0.45, bounce: 0.25)) {
                    activeSet.append(item)
                }
            }
        }

        let fanGoals = set.compactMap(\.fanGoal)
        // One per displayed set — the unit a user actually perceives, and the
        // only overlay event that fires per set rather than per event.
        AppAnalytics.overlaySetShown(count: set.count, hasFanGoal: !fanGoals.isEmpty)
        // Ball and confetti come in as the first fan-goal pill drops, and the
        // ball goes out with the set in `endSet`.
        if AppSession.shared.prefs.settings.goalCenter ?? true,
           let first = set.firstIndex(where: { $0.fanGoal != nil }) {
            scheduleLifecycle(after: Double(first) * Self.pillDropStagger) { [self] in
                fireConfetti(count: fanGoals.count)
                startBall(for: fanGoals)
            }
        }
        scheduleLifecycle(after: pillHoldSeconds) { [self] in endSet() }
    }

    /// Natural expiry: the whole set leaves, then the next set follows.
    func endSet() {
        guard !activeSet.isEmpty || queueBusy else { return }
        cancelLifecycleScheduled()
        finishBall()
        withAnimation(.easeIn(duration: 0.35)) {
            activeSet = []
        }
        scheduleLifecycle(after: 0.45) { [self] in
            queueBusy = false
            startNextSetIfIdle()
            hidePanelsIfDone()
        }
    }

    // MARK: Ball — the fan-goal animation for the active displayed set

    private func startBall(for goals: [MatchEvent]) {
        // A followed team scored and the animation actually fired. Skips the
        // Settings preview, whose synthetic event carries fixture 0 — that one
        // reports as `celebration_preview`.
        if goals.contains(where: { $0.fixtureId > 0 }) {
            AppAnalytics.celebrationShown()
        }
        ballEvents = goals
        ballPhase = .showing
        showInteractPanel()
    }

    /// Ball ✕ — only the ball goes; the notification set stays.
    func dismissBall() {
        guard ballPhase != .hidden else { return }
        // The ✕ is the one overlay control a user can press, so this is what
        // says whether people close the ball or let it ride (the other
        // half is `finishBall`'s `timeout`).
        AppAnalytics.overlayDismissed(reason: "user")
        hideBall()
    }

    /// Tear the ball down WITHOUT reporting a dismissal — a VAR reversal or
    /// the preview reset is not the user closing anything.
    private func hideBall() {
        guard ballPhase != .hidden else { return }
        withAnimation(.easeOut(duration: 0.3)) {
            ballPhase = .hidden
            ballEvents = []
        }
        hideInteractPanel()
        hidePanelsIfDone()
    }

    /// Natural ball expiry — leaves with its set, on the pills' curve.
    private func finishBall() {
        guard ballPhase != .hidden else { return }
        AppAnalytics.overlayDismissed(reason: "timeout")
        fadeOutInteractPanel(duration: 0.35)
        withAnimation(.easeIn(duration: 0.35)) {
            ballPhase = .hidden
            ballEvents = []
        }
        scheduleAmbient(after: 0.4) { [self] in hideInteractPanel() }
    }

    // MARK: Confetti — fire and forget, never waits for anything

    private func fireConfetti(count: Int) {
        guard count > 0 else { return }
        for _ in 0 ..< count {
            let burst = ConfettiBurst()
            confettiBursts.append(burst)
            scheduleAmbient(after: 5.5) { [self] in
                confettiBursts.removeAll { $0.id == burst.id }
                hidePanelsIfDone()
            }
        }
        showDisplayPanel()
    }

    // MARK: Preview

    /// Settings "Preview animation": a generic fan goal (Team A vs Team B)
    /// through the exact same pipeline — pill set + confetti + ball, per the
    /// user's toggles. Jumps ahead of anything queued.
    func preview() {
        let event = MatchEvent(
            eventId: "preview:\(Date().timeIntervalSince1970)",
            type: .goal,
            fixtureId: 0,
            leagueId: 1,
            teamId: TeamCatalog.previewHome.id,
            player: "Player Name",
            minute: 73,
            homeTeamId: TeamCatalog.previewHome.id,
            awayTeamId: TeamCatalog.previewAway.id,
            homeName: TeamCatalog.previewHome.name,
            awayName: TeamCatalog.previewAway.name,
            homeGoals: 1,
            awayGoals: 0
        )
        AppAnalytics.celebrationPreview()
        dismissAll()
        submit(event, isFanGoal: true)
    }

    /// Settings / onboarding sample: one notch drop of `type` for a generic
    /// match, so a size or alert-level change shows what it does. Never a fan
    /// goal — the goal animation has its own Preview.
    func previewAlert(_ type: MatchEventType) {
        let event = MatchEvent(
            eventId: "preview-alert:\(Date().timeIntervalSince1970)",
            type: type,
            fixtureId: 0,
            leagueId: 1,
            teamId: TeamCatalog.previewHome.id,
            player: "Player Name",
            minute: 73,
            homeTeamId: TeamCatalog.previewHome.id,
            awayTeamId: TeamCatalog.previewAway.id,
            homeName: TeamCatalog.previewHome.name,
            awayName: TeamCatalog.previewAway.name,
            homeGoals: type == .goal ? 1 : 0,
            awayGoals: 0
        )
        dismissAll()
        submit(event, isFanGoal: false)
    }

    // MARK: Scheduling

    private func scheduleLifecycle(after seconds: Double, _ block: @escaping () -> Void) {
        let work = DispatchWorkItem(block: block)
        lifecycleScheduled.append(work)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func scheduleAmbient(after seconds: Double, _ block: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: block)
    }

    private func cancelLifecycleScheduled() {
        lifecycleScheduled.forEach { $0.cancel() }
        lifecycleScheduled.removeAll()
    }

    // MARK: Panels

    private static func makePanel(frame: NSRect, clickThrough: Bool) -> NSPanel {
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // `.screenSaver` (not `.statusBar`) so the pill/ball float ABOVE
        // full-screen apps too; the collection behavior lets this accessory app
        // draw over another app's full-screen space. Shared with the pinned
        // capsules via `OverlayWindow` so every overlay floats above everything.
        panel.level = OverlayWindow.level
        panel.collectionBehavior = OverlayWindow.collectionBehavior
        panel.ignoresMouseEvents = clickThrough
        panel.sharingType = .readOnly
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        return panel
    }

    /// Hosting view for a panel whose frame WE control. `sizingOptions = []`
    /// stops the hosting view from driving the window's content-size
    /// constraints off the SwiftUI ideal size — without it, continuously
    /// animating content (confetti, spring-inserted pills)
    /// re-marks the window for an "Update Constraints in Window" pass every
    /// frame until AppKit exceeds its pass budget and throws (app crash).
    private static func makeHostingView<Content: View>(_ rootView: Content) -> NSHostingView<Content> {
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.sizingOptions = []
        return hostingView
    }

    // nil when no display is connected (e.g. a headless Mac mini). The event is
    // still recorded; there is simply nowhere to draw it.
    private var screen: NSScreen? { OverlayDisplayTarget.shared.selectedScreen }

    // The overlay lives in its own NSPanels, so SwiftUI's `preferredColorScheme`
    // (which only affects the app's own windows) never reaches it. Drive each
    // panel's appearance from the user's theme so the pill is black in dark and
    // white in light, independent of the system setting. nil = follow system.
    private var overlayAppearance: NSAppearance? {
        switch AppSession.shared.prefs.settings.theme ?? .system {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    /// Re-apply the theme to any panels already on screen — the Appearance
    /// setting can change while a pill/ball is showing.
    func applyOverlayTheme() {
        let appearance = overlayAppearance
        displayPanel?.appearance = appearance
        interactPanel?.appearance = appearance
    }

    private func showDisplayPanel() {
        guard let screen else { return }
        if displayPanel == nil {
            let panel = Self.makePanel(frame: screen.frame, clickThrough: true)
            panel.contentView = Self.makeHostingView(OverlayDisplayView().environmentObject(self))
            displayPanel = panel
        }
        displayPanel?.appearance = overlayAppearance
        displayPanel?.setFrame(screen.frame, display: true)
        displayPanel?.orderFrontRegardless()
    }

    private func displayTargetDidChange() {
        guard let screen else {
            displayPanel?.orderOut(nil)
            interactPanel?.orderOut(nil)
            return
        }
        if let displayPanel, displayPanel.isVisible {
            displayPanel.setFrame(screen.frame, display: true)
        }
        if let interactPanel, interactPanel.isVisible {
            interactPanel.setFrame(interactionFrame(on: screen), display: true)
        }
        // Re-evaluate selected-screen safe-area geometry in NotchStackView.
        objectWillChange.send()
    }

    /// The display panel stays while anything is on screen in either form.
    /// `queueBusy` covers the set-start race: a just-started set flips it
    /// synchronously but appends its pills to `activeSet` a tick later, so
    /// without it the endSet continuation (startNextSetIfIdle → hide) would
    /// order the panel out under a set whose pills haven't landed yet.
    private func hidePanelsIfDone() {
        guard !queueBusy, activeSet.isEmpty, goalQueue.isEmpty, otherQueue.isEmpty,
              ballPhase == .hidden, confettiBursts.isEmpty else { return }
        displayPanel?.orderOut(nil)
    }

    /// Fades the ball's panel in lockstep with the scene so the whole thing
    /// dissolves as one piece.
    private func fadeOutInteractPanel(duration: Double) {
        guard let panel = interactPanel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            panel.animator().alphaValue = 0
        }
    }

    private func showInteractPanel() {
        guard let screen else { return }
        let rect = interactionFrame(on: screen)
        if interactPanel == nil {
            let panel = Self.makePanel(frame: rect, clickThrough: false)
            panel.contentView = Self.makeHostingView(InteractiveBallView().environmentObject(self))
            interactPanel = panel
        }
        interactPanel?.appearance = overlayAppearance
        interactPanel?.setFrame(rect, display: true)
        interactPanel?.orderFrontRegardless()
    }

    private func interactionFrame(on screen: NSScreen) -> NSRect {
        let size: CGFloat = 320
        return NSRect(
            x: screen.frame.midX - size / 2,
            y: screen.frame.midY - size / 2,
            width: size,
            height: size
        )
    }

    private func hideInteractPanel() {
        interactPanel?.orderOut(nil)
        interactPanel?.alphaValue = 1 // reset after a fade-out
    }
}

/// The ✕ shared by the notification stack and the goal ball, so both
/// look identical. The caller supplies what dismissing means.
struct DismissCrossButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(.white, .black.opacity(0.6))
        }
        .buttonStyle(.plain)
        .hoverLift()
    }
}
