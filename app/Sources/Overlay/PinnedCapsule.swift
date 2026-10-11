import AppKit
import SwiftUI

// MARK: - Shared overlay-window configuration

/// The window level + collection behavior shared by EVERY floating overlay —
/// the notch notification stack, goal confetti, and pinned score
/// capsules. `.screenSaver` sits above full-screen window content, and
/// `.canJoinAllSpaces` + `.fullScreenAuxiliary` let this accessory
/// (`LSUIElement`) app draw over another app's full-screen space. Kept in one
/// place so all overlays float above everything, including full screen.
enum OverlayWindow {
    static let level = NSWindow.Level.screenSaver
    static let collectionBehavior: NSWindow.CollectionBehavior =
        [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
}

/// Geometry shared by the passive notch notifications and pinned
/// capsules. Callers pass the display they actually occupy; using
/// `NSScreen.main` for pinned content makes windows jump when focus changes.
enum OverlayLayout {
    static let fallbackMenuBarHeight: CGFloat = 26
    static let topGap: CGFloat = 6
    static let shadowInset: CGFloat = 6
    static let expandedShadowInset: CGFloat = 16
    static let stackSpacing: CGFloat = 8

    static func topInset(on screen: NSScreen?) -> CGFloat {
        let inset = screen?.safeAreaInsets.top ?? 0
        return inset > 0 ? inset : fallbackMenuBarHeight
    }

    static func topMargin(on screen: NSScreen?) -> CGFloat {
        topInset(on: screen) + topGap
    }
}

/// Capsules share the notch pill's exact chrome (NotchPillView): this corner
/// radius, a solid black/white fill, and a soft drop shadow.
let capsuleCorner: CGFloat = 18

// MARK: - Size metrics

/// Every dimension in the capsule, scaled by the user's `CapsuleSize` setting.
/// Medium is the baseline; small/large step it down/up proportionally. The
/// corner radius is NOT here — it's `capsuleCorner`, fixed to match the pills.
struct CapsuleMetrics {
    let nameFont: CGFloat
    let scoreFont: CGFloat
    let headerLogo: CGFloat
    let timeFont: CGFloat
    let eventFont: CGFloat
    let eventIcon: CGFloat
    let eventLogo: CGFloat
    let hPad: CGFloat
    let vPad: CGFloat
    let rowSpacing: CGFloat

    init(_ size: CapsuleSize) {
        switch size {
        case .small:
            nameFont = 11; scoreFont = 12; headerLogo = 16; timeFont = 10
            eventFont = 10; eventIcon = 11; eventLogo = 14
            hPad = 12; vPad = 8; rowSpacing = 4
        case .medium:
            nameFont = 13; scoreFont = 15; headerLogo = 20; timeFont = 12
            eventFont = 12; eventIcon = 13; eventLogo = 16
            hPad = 16; vPad = 11; rowSpacing = 6
        case .large:
            nameFont = 16; scoreFont = 19; headerLogo = 26; timeFont = 14
            eventFont = 15; eventIcon = 16; eventLogo = 20
            hPad = 20; vPad = 14; rowSpacing = 8
        }
    }
}

// MARK: - Manager

/// A screen corner a pinned capsule snaps to. Capsules in the same corner
/// stack away from it, so two never overlap.
enum CapsuleCorner: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight

    var isTop: Bool { self == .topLeft || self == .topRight }
    var isLeft: Bool { self == .topLeft || self == .bottomLeft }

    /// The corner whose quadrant of `area` holds `point`.
    static func nearest(to point: CGPoint, in area: CGRect) -> CapsuleCorner {
        switch (point.y >= area.midY, point.x < area.midX) {
        case (true, true): .topLeft
        case (true, false): .topRight
        case (false, true): .bottomLeft
        case (false, false): .bottomRight
        }
    }
}

/// Owns one small panel per pinned match, all on the display selected in
/// Settings. A new pin opens top-right; the user can drag it anywhere and on
/// release it snaps to the nearest corner, stacking with whatever is there.
/// A click expands or collapses it and a right-click offers Unpin. All
/// panels float above every app, including full screen (`OverlayWindow`).
@MainActor
final class PinnedCapsuleManager: ObservableObject {
    static let shared = PinnedCapsuleManager()

