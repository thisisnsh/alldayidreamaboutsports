import AppKit
import SwiftUI

/// One notification. `fanGoal` is set when this is a goal by a followed team —
/// that's what drives confetti and the center ball for the set it shows in.
struct NotchItem: Identifiable, Equatable {
    let id: String
    let icon: String
    let iconColor: Color
    let text: String
    var subtext: String?
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
            text: pillText(for: event),
            subtext: pillSubtext(for: event),
            fanGoal: isFanGoal ? event : nil
        ))
    }

    private func enqueue(_ item: NotchItem) {
        guard queue.allSatisfy({ $0.id != item.id }),
              activeSet.allSatisfy({ $0.id != item.id }) else { return }
        queue.append(item)
        startNextSetIfIdle()
    }

    /// VAR cancelled a goal. The pill stays queued (it's information), but it
    /// no longer triggers ball/confetti; if the ball is currently celebrating
    /// that team, it stops celebrating it (and goes away if no teams remain).
    func cancelGoal(fixtureId: Int, teamCode: String?) {
        for index in queue.indices
        where queue[index].fanGoal?.fixtureId == fixtureId && queue[index].fanGoal?.teamCode == teamCode {
            queue[index].fanGoal = nil
        }
        guard ballPhase != .hidden else { return }
        ballEvents.removeAll { $0.fixtureId == fixtureId && $0.teamCode == teamCode }
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
        guard activeSet.isEmpty, !queue.isEmpty else { return }
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
        guard !activeSet.isEmpty else { return }
        cancelScheduled()
        finishBall()
        hideDismissPanel()
        withAnimation(.easeIn(duration: 0.35)) {
            activeSet = []
        }
        schedule(after: 0.45) { [self] in
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
                    event.teamCode.map { (fixtureId: event.fixtureId, teamCode: $0) }
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

    /// One batched flush for all celebrated teams; each team's total comes
    /// back as a normal queued notification (real DB→CDN round trip, so it
    /// lands in a later set whenever it's ready).
    private func flushTapsAndQueueCounts() {
        let targets = ballEvents.compactMap { event in
            event.teamCode.map { (fixtureId: event.fixtureId, teamCode: $0) }
        }
        let taps = tapBursts
        CelebrationService.shared.endWindow()
        guard !targets.isEmpty,
              AppSession.shared.prefs.settings.eventEnabled(.celebration) else { return }
        Task { @MainActor in
            for target in targets {
                let totals = (try? await Services.scores.fetchCelebrations(fixtureId: target.fixtureId)) ?? [:]
                let team = TeamCatalog.team(for: target.teamCode, in: AppSession.shared.teams)
                let count = totals[target.teamCode] ?? 0
                let text: String? = count > 0
                    ? "\(count.formattedCompact) celebrations for \(team.name) this match"
                    : (taps > 0 ? "You celebrated with \(team.name)!" : nil)
                if let text {
                    enqueue(NotchItem(
                        id: "count:\(target.fixtureId):\(target.teamCode):\(Date().timeIntervalSince1970)",
                        icon: pillIcon(for: .celebration),
                        iconColor: pillIconColor(for: .celebration),
                        text: text,
                        subtext: nil,
                        fanGoal: nil
                    ))
                }
            }
        }
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
        let data: [String: Any] = [
            "eventId": "preview:\(Date().timeIntervalSince1970)", "type": "GOAL",
            "fixtureId": "0", "leagueId": "1",
            "homeTeam": TeamCatalog.previewHome.code, "awayTeam": TeamCatalog.previewAway.code,
            "homeName": TeamCatalog.previewHome.name, "awayName": TeamCatalog.previewAway.name,
            "homeGoals": "1", "awayGoals": "0",
            "teamCode": TeamCatalog.previewHome.code, "player": "Player Name", "minute": "73",
        ]
        guard let event = MatchEvent(fcmData: data) else { return }
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
        panel.sharingType = .none // celebrations never photobomb screen shares
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        return panel
    }

    private var screen: NSScreen { NSScreen.main ?? NSScreen.screens[0] }

    private func showDisplayPanel() {
        if displayPanel == nil {
            let panel = Self.makePanel(frame: screen.frame, clickThrough: true)
            panel.contentView = NSHostingView(rootView: OverlayDisplayView().environmentObject(self))
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
        let rect = dismissPanelRect()
        if dismissPanel == nil {
            let panel = Self.makePanel(frame: rect, clickThrough: false)
            panel.contentView = NSHostingView(rootView: SetDismissButton().environmentObject(self))
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
        let size: CGFloat = 320
        let rect = NSRect(
            x: screen.frame.midX - size / 2,
            y: screen.frame.midY - size / 2,
            width: size,
            height: size
        )
        if interactPanel == nil {
            let panel = Self.makePanel(frame: rect, clickThrough: false)
            panel.contentView = NSHostingView(rootView: InteractiveBallView().environmentObject(self))
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
