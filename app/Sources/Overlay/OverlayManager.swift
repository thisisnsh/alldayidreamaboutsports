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

enum BallPhase {
    case hidden, dropping, tapping
}

/// ONE queue of events, displayed in SETS:
/// - A set is up to `notchStackMax` pills stacked under the notch. It shows
///   at once, stays `pillHoldSeconds`, then the next set follows. Events that
///   arrive while a set is up simply wait — nothing is ever dropped.
/// - A ✕ under the stack dismisses the whole set early (next set comes).
/// - Fan goals in the displayed set drive the celebration: one confetti burst
///   per goal (fire-and-forget), and a single center ball carrying the flags
///   of every team that scored — taps celebrate all of them.
@MainActor
final class OverlayManager: ObservableObject {
    static let shared = OverlayManager()

    @Published private(set) var activeSet: [NotchItem] = []
    @Published private(set) var ballEvents: [MatchEvent] = [] // fan goals of the current set
    @Published private(set) var ballPhase: BallPhase = .hidden
    @Published private(set) var confettiBursts: [ConfettiBurst] = []
    @Published var tapBursts = 0 // increments per user tap → spawns mini balls

    private var queue: [NotchItem] = []
    private var scheduled: [DispatchWorkItem] = []
    private var queueBusy = false  // set synchronously so rapid-fire pushes can't race startNextSetIfIdle
    // Full-screen, click-through panel hosting confetti, the ball, and the pill
    // stack (so the rest of the screen stays fully usable). The single stack ✕
    // gets its own tiny non-click-through panel below the stack, since the
    // display panel passes all clicks through.
    private var displayPanel: NSPanel?
    private var interactPanel: NSPanel?
    private var dismissPanel: NSPanel?

    private var params: AnimationParams { ControlPlane.shared.animationParams }
    private var setSize: Int { max(1, params.notchStackMax) }

    // MARK: Intake — the single queue

    func submit(_ event: MatchEvent, isFanGoal: Bool) {
        enqueue(NotchItem(
            id: event.eventId,
            icon: pillIcon(for: event),
            iconColor: pillIconColor(for: event),
            title: pillTitle(for: event),
            subtitle: pillSubtitle(for: event),
            fanGoal: isFanGoal ? event : nil
        ))
    }

    private func enqueue(_ item: NotchItem) {
        // Covers stragglers that bypass EventRouter (celebration count pills
        // resolving after a sign-out mid-set).
        guard AppSession.shared.isSignedIn else { return }
        guard queue.allSatisfy({ $0.id != item.id }),
              activeSet.allSatisfy({ $0.id != item.id }) else { return }
        queue.append(item)
        startNextSetIfIdle()
    }

    /// VAR cancelled a goal. The pill stays queued (it's information), but it
    /// no longer triggers ball/confetti; if the ball is currently celebrating
    /// that team, it stops celebrating it (and goes away if no teams remain).
    func cancelGoal(fixtureId: Int, teamId: Int?) {
        for index in queue.indices
        where queue[index].fanGoal?.fixtureId == fixtureId && queue[index].fanGoal?.teamId == teamId {
            queue[index].fanGoal = nil
        }
        guard ballPhase != .hidden else { return }
        ballEvents.removeAll { $0.fixtureId == fixtureId && $0.teamId == teamId }
        if ballEvents.isEmpty {
            dismissBall()
        }
    }

    /// Kill switch / preview: drop everything pending and end the current set.
    func dismissAll() {
        queue.removeAll()
        endSet()
    }

    // MARK: Set lifecycle

    /// Stagger between pill drops within a set.
    private static let pillDropStagger = 0.18

    private func startNextSetIfIdle() {
        guard !queueBusy, !queue.isEmpty else { return }
        queueBusy = true
        let set = Array(queue.prefix(setSize))
        queue.removeFirst(set.count)
        showDisplayPanel()
        startHoverTracking()

        // Pills drop from the notch one by one — each new one takes the top
        // spot and pushes the existing ones down.
        for (index, item) in set.enumerated() {
            schedule(after: Double(index) * Self.pillDropStagger) { [self] in
                withAnimation(.spring(duration: 0.45, bounce: 0.25)) {
                    activeSet.insert(item, at: 0)
                }
            }
        }

        let fanGoals = set.compactMap(\.fanGoal)
        let settings = AppSession.shared.prefs.settings
        if settings.confetti ?? true {
            fireConfetti(count: fanGoals.count)
        }
        if settings.goalCenter ?? true, !fanGoals.isEmpty {
            startBall(for: fanGoals)
        }
        schedule(after: params.pillHoldSeconds) { [self] in endSet() }
    }

    /// Natural expiry or the stack ✕: the whole set leaves (ball included),
    /// then the next set follows.
    func endSet() {
        guard !activeSet.isEmpty || queueBusy else { return }
        cancelScheduled()
        finishBall()
        hideDismissPanel()
        withAnimation(.easeIn(duration: 0.35)) {
            activeSet = []
        }
        schedule(after: 0.45) { [self] in
            queueBusy = false
            startNextSetIfIdle()
            if activeSet.isEmpty { stopHoverTracking() }
            hidePanelsIfDone()
        }
    }

