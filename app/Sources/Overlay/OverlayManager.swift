import AppKit
import SwiftUI

enum OverlayItem {
    case celebration(MatchEvent)
    /// celebratory = a fan-team goal shown as a pill (goal-in-center off):
    /// confetti still fires alongside it if enabled.
    case pill(MatchEvent, celebratory: Bool)
}

enum OverlayPhase: Equatable {
    case idle
    case ballDropping
    case tapWindow
    case fadeOut // ball + score + minis all fade together…
    case count // …and only then the celebration total drops from the notch
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
    @Published var pillCelebratory = false // current pill is a fan goal → confetti

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
            // Only celebrations are capped — pills always queue, so no event
            // is ever missed; they play one after another.
            let queuedCelebrations = queue.filter {
                if case .celebration = $0 { return true } else { return false }
            }
            guard queuedCelebrations.count < params.maxQueuedAnimations else { return }
        }
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
        // Deliberately generic — Team A vs Team B with placeholder flags —
        // so it reads as an example, never as a real match.
        let data: [String: Any] = [
            "eventId": "preview:\(Date().timeIntervalSince1970)", "type": "GOAL",
            "fixtureId": "0", "leagueId": "1",
            "homeTeam": TeamCatalog.previewHome.code, "awayTeam": TeamCatalog.previewAway.code,
            "homeName": TeamCatalog.previewHome.name, "awayName": TeamCatalog.previewAway.name,
            "homeGoals": "1", "awayGoals": "0",
            "teamCode": TeamCatalog.previewHome.code, "player": "Player Name", "minute": "73",
        ]
        guard let event = MatchEvent(fcmData: data) else { return }
        let goalCenter = AppSession.shared.prefs.settings.goalCenter ?? true
        // A direct user action: jump the queue instead of lining up behind
        // whatever is already playing or waiting.
        dismissAll()
        enqueue(goalCenter ? .celebration(event) : .pill(event, celebratory: true))
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
                    // Ball disappears: flush the batched taps, fade the whole
                    // scene (panel included) in one smooth move…
                    CelebrationService.shared.endWindow()
                    phase = .fadeOut
                    fadeOutInteractPanel(duration: 0.7)
                    schedule(after: 0.7) { [self] in
                        hideInteractPanel()
                        // …then fetch the totals. This is a real round trip:
                        // the batched POST has to land in the DB before the
                        // total means anything, so the count arrives a beat
                        // after the ball is gone — never instantly.
                        Task { @MainActor in
                            if let totals = try? await Services.scores.fetchCelebrations(fixtureId: event.fixtureId) {
                                self.countTotals = totals
                            }
                            // The user may have dismissed it while we fetched.
                            guard currentEvent?.eventId == event.eventId, phase == .fadeOut else { return }
                            let count = countTotals[event.teamCode ?? ""] ?? 0
                            if count > 0 || tapBursts > 0 {
                                phase = .count
                                schedule(after: params.countHoldSeconds) { [self] in finishCurrent() }
                            } else {
                                finishCurrent()
                            }
                        }
                    }
                }
            }
        case .pill(let event, let celebratory):
            currentEvent = event
            pillCelebratory = celebratory
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
