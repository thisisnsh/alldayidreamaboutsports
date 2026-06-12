import AppKit
import SwiftUI

/// One pill in the notch stack. Items appear in real time as events arrive —
/// newest at the bottom, oldest exits from the top.
struct NotchItem: Identifiable, Equatable {
    let id: String
    let icon: String
    let iconColor: Color
    let text: String
    let celebratory: Bool // fan goal → confetti rides along (if enabled)
}

enum OverlayPhase: Equatable {
    case idle
    case ballDropping
    case tapWindow
    case fadeOut // ball + score + minis all fade together
}

/// Two independent presentation lanes, both on the same panels:
/// - Notch stack (information): every event becomes a pill IMMEDIATELY — no
///   queue, nothing is ever missed or stale. Capped; oldest leaves early.
/// - Center celebration (experience): fan goals queue (cap 4) and play
///   back-to-back; the tap window shrinks while others wait.
/// Panels: full-screen click-through display panel + small interactive ball.
@MainActor
final class OverlayManager: ObservableObject {
    static let shared = OverlayManager()

    // Notch lane
    @Published private(set) var notchItems: [NotchItem] = []

    // Celebration lane
    @Published var phase: OverlayPhase = .idle
    @Published var currentEvent: MatchEvent?
    @Published var countTotals: [String: Int] = [:]
    @Published var tapBursts: Int = 0 // increments per user tap → spawns mini balls

    private var celebrationQueue: [MatchEvent] = []
    private static let celebrationQueueMax = 4

    private var displayPanel: NSPanel?
    private var interactPanel: NSPanel?
    private var phaseWork: [DispatchWorkItem] = []
    private var tapWindowWork: DispatchWorkItem?
    private var notchExpiry: [String: DispatchWorkItem] = [:]

    private var params: AnimationParams { ControlPlane.shared.animationParams }

    // MARK: Notch stack — real-time, no queue

    func showPill(for event: MatchEvent, celebratory: Bool) {
        push(NotchItem(
            id: event.eventId,
            icon: pillIcon(for: event),
            iconColor: pillIconColor(for: event),
            text: pillText(for: event),
            celebratory: celebratory
        ))
    }

    /// The post-celebration total — a regular stack item like any other.
    func pushCountItem(text: String) {
        push(NotchItem(
            id: "count:\(Date().timeIntervalSince1970)",
            icon: "party.popper.fill",
            iconColor: .yellow,
            text: text,
            celebratory: false
        ))
    }

    private func push(_ item: NotchItem) {
        guard notchItems.allSatisfy({ $0.id != item.id }) else { return }
        withAnimation(.spring(duration: 0.45, bounce: 0.2)) {
            notchItems.append(item)
        }
        // Over the cap: the oldest (top) leaves early via its normal exit.
        if notchItems.count > params.notchStackMax, let oldest = notchItems.first {
            expire(id: oldest.id)
        }
        let work = DispatchWorkItem { [weak self] in self?.expire(id: item.id) }
        notchExpiry[item.id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + params.pillHoldSeconds, execute: work)
        showDisplayPanel()
    }

    private func expire(id: String) {
        notchExpiry.removeValue(forKey: id)?.cancel()
        withAnimation(.easeIn(duration: 0.35)) {
            notchItems.removeAll { $0.id == id }
        }
        hidePanelsIfDone(after: 0.4)
    }

    // MARK: Celebration lane — queued, cap 4, adaptive tap window

    func enqueueCelebration(_ event: MatchEvent) {
        // Collapse: a newer goal in the same fixture replaces a queued one.
        celebrationQueue.removeAll { $0.fixtureId == event.fixtureId }
        guard celebrationQueue.count < Self.celebrationQueueMax else { return }
        celebrationQueue.append(event)
        if phase == .idle {
            startNextCelebration()
        } else if phase == .tapWindow {
            // Someone's now waiting — shrink the current window to the busy
            // duration so the queue drains fast.
            rescheduleTapWindow(after: params.tapWindowBusySeconds)
        }
    }

    /// A VAR cancellation kills the queued (or playing) celebration of that goal.
    func cancelCelebration(fixtureId: Int, teamCode: String?) {
        celebrationQueue.removeAll { $0.fixtureId == fixtureId && $0.teamCode == teamCode }
        if let current = currentEvent, phase != .idle,
           current.fixtureId == fixtureId, current.teamCode == teamCode {
            dismissCurrent()
        }
    }