    // MARK: Ball — one ball for every goaled team in the set

    private func startBall(for goals: [MatchEvent]) {
        ballEvents = goals
        tapBursts = 0
        ballPhase = .dropping
        schedule(after: params.ballDropSeconds) { [self] in
            guard ballPhase == .dropping else { return }
            ballPhase = .tapping
            CelebrationService.shared.beginWindow(
                targets: ballEvents.compactMap { event in
                    guard event.fixtureId > 0 else { return nil }
                    return event.teamId.map { (fixtureId: event.fixtureId, teamId: String($0)) }
                }
            )
            showInteractPanel()
        }
    }

    /// Ball ✕ — only the ball goes; the notification set stays.
    func dismissBall() {
        guard ballPhase != .hidden else { return }
        flushTapsAndQueueCounts()
        withAnimation(.easeOut(duration: 0.3)) {
            ballPhase = .hidden
            ballEvents = []
        }
        hideInteractPanel()
    }

    /// Set is ending — the ball fades out with it.
    private func finishBall() {
        guard ballPhase != .hidden else { return }
        flushTapsAndQueueCounts()
        fadeOutInteractPanel(duration: 0.35)
        withAnimation(.easeOut(duration: 0.35)) {
            ballPhase = .hidden
            ballEvents = []
        }
        schedule(after: 0.4) { [self] in hideInteractPanel() }
    }

    /// The ball window closed: stop the tap counter (CelebrationService POSTs
    /// the batch) and fold your own taps into the local match total so the menu
    /// reflects them at once. The on-screen count notification is NOT queued
    /// here — it fires for every client, tapper or not, when LiveStore's
    /// post-goal poll window converges (`notifyCelebrationCount`), so all apps
    /// show the same final tally instead of a partial, per-client snapshot.
    private func flushTapsAndQueueCounts() {
        let targets: [(fixtureId: Int, teamId: String)] = ballEvents.compactMap { event in
            guard event.fixtureId > 0 else { return nil }
            return event.teamId.map { (fixtureId: event.fixtureId, teamId: String($0)) }
        }
        let taps = tapBursts
        CelebrationService.shared.endWindow()
        guard !targets.isEmpty, taps > 0,
              AppSession.shared.prefs.settings.eventEnabled(.celebration) else { return }

        // Optimistic: reflect your own taps in the local total now, before any
        // network round-trip. The 60s poll later max-merges the server total in,
        // so this never double-counts.
        for target in targets {
            AppSession.shared.addLocalCelebrations(taps, teamId: target.teamId, fixtureId: target.fixtureId)
        }
    }

    /// Queue the celebration-count notification for one team from the converged
    /// match total. Driven by LiveStore when the post-goal poll window ends, so
    /// every client — whether or not it tapped — surfaces the same final tally.
    func notifyCelebrationCount(fixtureId: Int, teamId: String) {
        guard AppSession.shared.prefs.settings.eventEnabled(.celebration) else { return }
        let count = AppSession.shared.celebrationTotals[fixtureId]?[teamId] ?? 0
        guard count > 0 else { return }
        let team = TeamCatalog.team(for: Int(teamId) ?? -1, in: AppSession.shared.teams)
        enqueue(NotchItem(
            id: "count:\(fixtureId):\(teamId):\(Date().timeIntervalSince1970)",
            icon: pillIcon(for: .celebration),
            iconColor: pillIconColor(for: .celebration),
            title: [.text("\(count.formattedCompact) celebrations for \(team.name) this match")],
            subtitle: nil,
            fanGoal: nil
        ))
    }

    func registerTap() {
        CelebrationService.shared.registerTap()
        tapBursts += 1
    }

    // MARK: Confetti — fire and forget, never waits for anything