    /// Which matches are pinned — the menu observes this to swap a fixture row
    /// into its "shown in capsule" state.
    @Published private(set) var pinnedFixtureIds: Set<Int> = []
    /// Capsules showing full names and the timeline.
    @Published private(set) var expandedFixtureIds: Set<Int> = []

    /// Each corner's capsules, nearest the corner first.
    private var stacks: [CapsuleCorner: [Int]] = [:]
    private var panels: [Int: NSPanel] = [:]
    /// Each capsule's SwiftUI size (shadow margin included), as last measured.
    private var sizes: [Int: CGSize] = [:]
    /// The capsule being dragged — out of every stack until it's dropped.
    private var dragging: Int?
    private var displayObserver: NSObjectProtocol?

    /// Gap between a capsule and the screen edge, and between stacked capsules.
    static let edgeGap: CGFloat = 12
    /// Transparent margin around each capsule so its shadow isn't clipped.
    static let shadowMargin: CGFloat = 8

    private init() {
        displayObserver = NotificationCenter.default.addObserver(
            forName: .overlayDisplayTargetDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.moveCapsulesToSelectedDisplay() }
        }
    }

    func isPinned(_ fixtureId: Int) -> Bool { pinnedFixtureIds.contains(fixtureId) }
    func isExpanded(_ fixtureId: Int) -> Bool { expandedFixtureIds.contains(fixtureId) }

    /// A click only toggles when there's a timeline to show — or to hide.
    func canToggleExpanded(_ fixtureId: Int) -> Bool {
        if isExpanded(fixtureId) { return true }
        guard let fixture = AppSession.shared.fixtures.first(where: { $0.fixtureId == fixtureId }) else { return false }
        return !capsuleTimeline(for: fixture).isEmpty
    }

    /// The one place both the menu row's pin affordance and any other caller
    /// funnel through, so the analytics live here rather than at each call site.
    func toggle(fixtureId: Int) {
        let pinning = !isPinned(fixtureId)
        if pinning {
            AppAnalytics.capsulePinned(fixtureId: fixtureId)
        } else {
            AppAnalytics.capsuleUnpinned(fixtureId: fixtureId)
        }
        if pinning { pin(fixtureId: fixtureId) } else { unpin(fixtureId: fixtureId) }
    }

    func pin(fixtureId: Int) {
        guard !isPinned(fixtureId), let screen = OverlayDisplayTarget.shared.selectedScreen else { return }
        pinnedFixtureIds.insert(fixtureId)
        stacks[.topRight, default: []].append(fixtureId)
        let panel = makePanel(for: fixtureId)
        panels[fixtureId] = panel
        sizes[fixtureId] = panel.contentView?.fittingSize
        layout(on: screen, animated: false)
        panel.orderFrontRegardless()
        AppLog.info(.app, "capsule_pinned fixture_id=\(fixtureId)")
    }

    func unpin(fixtureId: Int) {
        guard isPinned(fixtureId) else { return }
        pinnedFixtureIds.remove(fixtureId)
        expandedFixtureIds.remove(fixtureId)
        for corner in CapsuleCorner.allCases { stacks[corner]?.removeAll { $0 == fixtureId } }
        panels[fixtureId]?.orderOut(nil)
        panels[fixtureId] = nil
        sizes[fixtureId] = nil
        if dragging == fixtureId { dragging = nil }
        relayout(animated: true)
        AppLog.info(.app, "capsule_unpinned fixture_id=\(fixtureId)")
    }

    func toggleExpanded(_ fixtureId: Int) {
        guard canToggleExpanded(fixtureId) else { return }
        if expandedFixtureIds.contains(fixtureId) {
            expandedFixtureIds.remove(fixtureId)
        } else {
            expandedFixtureIds.insert(fixtureId)
        }
    }

    // MARK: Layout

    /// The SwiftUI content reports its size; the panel follows, anchored to
    /// its corner so it grows away from the screen edge.
    func contentSizeChanged(_ fixtureId: Int, to size: CGSize) {
        guard isPinned(fixtureId), sizes[fixtureId] != size else { return }
        sizes[fixtureId] = size
        if dragging == fixtureId, let panel = panels[fixtureId] {
            panel.setFrame(CGRect(origin: panel.frame.origin, size: size), display: true)
            return
        }
        relayout(animated: true)
    }

    private func relayout(animated: Bool) {
        guard let screen = OverlayDisplayTarget.shared.selectedScreen else { return }
        layout(on: screen, animated: animated)
    }

    /// Place every stacked capsule. A capsule only animates when it moves
    /// without changing size: animating a resize would show the new content
    /// centered in a frame that's still catching up.
    private func layout(on screen: NSScreen, animated: Bool) {
        let area = screen.visibleFrame
        let margin = Self.shadowMargin
        for corner in CapsuleCorner.allCases {
            var offset: CGFloat = 0
            for fixtureId in stacks[corner] ?? [] {
                guard let panel = panels[fixtureId] else { continue }
                let size = sizes[fixtureId] ?? panel.frame.size
                let x = corner.isLeft
                    ? area.minX + Self.edgeGap - margin
                    : area.maxX - Self.edgeGap + margin - size.width
                let y = corner.isTop
                    ? area.maxY - Self.edgeGap + margin - offset - size.height
                    : area.minY + Self.edgeGap - margin + offset
                let frame = CGRect(x: x, y: y, width: size.width, height: size.height).integral
                offset += size.height - 2 * margin + Self.edgeGap
                if frame == panel.frame { continue }
                if animated, frame.size == panel.frame.size, panel.isVisible {
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.22
                        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                        panel.animator().setFrame(frame, display: true)
                    }
                } else {
                    panel.setFrame(frame, display: true)
                }
            }
        }
    }

    // MARK: Dragging

    /// The capsule leaves its stack while it's carried, so the rest close up.
    func beginDrag(_ fixtureId: Int) {
        dragging = fixtureId
        for corner in CapsuleCorner.allCases { stacks[corner]?.removeAll { $0 == fixtureId } }
        relayout(animated: true)
    }

    /// Snap to the corner whose quadrant the capsule was dropped in, slotted
    /// among that corner's capsules by where it landed.
    func endDrag(_ fixtureId: Int) {
        guard dragging == fixtureId else { return }
        dragging = nil
        guard let panel = panels[fixtureId],
              let screen = OverlayDisplayTarget.shared.selectedScreen else { return }
        let center = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        let corner = CapsuleCorner.nearest(to: center, in: screen.visibleFrame)
        var stack = stacks[corner] ?? []
        let index = stack.filter { other in
            guard let otherFrame = panels[other]?.frame else { return false }
            return corner.isTop ? otherFrame.midY > center.y : otherFrame.midY < center.y
        }.count
        stack.insert(fixtureId, at: min(index, stack.count))
        stacks[corner] = stack
        AppLog.info(.app, "capsule_moved fixture_id=\(fixtureId) corner=\(corner)")
        // Animate the snap: the dragged panel keeps its size, only its origin moves.
        layout(on: screen, animated: true)
    }

    // MARK: Theme

    /// Re-apply the user's theme to every open capsule (Appearance can change
    /// while capsules are up). Mirrors `OverlayManager.applyOverlayTheme`.
    func applyTheme() {
        let appearance = overlayAppearance
        for panel in panels.values { panel.appearance = appearance }
    }

    // MARK: Panels

    /// Move every capsule when the user changes the screen setting or macOS
    /// removes the selected display. Corners and order carry over.
    private func moveCapsulesToSelectedDisplay() {
        guard let screen = OverlayDisplayTarget.shared.selectedScreen else {
            for panel in panels.values { panel.orderOut(nil) }
            return
        }
        layout(on: screen, animated: false)
        for panel in panels.values { panel.orderFrontRegardless() }
    }

    private var overlayAppearance: NSAppearance? {
        switch AppSession.shared.prefs.settings.theme ?? .system {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    private func makePanel(for fixtureId: Int) -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 60),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // No AppKit shadow: it hugs the rectangular FRAME, not the rounded
        // capsule, and reads as a visible window boundary. The SwiftUI shadow
        // (inside `shadowMargin`) is the only shadow.
        panel.hasShadow = false
        panel.level = OverlayWindow.level
        panel.collectionBehavior = OverlayWindow.collectionBehavior
        panel.sharingType = .readOnly
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        // Dragging is ours (`CapsuleInteractionView`): AppKit's own window
        // drag can't tell a click from a drag or snap on release.
        panel.isMovableByWindowBackground = false
        panel.appearance = overlayAppearance

        let hostingView = NSHostingView(rootView: PinnedCapsuleView(fixtureId: fixtureId)
            .padding(Self.shadowMargin)
            .fixedSize()
            .onGeometryChange(for: CGSize.self, of: \.size) { size in
                DispatchQueue.main.async {
                    PinnedCapsuleManager.shared.contentSizeChanged(fixtureId, to: size)
                }
            }
            .environmentObject(AppSession.shared)
            .environmentObject(self))
        // The panel's frame is ours; never let the hosting view drive window
        // constraints (a re-measuring root loops AppKit's constraint passes).
        hostingView.sizingOptions = []
        panel.contentView = CapsuleInteractionView(fixtureId: fixtureId, content: hostingView)
        return panel
    }
}