    func dismissCurrent() {
        CelebrationService.shared.endWindow()
        cancelScheduledPhases()
        finishCurrent()
    }

    func dismissAll() {
        celebrationQueue.removeAll()
        dismissCurrent()
    }

    func updateCelebrationCount(fixtureId: Int, totals: [String: Int]) {
        guard currentEvent?.fixtureId == fixtureId else { return }
        countTotals = totals
    }

    /// Settings "Preview animation" — plays exactly the combination the user
    /// configured, instantly: pill (+confetti if on), and the full celebration
    /// when goal-in-center is on. Generic Team A/B so it reads as an example.
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
        dismissAll() // direct user action: jump ahead of anything playing
        showPill(for: event, celebratory: true)
        if AppSession.shared.prefs.settings.goalCenter ?? true {
            enqueueCelebration(event)
        }
    }

    // MARK: Celebration sequence

    private func startNextCelebration() {
        guard phase == .idle, !celebrationQueue.isEmpty else { return }
        let event = celebrationQueue.removeFirst()
        currentEvent = event
        countTotals = AppSession.shared.celebrationTotals[event.fixtureId] ?? [:]
        tapBursts = 0
        showDisplayPanel()
        phase = .ballDropping
        schedule(after: params.ballDropSeconds) { [self] in
            phase = .tapWindow
            if let team = event.teamCode {
                CelebrationService.shared.beginWindow(fixtureId: event.fixtureId, teamCode: team)
            }
            showInteractPanel()
            let hold = celebrationQueue.isEmpty ? params.tapWindowSeconds : params.tapWindowBusySeconds
            rescheduleTapWindow(after: hold)
        }
    }

    /// (Re)arms the end of the tap window; called again with a shorter delay
    /// when another celebration queues up behind the current one.
    private func rescheduleTapWindow(after seconds: Double) {
        tapWindowWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.endTapWindow() }
        tapWindowWork = work
        phaseWork.append(work)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func endTapWindow() {
        guard phase == .tapWindow, let event = currentEvent else { return }
        // Ball disappears: flush the batched taps, fade everything as one.
        CelebrationService.shared.endWindow()
        phase = .fadeOut
        fadeOutInteractPanel(duration: 0.7)
        let taps = tapBursts
        // The count is a detached round trip (POST lands in the DB, total
        // comes back from the CDN) — it drops into the notch stack whenever
        // it's ready and never blocks the next queued celebration.
        Task { @MainActor in
            let totals = (try? await Services.scores.fetchCelebrations(fixtureId: event.fixtureId)) ?? [:]
            let team = TeamCatalog.team(for: event.teamCode ?? "", in: AppSession.shared.teams)
            let count = totals[event.teamCode ?? ""] ?? 0
            if count > 0 {
                pushCountItem(text: "🎉 \(count.formattedCompact) celebrations for \(team.name) this match")
            } else if taps > 0 {
                pushCountItem(text: "🎉 You celebrated with \(team.name)!")
            }
        }
        schedule(after: 0.7) { [self] in finishCurrent() }
    }

    func registerTap() {
        CelebrationService.shared.registerTap()
        tapBursts += 1
    }

    private func finishCurrent() {
        phase = .idle
        currentEvent = nil
        hideInteractPanel()
        if celebrationQueue.isEmpty {
            hidePanelsIfDone(after: 0)
        } else {
            startNextCelebration() // ✕ or natural end → next plays immediately
        }
    }

    private func schedule(after seconds: Double, _ block: @escaping () -> Void) {
        let work = DispatchWorkItem(block: block)
        phaseWork.append(work)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func cancelScheduledPhases() {
        phaseWork.forEach { $0.cancel() }
        phaseWork.removeAll()
        tapWindowWork = nil
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
        panel.sharingType = .none // goal celebrations never photobomb screen shares
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

    /// The display panel stays up while EITHER lane has something to show.
    private func hidePanelsIfDone(after delay: Double) {
        schedule(after: delay) { [self] in
            guard phase == .idle, notchItems.isEmpty, celebrationQueue.isEmpty else { return }
            displayPanel?.orderOut(nil)
        }
    }

    /// Fades the tappable ball in lockstep with the display scene's fade so
    /// the whole celebration dissolves as one piece — no abrupt swap.
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