    private func fireConfetti(count: Int) {
        guard count > 0 else { return }
        for _ in 0 ..< count {
            let burst = ConfettiBurst()
            confettiBursts.append(burst)
            schedule(after: 5.5) { [self] in
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
        dismissAll()
        submit(event, isFanGoal: true)
    }

    // MARK: Scheduling

    private func schedule(after seconds: Double, _ block: @escaping () -> Void) {
        let work = DispatchWorkItem(block: block)
        scheduled.append(work)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func cancelScheduled() {
        scheduled.forEach { $0.cancel() }
        scheduled.removeAll()
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
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = clickThrough
        panel.sharingType = .readOnly
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        return panel
    }

    /// Hosting view for a panel whose frame WE control. `sizingOptions = []`
    /// stops the hosting view from driving the window's content-size
    /// constraints off the SwiftUI ideal size — without it, continuously
    /// animating content (confetti, the dropping ball, spring-inserted pills)
    /// re-marks the window for an "Update Constraints in Window" pass every
    /// frame until AppKit exceeds its pass budget and throws (app crash).
    private static func makeHostingView<Content: View>(_ rootView: Content) -> NSHostingView<Content> {
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.sizingOptions = []
        return hostingView
    }

    // nil when no display is active (e.g. a Mac mini with its screen asleep or
    // detached). Every panel show guards on it — the event is still recorded
    // and the system's time-sensitive notification still fires; we just don't
    // draw the overlay. Indexing NSScreen.screens here used to crash.
    private var screen: NSScreen? { NSScreen.main ?? NSScreen.screens.first }

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
        dismissPanel?.appearance = appearance
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

    /// The display panel stays while anything is on screen in either form.
    private func hidePanelsIfDone() {
        guard activeSet.isEmpty, queue.isEmpty, ballPhase == .hidden, confettiBursts.isEmpty else { return }
        displayPanel?.orderOut(nil)
    }

    /// The pill stack reports its real rendered size as pills drop in and out;
    /// it positions the ✕ and defines the hover region that reveals it.
    private var measuredStackSize: CGSize = .zero

    func reportStackSize(_ size: CGSize) {
        measuredStackSize = size
        // Keep the ✕ pinned under the stack if it's currently showing.
        if dismissPanel?.isVisible == true {
            dismissPanel?.setFrame(dismissPanelRect(), display: true)
        }
        refreshDismissCross()
    }

    private func dismissPanelRect() -> NSRect {
        guard let screen else { return .zero }
        let inset = (NSScreen.main?.safeAreaInsets.top).flatMap { $0 > 0 ? $0 : nil } ?? 26
        let pillSpacing: CGFloat = 8
        let size: CGFloat = 22
        return NSRect(
            x: screen.frame.midX - size / 2,
            y: screen.frame.maxY - inset - 6 - measuredStackSize.height - pillSpacing - size,
            width: size,
            height: size
        )
    }

    // MARK: Stack ✕ — hover-revealed

    private var hoverTimer: Timer?

    /// Poll the cursor while a set is up (passive — never consumes clicks, so
    /// the screen stays fully usable) so the ✕ shows only while the pointer is
    /// over the stack. A timer is used rather than a global mouse-moved monitor
    /// because those fire unreliably over click-through windows like ours.
    private func startHoverTracking() {
        guard hoverTimer == nil else { return }
        let timer = Timer(timeInterval: 0.06, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshDismissCross() }
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    private func stopHoverTracking() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        hideDismissPanel()
    }

    /// The screen rect (bottom-left origin) that counts as "hovering the stack":
    /// the pills plus a margin reaching down to include the ✕ itself, so moving
    /// onto the ✕ doesn't dismiss the hover.
    private func stackHoverRegion() -> NSRect? {
        guard let screen, measuredStackSize.height > 0 else { return nil }
        let inset = (NSScreen.main?.safeAreaInsets.top).flatMap { $0 > 0 ? $0 : nil } ?? 26
        let pad: CGFloat = 14
        let belowExtent: CGFloat = 8 + 22 + 10 // pill gap + ✕ + slack
        let w = max(measuredStackSize.width, 60) + pad * 2
        let top = screen.frame.maxY - inset - 6
        let bottom = top - measuredStackSize.height - belowExtent
        return NSRect(x: screen.frame.midX - w / 2, y: bottom, width: w, height: top + pad - bottom)
    }

    /// Show the ✕ iff there are pills and the cursor is over the stack region.
    private func refreshDismissCross() {
        guard !activeSet.isEmpty, let region = stackHoverRegion(),
              region.contains(NSEvent.mouseLocation) else {
            hideDismissPanel()
            return
        }
        showDismissPanel()
    }

    /// Small clickable ✕ floating just below the pill stack (the display panel
    /// is click-through, so the button needs its own panel).
    private func showDismissPanel() {
        guard screen != nil else { return }
        let rect = dismissPanelRect()
        if dismissPanel == nil {
            let panel = Self.makePanel(frame: rect, clickThrough: false)
            panel.contentView = Self.makeHostingView(SetDismissButton().environmentObject(self))
            dismissPanel = panel
        }
        dismissPanel?.appearance = overlayAppearance
        dismissPanel?.setFrame(rect, display: true)
        dismissPanel?.orderFrontRegardless()
    }

    private func hideDismissPanel() {
        dismissPanel?.orderOut(nil)
    }

    /// Fades the tappable ball in lockstep with the scene so the celebration
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
        let size: CGFloat = 320
        let rect = NSRect(
            x: screen.frame.midX - size / 2,
            y: screen.frame.midY - size / 2,
            width: size,
            height: size
        )
        if interactPanel == nil {
            let panel = Self.makePanel(frame: rect, clickThrough: false)
            panel.contentView = Self.makeHostingView(InteractiveBallView().environmentObject(self))
            interactPanel = panel
        }
        interactPanel?.appearance = overlayAppearance
        interactPanel?.setFrame(rect, display: true)
        interactPanel?.orderFrontRegardless()
    }

    private func hideInteractPanel() {
        interactPanel?.orderOut(nil)
        interactPanel?.alphaValue = 1 // reset after a fade-out
    }
}

/// The ✕ shared by the notification stack and the celebration ball, so both
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

/// The ✕ below the notification set — clicking it ends the whole set early.
struct SetDismissButton: View {
    @EnvironmentObject var overlay: OverlayManager

    var body: some View {
        DismissCrossButton { overlay.endSet() }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
