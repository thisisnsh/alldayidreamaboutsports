import AppKit
import SwiftUI

/// One notification. `fanGoal` is set when this is a goal by a followed team —
/// that's what drives the goal confetti for the set it shows in.
struct NotchItem: Identifiable, Equatable {
    let id: String
    /// The match it's about — clicking the drop opens that match's card.
    let fixtureId: Int
    let icon: String
    let iconColor: Color
    let title: [PillSegment]
    var subtitle: [PillSegment]?
    var fanGoal: MatchEvent?

    static func == (lhs: NotchItem, rhs: NotchItem) -> Bool { lhs.id == rhs.id }
}

/// Fire-and-forget confetti token for one fan goal; bursts overlap freely
/// and outlive sets.
struct ConfettiBurst: Identifiable {
    let id = UUID()
    let fixtureId: Int
    let teamId: Int?
    /// The scoring team's crest, drawn among the paper confetti.
    let logo: String
}

private struct QueuedNotchItem {
    var item: NotchItem
    let arrivalSeq: Int
    let isGoal: Bool
}

/// TWO queues of events, displayed in SETS:
/// - Goals are kept in a priority queue; every other event waits separately.
///   Each set takes goals first, then fills remaining slots with other events.
/// - The visible stack is chronological within the selected set: oldest at the
///   top, newest at the bottom, and it stays up for the user's alert time. The
///   set is drawn by `NotchIsland`: drops emerge from the notch into fixed slots.
/// - Fan goals fire goal confetti (the scorer's crest + paper) from the
///   bottom corners when their goal pill drops. It's click-through and
///   fire-and-forget, gone within seconds.
@MainActor
final class OverlayManager: ObservableObject {
    static let shared = OverlayManager()

    @Published private(set) var activeSet: [NotchItem] = []
    /// Retain the slots until every drop has finished returning to the notch.
    @Published private(set) var isRetracting = false
    @Published private(set) var retractingItemIDs: Set<String> = []
    @Published private(set) var confettiBursts: [ConfettiBurst] = []

    private var goalQueue: [QueuedNotchItem] = []
    private var otherQueue: [QueuedNotchItem] = []
    private var nextArrivalSeq = 0
    private var lifecycleScheduled: [DispatchWorkItem] = []
    private var queueBusy = false  // set synchronously so rapid-fire pushes can't race startNextSetIfIdle
    private var pendingDropCount = 0
    private var displayPanel: NSPanel?
    /// Confetti waves after a goal's first burst, still to fire. Cancelled with
    /// the goal (VAR) or by a preview.
    private var pendingWaves: [PendingWave] = []

    private struct PendingWave {
        let id: UUID
        let fixtureId: Int
        let teamId: Int?
        let work: DispatchWorkItem
    }
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

    /// How long each notification set stays on screen.
    private var pillHoldSeconds: TimeInterval {
        (AppSession.shared.prefs.settings.alertDuration ?? .medium).alertHoldSeconds
    }
    /// Gap between a goal's confetti bursts: the next throw goes up as the
    /// last one starts to fall away. Sized so 1/2/3 waves last about 3/5/7
    /// seconds.
    private static let confettiWaveGap: TimeInterval = 1.7
    /// Notification set size — how many pills display at once.
    private let setSize = 5

    // MARK: Intake — two queues, goals prioritized for selection

