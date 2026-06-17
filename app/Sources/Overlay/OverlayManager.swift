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

        // Pills drop from the notch one by one — each new one takes the top
        // spot and pushes the existing ones down.
        for (index, item) in set.enumerated() {
            schedule(after: Double(index) * Self.pillDropStagger) { [self] in
                withAnimation(.spring(duration: 0.45, bounce: 0.25)) {
                    activeSet.insert(item, at: 0)
                }
            }
        }
        // The ✕ appears once the last pill has landed; its position comes
        // from the stack's MEASURED height (see reportStackHeight).
        schedule(after: Double(set.count - 1) * Self.pillDropStagger + 0.35) { [self] in
            showDismissPanel()
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

    /// Natural expiry or the ✕ under the stack: the whole set leaves (ball
    /// included), then the next set follows.
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

    /// Your taps show instantly: they're folded into the local total and a
    /// count pill drops right away. The authoritative server total (everyone's
    /// taps) lands ~5s later — long enough for the backend to batch the POST we
    /// just sent into the CDN file — and updates the pill if it grew.
    private func flushTapsAndQueueCounts() {
        let targets: [(fixtureId: Int, teamId: String)] = ballEvents.compactMap { event in
            guard event.fixtureId > 0 else { return nil }
            return event.teamId.map { (fixtureId: event.fixtureId, teamId: String($0)) }
        }
        let taps = tapBursts
        CelebrationService.shared.endWindow()
        guard !targets.isEmpty,
              AppSession.shared.prefs.settings.eventEnabled(.celebration) else { return }

        // Optimistic: reflect your own taps now, before any network round-trip.
        if taps > 0 {
            for target in targets {
                AppSession.shared.addLocalCelebrations(taps, teamId: target.teamId, fixtureId: target.fixtureId)
                queueCelebrationPill(for: target, taps: taps)
            }
        }

        Task { @MainActor in
            // Give the backend time to aggregate everyone's just-sent taps into
            // the CDN file so the read reflects them (and doesn't 404 a fresh
            // file). This matters even when WE didn't tap: the other apps' taps
            // need that window to land, or a non-tapping app reads an empty total.
            try? await Task.sleep(for: .seconds(5))
            for target in targets {
                let totals: [String: Int]
                do {
                    totals = try await Services.scores.fetchCelebrations(fixtureId: target.fixtureId)
                    AppLog.info(.celebrations, "post_window_totals_refresh_complete fixture_id=\(target.fixtureId) teams=\(totals.count)")
                } catch {
                    AppLog.error(.celebrations, "post_window_totals_refresh_failed fixture_id=\(target.fixtureId)", error: error)
                    totals = [:]
                }
                let before = AppSession.shared.celebrationTotals[target.fixtureId]?[target.teamId] ?? 0
                AppSession.shared.mergeCelebrationTotals(totals, fixtureId: target.fixtureId)
                let after = AppSession.shared.celebrationTotals[target.fixtureId]?[target.teamId] ?? 0
                // Only refresh the pill if the authoritative total beat what we
                // already showed optimistically — no redundant duplicate.
                if after > before || (taps == 0 && after > 0) {
                    queueCelebrationPill(for: target, taps: taps)
                }
            }
        }
    }

    /// Drops a celebration-count pill for one team from the current local total.
    private func queueCelebrationPill(for target: (fixtureId: Int, teamId: String), taps: Int) {
        let team = TeamCatalog.team(for: Int(target.teamId) ?? -1, in: AppSession.shared.teams)
        let count = AppSession.shared.celebrationTotals[target.fixtureId]?[target.teamId] ?? 0
        let text: String? = count > 0
            ? "\(count.formattedCompact) celebrations for \(team.name) this match"
            : (taps > 0 ? "You celebrated with \(team.name)!" : nil)
        guard let text else { return }
        enqueue(NotchItem(
            id: "count:\(target.fixtureId):\(target.teamId):\(Date().timeIntervalSince1970)",
            icon: pillIcon(for: .celebration),
            iconColor: pillIconColor(for: .celebration),
            title: [.text(text)],
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

    private func showDisplayPanel() {
        guard let screen else { return }
        if displayPanel == nil {
            let panel = Self.makePanel(frame: screen.frame, clickThrough: true)
            panel.contentView = Self.makeHostingView(OverlayDisplayView().environmentObject(self))
            displayPanel = panel
        }
        displayPanel?.setFrame(screen.frame, display: true)
        displayPanel?.orderFrontRegardless()
    }

    /// The display panel stays while anything is on screen in either form.
    private func hidePanelsIfDone() {
        guard activeSet.isEmpty, queue.isEmpty, ballPhase == .hidden, confettiBursts.isEmpty else { return }
        displayPanel?.orderOut(nil)
    }

    /// The pill stack reports its real rendered height (emoji lines make
    /// pills taller than any estimate) so the ✕ always sits exactly one
    /// pill-gap below the last pill.
    private var measuredStackHeight: CGFloat = 0

    func reportStackHeight(_ height: CGFloat) {
        measuredStackHeight = height
        if dismissPanel?.isVisible == true {
            dismissPanel?.setFrame(dismissPanelRect(), display: true)
        }
    }

    private func dismissPanelRect() -> NSRect {
        guard let screen else { return .zero }
        let inset = (NSScreen.main?.safeAreaInsets.top).flatMap { $0 > 0 ? $0 : nil } ?? 26
        let pillSpacing: CGFloat = 8
        let size: CGFloat = 22
        return NSRect(
            x: screen.frame.midX - size / 2,
            y: screen.frame.maxY - inset - 6 - measuredStackHeight - pillSpacing - size,
            width: size,
            height: size
        )
    }

    /// Small clickable ✕ floating just below the pill stack (the display
    /// panel is click-through, so the button needs its own panel).
    private func showDismissPanel() {
        guard screen != nil else { return }
        let rect = dismissPanelRect()
        if dismissPanel == nil {
            let panel = Self.makePanel(frame: rect, clickThrough: false)
            panel.contentView = Self.makeHostingView(SetDismissButton().environmentObject(self))
            dismissPanel = panel
        }
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
        interactPanel?.setFrame(rect, display: true)
        interactPanel?.orderFrontRegardless()
    }

    private func hideInteractPanel() {
        interactPanel?.orderOut(nil)
        interactPanel?.alphaValue = 1 // reset after a fade-out
    }
}

/// The ✕ under the notification set — clicking it ends the whole set early.
struct SetDismissButton: View {
    @EnvironmentObject var overlay: OverlayManager

    var body: some View {
        Button {
            overlay.endSet()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(.white, .black.opacity(0.75))
        }
        .buttonStyle(.plain)
        .hoverLift()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