/// The capsule panel's content view: takes every mouse event itself (the
/// capsule has no controls of its own) to tell a click from a drag.
private final class CapsuleInteractionView: NSView {
    let fixtureId: Int
    private var dragStartMouse: CGPoint = .zero
    private var dragStartOrigin: CGPoint = .zero
    private var isDragging = false

    init(fixtureId: Int, content: NSView) {
        self.fixtureId = fixtureId
        super.init(frame: content.frame)
        content.autoresizingMask = [.width, .height]
        addSubview(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var fittingSize: NSSize { subviews.first?.fittingSize ?? super.fittingSize }

    /// Only the capsule itself is solid; the shadow margin lets clicks fall
    /// through to whatever is behind.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let margin = PinnedCapsuleManager.shadowMargin
        return bounds.insetBy(dx: margin, dy: margin).contains(local) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        dragStartMouse = NSEvent.mouseLocation
        dragStartOrigin = window?.frame.origin ?? .zero
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - dragStartMouse.x, dy = mouse.y - dragStartMouse.y
        if !isDragging {
            // A few points of wobble is still a click.
            guard hypot(dx, dy) > 3 else { return }
            isDragging = true
            PinnedCapsuleManager.shared.beginDrag(fixtureId)
        }
        window?.setFrameOrigin(CGPoint(x: dragStartOrigin.x + dx, y: dragStartOrigin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        if isDragging {
            isDragging = false
            PinnedCapsuleManager.shared.endDrag(fixtureId)
        } else {
            PinnedCapsuleManager.shared.toggleExpanded(fixtureId)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let manager = PinnedCapsuleManager.shared
        let menu = NSMenu()
        if manager.canToggleExpanded(fixtureId) {
            let expand = NSMenuItem(
                title: manager.isExpanded(fixtureId) ? "Collapse" : "Show timeline",
                action: #selector(toggleExpanded), keyEquivalent: ""
            )
            expand.target = self
            menu.addItem(expand)
        }
        let unpin = NSMenuItem(title: "Unpin", action: #selector(unpin), keyEquivalent: "")
        unpin.target = self
        menu.addItem(unpin)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func toggleExpanded() { PinnedCapsuleManager.shared.toggleExpanded(fixtureId) }
    @objc private func unpin() { PinnedCapsuleManager.shared.toggle(fixtureId: fixtureId) }
}

// MARK: - Timeline

/// One flattened row of a match's timeline (goal / card / sub / VAR / penalty
/// kick), built straight from the `Fixture` scoreboard so the capsule needs no
/// event stream.
struct CapsuleTimelineRow: Identifiable {
    let id: String
    let minute: Int?
    let extra: Int?
    let icon: String
    let color: Color
    /// What happened: "Goal", "Own goal", "Sub", "VAR", …
    let label: String
    /// Who/what it happened to — player name(s) or VAR detail. Optional.
    let text: String?
    let teamId: Int?
    /// A goal the aggregate no longer counts (disallowed by VAR/offside): the
    /// authoritative `goals` count dropped but the scorer-attributed event still
    /// lingers in `goalEvents`. Rendered struck-through. Always false for
    /// non-goal rows.
    var disallowed: Bool = false

    /// Sort key: match minute (+ stoppage) ascending; shootout kicks (no minute)
    /// sort after everything in taken order.
    var sortKey: Int { minute.map { $0 * 100 + (extra ?? 0) } ?? 1_000_000 }

    var minuteText: String {
        guard let minute else { return "" }
        return extra.map { "\(minute)+\($0)′" } ?? "\(minute)′"
    }
}

@MainActor
func capsuleTimeline(for fixture: Fixture) -> [CapsuleTimelineRow] {
    var rows: [CapsuleTimelineRow] = []

    // `validCount` bounds how many of these events the aggregate still counts.
    // For goals, the authoritative `team.goals` can drop below `goalEvents.count`
    // on a VAR disallow while the reversed goal lingers in the event list — those
    // trailing (most-recent) entries are marked disallowed so they render struck.
    func add(_ events: [MatchTimelineEvent], type: MatchEventType, team: ScoreboardTeam, prefix: String, validCount: Int = .max) {
        for (index, event) in events.enumerated() {
            let label: String = switch (type, event.kind) {
            case (.goal, "own"): "Own goal"
            case (.goal, "penalty"): "Penalty goal"
            default: eventLabel(for: type)
            }
            rows.append(CapsuleTimelineRow(
                id: "\(fixture.fixtureId):\(prefix):\(team.id):\(index)",
                minute: event.minute,
                extra: event.extra,
                icon: pillIcon(for: type),
                color: pillIconColor(for: type),
                label: label,
                text: event.player,
                teamId: team.id,
                disallowed: index >= validCount
            ))
        }
    }

    for team in [fixture.home, fixture.away] {
        add(team.goalEvents, type: .goal, team: team, prefix: "g", validCount: team.goals)
        add(team.yellowCardEvents, type: .yellowCard, team: team, prefix: "y")
        add(team.redCardEvents, type: .redCard, team: team, prefix: "r")

        for (index, sub) in team.subs.enumerated() {
            let names = [sub.playerIn, sub.playerOut.map { "for \($0)" }]
                .compactMap { $0 }.joined(separator: " ")
            rows.append(CapsuleTimelineRow(
                id: "\(fixture.fixtureId):s:\(team.id):\(index)",
                minute: sub.minute,
                extra: sub.extra,
                icon: pillIcon(for: .substitution),
                color: pillIconColor(for: .substitution),
                label: eventLabel(for: .substitution),
                text: names.isEmpty ? nil : names,
                teamId: team.id
            ))
        }
    }

    for (index, record) in fixture.varEvents.enumerated() {
        rows.append(CapsuleTimelineRow(
            id: "\(fixture.fixtureId):v:\(index)",
            minute: record.minute,
            extra: record.extra,
            icon: pillIcon(for: .varDecision),
            color: pillIconColor(for: .varDecision),
            label: eventLabel(for: .varDecision),
            text: record.player.map { "\(record.detail) — \($0)" } ?? record.detail,
            teamId: record.teamId
        ))
    }

    for (index, kick) in (fixture.shootout?.kicks ?? []).enumerated() {
        let scored = kick.scored
        rows.append(CapsuleTimelineRow(
            id: "\(fixture.fixtureId):pk:\(index)",
            minute: nil,
            extra: nil,
            icon: scored ? "checkmark.circle.fill" : "xmark.circle.fill",
            color: scored ? .green : .red,
            label: "Penalty",
            text: kick.player ?? (scored ? "Scored" : "Missed"),
            teamId: kick.teamId
        ))
    }

    return rows.sorted { $0.sortKey < $1.sortKey }
}

private func eventLabel(for type: MatchEventType) -> String {
    switch type {
    case .goal: "Goal"
    case .yellowCard: "Yellow card"
    case .redCard: "Red card"
    case .substitution: "Sub"
    case .varDecision: "VAR"
    default: ""
    }
}

// MARK: - View

/// The capsule content. Collapsed it's the tightest possible scoreline —
/// `logo MCI score MUN logo time`, each side its short code — in the notch
/// pill's chrome. Clicking expands it: full club names, the competition, and
/// the event timeline. Reads live from `AppSession` as `LiveStore` polls.
struct PinnedCapsuleView: View {
    let fixtureId: Int
    @EnvironmentObject var session: AppSession
    @EnvironmentObject var manager: PinnedCapsuleManager
    @Environment(\.colorScheme) private var scheme

    private var metrics: CapsuleMetrics { CapsuleMetrics(session.prefs.settings.capsuleSize ?? .medium) }
    private var fixture: Fixture? { session.fixtures.first { $0.fixtureId == fixtureId } }
    private var expanded: Bool { manager.isExpanded(fixtureId) }

    var body: some View {
        Group {
            if let fixture {
                capsuleBody(fixture)
            } else {
                // Fixture rolled out of today's list / cache cleared — retire it.
                Color.clear.frame(width: 1, height: 1).onAppear {
                    manager.unpin(fixtureId: fixtureId)
                }
            }
        }
        .fixedSize()
        .respectReducedMotion()
    }

    private func timelineList(_ rows: [CapsuleTimelineRow]) -> some View {
        // Reserve ONE minute-column width for the whole list, sized to the
        // widest minute (e.g. `45+7′`), so every logo/icon/label lines up in a
        // column instead of a stoppage-time row shoving itself rightward.
        let minuteColumn = rows.map(\.minuteText).max { $0.count < $1.count } ?? ""
        return VStack(alignment: .leading, spacing: metrics.rowSpacing) {
            ForEach(rows) { row in
                eventRow(row, minuteColumn: minuteColumn)
            }
        }
    }

    /// The visible capsule chrome + content. No SwiftUI animation on expand:
    /// the panel snaps to the new size, and an animated body would be clipped
    /// mid-way.
    private func capsuleBody(_ fixture: Fixture) -> some View {
        let rows = capsuleTimeline(for: fixture)
        return VStack(alignment: .leading, spacing: metrics.rowSpacing) {
            header(fixture, hasTimeline: !rows.isEmpty)
            if expanded {
                subtitle(fixture)
                if !rows.isEmpty {
                    Divider().padding(.vertical, metrics.rowSpacing / 2)
                    timelineList(rows)
                }
            }
        }
        .padding(.horizontal, metrics.hPad)
        .padding(.vertical, metrics.vPad)
        .background(
            RoundedRectangle(cornerRadius: capsuleCorner, style: .continuous)
                .fill(scheme == .dark ? Color.black : Color.white)
                .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
        )
        // A hairline edge so the capsule holds its shape on a wallpaper of
        // the same color.
        .overlay(
            RoundedRectangle(cornerRadius: capsuleCorner, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: capsuleCorner, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityHint(rows.isEmpty ? "Drag to move." : expanded ? "Click to collapse. Drag to move." : "Click for the timeline. Drag to move.")
    }

    /// One side of the scoreline: the short code collapsed, the club's full
    /// name expanded.
    private func teamLabel(_ team: ScoreboardTeam) -> some View {
        Text(expanded ? team.name : TeamCatalog.shortName(for: team.id, in: session.allTeams, fallback: team.name))
            .font(.system(size: metrics.nameFont, weight: .medium, design: .rounded))
            .lineLimit(1)
    }

    /// The scoreline row: `logo name score name logo time`, plus a chevron
    /// when there's a timeline to expand into.
    private func header(_ fixture: Fixture, hasTimeline: Bool) -> some View {
        HStack(spacing: 6) {
            // The scoreline itself hugs its content on ONE line (the inner
            // `.fixedSize`). Keeping it as its own group lets it sit flush-left
            // while the clock is pushed to the trailing edge by the Spacer — so
            // when the capsule expands to the timeline's width the clock stays
            // pinned right instead of drifting in beside the score.
            HStack(spacing: 6) {
                CachedTeamLogo(url: logo(fixture.home.id), size: metrics.headerLogo)
                teamLabel(fixture.home)
                Text(scoreText(fixture))
                    .font(.system(size: metrics.scoreFont, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.spring, value: fixture.scorelineText)
                    .fixedSize().layoutPriority(1)
                teamLabel(fixture.away)
                CachedTeamLogo(url: logo(fixture.away.id), size: metrics.headerLogo)
            }
            .fixedSize()
            if expanded {
                Spacer(minLength: 8)
            }
            trailing(fixture)
                .padding(.leading, 2)
            if hasTimeline {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: metrics.timeFont - 2, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Competition and stage, under the scoreline when expanded.
    @ViewBuilder private func subtitle(_ fixture: Fixture) -> some View {
        if let text = [session.leagueName(for: fixture.leagueId), fixture.stageLabel]
            .compactMap({ $0 }).joined(separator: " · ").trimmedNonEmpty {
            Text(text)
                .font(.system(size: metrics.eventFont, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder private func trailing(_ fixture: Fixture) -> some View {
        if fixture.isLive {
            LiveMatchStatus(fixture: fixture, fontSize: metrics.timeFont)
        } else if fixture.status == "FINISHED" {
            Text("FT")
                .font(.system(size: metrics.timeFont, weight: .semibold, design: .rounded))
                .foregroundStyle(.green)
        } else if let kickoff = fixture.kickoff {
            Text(kickoff, style: .time)
                .font(.system(size: metrics.timeFont, design: .rounded)).opacity(0.7)
        }
    }

    /// One past event: `minute · team logo · icon · label · player?`, a step
    /// smaller than the header so the scoreline stays the loudest line.
    private func eventRow(_ row: CapsuleTimelineRow, minuteColumn: String) -> some View {
        HStack(spacing: 6) {
            // An invisible twin of the widest minute fixes the column width;
            // the real minute is trailing-aligned inside it.
            Text(minuteColumn)
                .font(.system(size: metrics.eventFont, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(minWidth: metrics.eventFont * 2.6, alignment: .trailing)
                .fixedSize()
                .hidden()
                .overlay(alignment: .trailing) {
                    Text(row.minuteText)
                        .font(.system(size: metrics.eventFont, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            if let teamId = row.teamId {
                CachedTeamLogo(url: logo(teamId), size: metrics.eventLogo)
            } else {
                // Keep the icon column aligned for team-less rows.
                Color.clear.frame(width: metrics.eventLogo, height: metrics.eventLogo)
            }
            Image(systemName: row.icon)
                .font(.system(size: metrics.eventIcon, weight: .semibold))
                // Dim a disallowed goal's icon so it reads as "not counted".
                .foregroundStyle(row.disallowed ? Color.secondary : row.color)
                .frame(width: metrics.eventIcon + 6)
            Text(row.label)
                .font(.system(size: metrics.eventFont, weight: .semibold, design: .rounded))
                .strikethrough(row.disallowed)
                .foregroundStyle(row.disallowed ? Color.secondary : .primary)
                .fixedSize()
            if let text = row.text {
                // Long names ellipsize instead of widening the capsule.
                Text(text)
                    .font(.system(size: metrics.eventFont, design: .rounded))
                    .foregroundStyle(.secondary)
                    .strikethrough(row.disallowed)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: metrics.eventFont * 11, alignment: .leading)
            }
            Spacer(minLength: 6)
        }
    }

    private func logo(_ id: Int) -> String {
        TeamCatalog.team(for: id, in: session.allTeams).logo
    }

    private func scoreText(_ fixture: Fixture) -> String {
        fixture.status == "SCHEDULED" ? "vs" : fixture.scorelineText
    }
}
