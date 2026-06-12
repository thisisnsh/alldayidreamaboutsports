import AppKit
import SwiftUI

enum OverlayItem {
    case celebration(MatchEvent)
    case pill(MatchEvent)
}

enum OverlayPhase: Equatable {
    case idle
    case ballDropping
    case tapWindow
    case count
    case fadeOut // ball + score + minis all fade together at the end
    case pill
}

/// Serializes overlay animations and owns the two panels:
/// - display panel: full screen, click-through, never steals input
/// - interact panel: small, centered, exists only during the tap window so the
///   ball and the ✕ are clickable while the rest of the screen stays usable
@MainActor
final class OverlayManager: ObservableObject {
    static let shared = OverlayManager()

    @Published var phase: OverlayPhase = .idle
    @Published var currentEvent: MatchEvent?
    @Published var countTotals: [String: Int] = [:]
    @Published var tapBursts: Int = 0 // increments per user tap → spawns mini balls

    private var queue: [OverlayItem] = []
    private var displayPanel: NSPanel?
    private var interactPanel: NSPanel?
    private var phaseWork: [DispatchWorkItem] = []

    private var params: AnimationParams { ControlPlane.shared.animationParams }

    // MARK: Queue

    func enqueue(_ item: OverlayItem) {
        if case .celebration(let ev) = item {
            // Collapse: a newer goal in the same fixture replaces a queued one.
            queue.removeAll {
                if case .celebration(let queued) = $0 { return queued.fixtureId == ev.fixtureId }
                return false
            }
        }
        guard queue.count < params.maxQueuedAnimations else { return }
        queue.append(item)
        if phase == .idle { runNext() }
    }

    func dismissCurrent() {
        CelebrationService.shared.endWindow()
        cancelScheduledPhases()
        finishCurrent()
    }

    func dismissAll() {
        queue.removeAll()
        dismissCurrent()
    }

    func updateCelebrationCount(fixtureId: Int, totals: [String: Int]) {
        guard currentEvent?.fixtureId == fixtureId else { return }
        countTotals = totals
    }

    /// Settings "Preview animation" — plays exactly the combination the user
    /// configured: goal in center on → full celebration (+confetti if on);
    /// off → the notch pill goals will use (+confetti if on). Always fires —
    /// no dedup or event-toggle gates in the way.
    func preview() {
        var data: [String: Any] = [
            "eventId": "preview:\(Date().timeIntervalSince1970)", "type": "GOAL",
            "fixtureId": "0", "leagueId": "1",
            "homeTeam": "BRA", "awayTeam": "USA",
            "homeName": "Brazil", "awayName": "United States",
            "homeGoals": "1", "awayGoals": "0",
            "teamCode": "BRA", "player": "Vinícius Jr", "minute": "73",
        ]
        if let fan = AppSession.shared.fanTeams.first {
            data["teamCode"] = fan.code
            data["homeTeam"] = fan.code
            data["homeName"] = fan.name
        }
        guard let event = MatchEvent(fcmData: data) else { return }
        let goalCenter = AppSession.shared.prefs.settings.goalCenter ?? true
        enqueue(goalCenter ? .celebration(event) : .pill(event))
    }

    // MARK: Sequence

    private func runNext() {
        guard let item = queue.first else { return }
        queue.removeFirst()
        switch item {
        case .celebration(let event):
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
                schedule(after: params.tapWindowSeconds) { [self] in
                    Task { @MainActor in
                        if let totals = try? await Services.scores.fetchCelebrations(fixtureId: event.fixtureId) {
                            self.countTotals = totals
                        }
                    }
                    // The ball stays tappable through the count phase — taps
                    // only stop when the ball itself disappears (fade-out).
                    phase = .count
                    schedule(after: params.countHoldSeconds) { [self] in
                        CelebrationService.shared.endWindow()
                        hideInteractPanel()
                        phase = .fadeOut
                        schedule(after: 0.7) { [self] in finishCurrent() }
                    }
                }
            }
        case .pill(let event):
            currentEvent = event
            showDisplayPanel()
            phase = .pill
            schedule(after: params.pillHoldSeconds + 1.0) { [self] in finishCurrent() }
        }
    }

    func registerTap() {
        CelebrationService.shared.registerTap()
        tapBursts += 1
    }

    private func finishCurrent() {
        phase = .idle
        currentEvent = nil
        hideInteractPanel()
        if queue.isEmpty {
            hideDisplayPanel()
        } else {
            runNext()
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

    private func hideDisplayPanel() {
        displayPanel?.orderOut(nil)
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
    }
}