    func submit(_ event: MatchEvent, isFanGoal: Bool) {
        enqueue(NotchItem(
            id: event.eventId,
            fixtureId: event.fixtureId,
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
    /// no longer fires confetti, and any of its confetti still in the air goes.
    func cancelGoal(fixtureId: Int, teamId: Int?) {
        for index in goalQueue.indices
        where goalQueue[index].item.fanGoal?.fixtureId == fixtureId && goalQueue[index].item.fanGoal?.teamId == teamId {
            goalQueue[index].item.fanGoal = nil
        }
        confettiBursts.removeAll { $0.fixtureId == fixtureId && $0.teamId == teamId }
        cancelWaves { $0.fixtureId == fixtureId && $0.teamId == teamId }
        hidePanelsIfDone()
    }

    /// Preview: drop everything pending and end the current set.
    func dismissAll() {
        goalQueue.removeAll()
        otherQueue.removeAll()
        confettiBursts.removeAll()
        cancelWaves { _ in true }
        endSet()
    }

    // MARK: Set lifecycle

    /// Close one notification without disturbing the other drops or their
    /// hold timer. Its slot stays reserved until the return has finished.
    func dismissNotification(_ id: String) {
        guard !isRetracting, activeSet.contains(where: { $0.id == id }),
              !retractingItemIDs.contains(id) else { return }
        retractingItemIDs.insert(id)
        let delay = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? 0.24 : NotchDropAnimation.retirementDelay(count: 1)
        scheduleLifecycle(after: delay) { [self] in
            withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : NotchIsland.spring) {
                activeSet.removeAll { $0.id == id }
            }
            retractingItemIDs.remove(id)
            if activeSet.isEmpty && pendingDropCount == 0 { finishSet() }
        }
    }

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
        NotchIsland.shared.setWillShow()
        isRetracting = false
        pendingDropCount = set.count

        // Pills publish top-to-bottom in chronological order: oldest first,
        // newest last, even though goals were prioritized for selection.
        for (index, item) in set.enumerated() {
            scheduleLifecycle(after: Double(index) * NotchDropAnimation.arrivalStagger) { [self] in
                pendingDropCount -= 1
                activeSet.append(item)
            }
        }

        let fanGoals = set.compactMap(\.fanGoal)
        // One per displayed set — the unit a user actually perceives, and the
        // only overlay event that fires per set rather than per event.
        AppAnalytics.overlaySetShown(count: set.count, hasFanGoal: !fanGoals.isEmpty)
        // Confetti comes in as the first fan-goal pill drops.
        if AppSession.shared.prefs.settings.goalCenter ?? true,
           let first = set.firstIndex(where: { $0.fanGoal != nil }) {
            let crests = fanGoals.map { crest(for: $0) }
            TeamLogoStore.shared.preload(crests)
            scheduleLifecycle(after: Double(first) * NotchDropAnimation.arrivalStagger) { [self] in
                fireConfetti(for: fanGoals)
            }
        }
        let arrivalTime = Double(max(0, set.count - 1)) * NotchDropAnimation.arrivalStagger
            + NotchDropAnimation.arrivalDuration
        scheduleLifecycle(after: arrivalTime + pillHoldSeconds) { [self] in endSet() }
    }

    /// Natural expiry: the whole set leaves, then the next set follows.
    func endSet() {
        guard !isRetracting, !activeSet.isEmpty || queueBusy else { return }
        cancelLifecycleScheduled()
        isRetracting = true
        let delay = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? 0.24 : NotchDropAnimation.retirementDelay(count: activeSet.count)
        scheduleLifecycle(after: delay) { [self] in
            // No layout change until the last returning silhouette is gone.
            finishSet()
        }
    }

    private func finishSet() {
        cancelLifecycleScheduled()
        activeSet = []
        retractingItemIDs = []
        pendingDropCount = 0
        isRetracting = false
        queueBusy = false
        startNextSetIfIdle()
        hidePanelsIfDone()
    }

    // MARK: Confetti — fire and forget, never waits for anything

    private func fireConfetti(for goals: [MatchEvent]) {
        guard !goals.isEmpty else { return }
        // A followed team scored and the animation actually fired. Skips the
        // Settings preview, whose synthetic event carries fixture 0 — that one
        // reports as `celebration_preview`.
        if goals.contains(where: { $0.fixtureId > 0 }) {
            AppAnalytics.celebrationShown()
        }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let waves = (AppSession.shared.prefs.settings.confettiDuration ?? .medium).confettiWaves
        for goal in goals {
            addBurst(for: goal)
            for wave in 1..<max(1, waves) {
                scheduleWave(for: goal, after: Double(wave) * Self.confettiWaveGap)
            }
        }
        showDisplayPanel()
    }

    private func addBurst(for goal: MatchEvent) {
        let burst = ConfettiBurst(fixtureId: goal.fixtureId, teamId: goal.teamId, logo: crest(for: goal))
        confettiBursts.append(burst)
        scheduleAmbient(after: ConfettiView.lifetime + 1.2) { [self] in
            confettiBursts.removeAll { $0.id == burst.id }
            hidePanelsIfDone()
        }
    }

    private func scheduleWave(for goal: MatchEvent, after seconds: Double) {
        let id = UUID()
        let work = DispatchWorkItem { [self] in
            pendingWaves.removeAll { $0.id == id }
            addBurst(for: goal)
            showDisplayPanel()
        }
        pendingWaves.append(PendingWave(id: id, fixtureId: goal.fixtureId, teamId: goal.teamId, work: work))
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func cancelWaves(where matches: (PendingWave) -> Bool) {
        for wave in pendingWaves where matches(wave) { wave.work.cancel() }
        pendingWaves.removeAll(where: matches)
    }

    private func crest(for goal: MatchEvent) -> String {
        guard let teamId = goal.teamId else { return "" }
        return TeamCatalog.team(for: teamId, in: AppSession.shared.allTeams).logo
    }

    // MARK: Preview

    /// Settings "Preview goal confetti": a generic fan goal (Team A vs Team B)
    /// through the exact same pipeline — pill set + confetti, per the
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
    /// goal — the goal confetti has its own Preview.
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

    private static func makePanel(frame: NSRect) -> NSPanel {
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // `.screenSaver` (not `.statusBar`) so the pills/confetti float ABOVE
        // full-screen apps too; the collection behavior lets this accessory app
        // draw over another app's full-screen space. Shared with the pinned
        // capsules via `OverlayWindow` so every overlay floats above everything.
        panel.level = OverlayWindow.level
        panel.collectionBehavior = OverlayWindow.collectionBehavior
        panel.ignoresMouseEvents = true
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
    /// setting can change while a pill is showing.
    func applyOverlayTheme() {
        displayPanel?.appearance = overlayAppearance
    }

    private func showDisplayPanel() {
        guard let screen else { return }
        if displayPanel == nil {
            let panel = Self.makePanel(frame: screen.frame)
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
            return
        }
        if let displayPanel, displayPanel.isVisible {
            displayPanel.setFrame(screen.frame, display: true)
        }
    }

    /// The display panel only hosts confetti now (drops live in the notch
    /// island's own panel), so it goes as soon as the last burst has fallen.
    private func hidePanelsIfDone() {
        guard confettiBursts.isEmpty else { return }
        displayPanel?.orderOut(nil)
    }
}
