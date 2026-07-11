import AppKit
import SwiftUI

// MARK: - Shared overlay-window configuration

/// The window level + collection behavior shared by EVERY floating overlay —
/// the notch notification stack, the center celebration ball, and pinned score
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

/// Owns one click-through capsule-stack panel per display. A SwiftUI `VStack`
/// performs the vertical layout; AppKit only sizes and anchors each whole stack.
/// All panels float above every app, including full screen (`OverlayWindow`).
@MainActor
final class PinnedCapsuleManager: ObservableObject {
    static let shared = PinnedCapsuleManager()

    /// Which matches are pinned — the menu observes this to swap a fixture row
    /// into its "shown in capsule" state.
    @Published private(set) var pinnedFixtureIds: Set<Int> = []
    /// All assignments point at the process-local display selected in Settings.
    @Published private(set) var displayAssignments: [Int: CGDirectDisplayID] = [:]
    /// Global insertion order; each display filters this into its own stack.
    @Published private(set) var order: [Int] = []
    /// Hover is derived from the global pointer because the panels themselves
    /// intentionally ignore every mouse event.
    @Published private(set) var hoveredFixtureId: Int?

    private var panels: [CGDirectDisplayID: NSPanel] = [:]
    private var capsuleFrames: [CGDirectDisplayID: [Int: CGRect]] = [:]
    private var hoverTimer: Timer?
    private var displayObserver: NSObjectProtocol?

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

    func toggle(fixtureId: Int) {
        if isPinned(fixtureId) { unpin(fixtureId: fixtureId) } else { pin(fixtureId: fixtureId) }
    }

    func pin(fixtureId: Int) {
        guard !isPinned(fixtureId),
              let displayID = OverlayDisplayTarget.shared.selectedDisplayID else { return }
        let panel = ensurePanel(for: displayID)
        displayAssignments[fixtureId] = displayID
        order.append(fixtureId)
        pinnedFixtureIds.insert(fixtureId)
        panel.orderFrontRegardless()
        startHoverTracking()
        AppLog.info(.app, "capsule_pinned fixture_id=\(fixtureId) display_id=\(displayID)")
    }

    func unpin(fixtureId: Int) {
        guard let displayID = displayAssignments[fixtureId] else { return }
        displayAssignments[fixtureId] = nil
        order.removeAll { $0 == fixtureId }
        pinnedFixtureIds.remove(fixtureId)
        if fixtureIds(on: displayID).isEmpty {
            panels[displayID]?.orderOut(nil)
            panels[displayID] = nil
            capsuleFrames[displayID] = nil
        }
        if hoveredFixtureId == fixtureId { hoveredFixtureId = nil }
        stopHoverTrackingIfIdle()
        AppLog.info(.app, "capsule_unpinned fixture_id=\(fixtureId)")
    }

    /// Tear every capsule down (sign-out / kill switch).
    func closeAll() {
        for panel in panels.values { panel.orderOut(nil) }
        panels.removeAll()
        capsuleFrames.removeAll()
        displayAssignments.removeAll()
        order.removeAll()
        pinnedFixtureIds.removeAll()
        hoveredFixtureId = nil
        hoverTimer?.invalidate()
        hoverTimer = nil
    }

    // MARK: Stack membership

    func fixtureIds(on displayID: CGDirectDisplayID) -> [Int] {
        order.filter { displayAssignments[$0] == displayID }
    }

    // MARK: Click-through hover tracking

    func updateCapsuleFrames(displayID: CGDirectDisplayID, frames: [Int: CGRect]) {
        guard let panel = panels[displayID] else { return }
        capsuleFrames[displayID] = frames.mapValues { frame in
            CGRect(
                x: panel.frame.minX + frame.minX,
                y: panel.frame.maxY - frame.maxY,
                width: frame.width,
                height: frame.height
            )
        }
        refreshHover()
    }

    private func startHoverTracking() {
        guard hoverTimer == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshHover() }
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    private func stopHoverTrackingIfIdle() {
        guard pinnedFixtureIds.isEmpty else { return }
        hoverTimer?.invalidate()
        hoverTimer = nil
    }

    private func refreshHover() {
        let pointer = NSEvent.mouseLocation
        let hovered = capsuleFrames.values.lazy
            .compactMap { frames in frames.first { $0.value.contains(pointer) }?.key }
            .first
        if hoveredFixtureId != hovered { hoveredFixtureId = hovered }
    }

    // MARK: Theme

    /// Re-apply the user's theme to every open capsule (Appearance can change
    /// while capsules are up). Mirrors `OverlayManager.applyOverlayTheme`.
    func applyTheme() {
        let appearance = overlayAppearance
        for panel in panels.values { panel.appearance = appearance }
    }

    // MARK: Panels

    private func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { self.displayID(for: $0) == displayID }
    }

    /// Migrate the complete stack when the user changes the setting or macOS
    /// removes the selected display. Hover still uses the pointer only to decide
    /// whether a capsule is expanded; it never chooses a target display.
    private func moveCapsulesToSelectedDisplay() {
        guard let displayID = OverlayDisplayTarget.shared.selectedDisplayID else {
            for panel in panels.values { panel.orderOut(nil) }
            panels.removeAll()
            capsuleFrames.removeAll()
            return
        }

        for panel in panels.values { panel.orderOut(nil) }
        panels.removeAll()
        capsuleFrames.removeAll()
        for fixtureId in pinnedFixtureIds { displayAssignments[fixtureId] = displayID }
        guard !pinnedFixtureIds.isEmpty else { return }
        ensurePanel(for: displayID).orderFrontRegardless()
    }

    private func ensurePanel(for displayID: CGDirectDisplayID) -> NSPanel {
        if let panel = panels[displayID] { return panel }
        guard let screen = screen(for: displayID) else {
            preconditionFailure("A capsule panel requires its captured display")
        }
        let panel = Self.makePanel(frame: screen.frame)
        let bottomInset = max(0, screen.visibleFrame.minY - screen.frame.minY)
        panel.contentView = Self.makeHostingView(
            PinnedCapsuleStackView(
                displayID: displayID,
                topInset: OverlayLayout.topInset(on: screen),
                bottomInset: bottomInset
            )
                .environmentObject(AppSession.shared)
                .environmentObject(self)
        )
        panel.appearance = overlayAppearance
        panels[displayID] = panel
        return panel
    }

    private var overlayAppearance: NSAppearance? {
        switch AppSession.shared.prefs.settings.theme ?? .system {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    private static func makePanel(frame: NSRect) -> NSPanel {
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // No AppKit shadow: it hugs the rectangular FRAME, not the rounded
        // capsule, and reads as a visible window boundary. The SwiftUI shadow
        // (inside the asymmetric stack inset) is the only shadow.
        panel.hasShadow = false
        panel.level = OverlayWindow.level
        panel.collectionBehavior = OverlayWindow.collectionBehavior
        panel.ignoresMouseEvents = true
        panel.sharingType = .readOnly
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = false
        return panel
    }

    /// Disable hosting-view-driven window constraints. Every capsule panel has
    /// a static display-sized frame; only its SwiftUI stack changes shape.
    private static func makeHostingView<Content: View>(_ rootView: Content) -> NSHostingView<Content> {
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.sizingOptions = []
        return hostingView
    }
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

/// One trailing-aligned stack inside a fixed, screen-sized click-through panel.
private struct PinnedCapsuleStackView: View {
    let displayID: CGDirectDisplayID
    let topInset: CGFloat
    let bottomInset: CGFloat
    @EnvironmentObject private var manager: PinnedCapsuleManager
    @EnvironmentObject private var session: AppSession

    private var alignment: Alignment {
        (session.prefs.settings.capsulePosition ?? .top) == .top ? .topTrailing : .bottomTrailing
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(alignment: .trailing, spacing: OverlayLayout.stackSpacing) {
                ForEach(manager.fixtureIds(on: displayID), id: \.self) { fixtureId in
                    PinnedCapsuleView(fixtureId: fixtureId)
                        .background(
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: CapsuleFramesKey.self,
                                    value: [fixtureId: geometry.frame(in: .named("capsule-stack"))]
                                )
                            }
                        )
                }
            }
            .fixedSize()            
            .animation(.easeInOut(duration: 0.25), value: manager.hoveredFixtureId)
            .padding(EdgeInsets(
                top: topInset + OverlayLayout.topGap,
                leading: OverlayLayout.expandedShadowInset,
                bottom: bottomInset + OverlayLayout.expandedShadowInset,
                trailing: OverlayLayout.shadowInset
            ))
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: alignment)
        }
        .coordinateSpace(name: "capsule-stack")
        .onPreferenceChange(CapsuleFramesKey.self) { frames in
            DispatchQueue.main.async {
                manager.updateCapsuleFrames(displayID: displayID, frames: frames)
            }
        }
    }
}

/// The capsule content. At rest it's the tightest possible scoreline —
/// `logo score logo time` — in the notch pill's exact chrome. Hovering fades
/// and slides the team names and event timeline in. The screen-sized parent
/// panel is static and click-through; hover comes from the manager's global
/// pointer tracking. Reads live from `AppSession` as `LiveStore` polls.
struct PinnedCapsuleView: View {
    let fixtureId: Int
    @EnvironmentObject var session: AppSession
    @EnvironmentObject var manager: PinnedCapsuleManager
    @Environment(\.colorScheme) private var scheme

    private var metrics: CapsuleMetrics { CapsuleMetrics(session.prefs.settings.capsuleSize ?? .medium) }
    private var fixture: Fixture? { session.fixtures.first { $0.fixtureId == fixtureId } }
    private var hovering: Bool { manager.hoveredFixtureId == fixtureId }

    var body: some View {
        Group {
            if let fixture {
                capsule(fixture)
            } else {
                // Fixture rolled out of today's list / cache cleared — retire it.
                Color.clear.frame(width: 1, height: 1).onAppear {
                    manager.unpin(fixtureId: fixtureId)
                }
            }
        }
        .fixedSize()
    }

    @ViewBuilder private func capsule(_ fixture: Fixture) -> some View {
        let hasEvents = !capsuleTimeline(for: fixture).isEmpty
        capsuleBody(fixture, showNames: hovering, showTimeline: hovering && hasEvents)
            .animation(.easeInOut(duration: 0.25), value: hovering)
    }

    private func timelineList(_ fixture: Fixture) -> some View {
        let rows = capsuleTimeline(for: fixture)
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

    /// The visible capsule chrome + content for one state.
    private func capsuleBody(_ fixture: Fixture, showNames: Bool, showTimeline: Bool) -> some View {
        VStack(alignment: .leading, spacing: metrics.rowSpacing) {
            header(fixture, showNames: showNames)
            if showTimeline {
                timelineList(fixture)
                    // Breathing room between the scoreline and the event list.
                    .padding(.top, metrics.rowSpacing)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, metrics.hPad)
        .padding(.vertical, metrics.vPad)
        // Clip to the animated bounds so event rows don't paint past the
        // background while the expand/collapse animation is in flight; the
        // shadowed fill sits outside the clip so it stays soft.
        .clipShape(RoundedRectangle(cornerRadius: capsuleCorner, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: capsuleCorner, style: .continuous)
                .fill(scheme == .dark ? Color.black : Color.white)
                .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
        )
        .contentShape(RoundedRectangle(cornerRadius: capsuleCorner, style: .continuous))
    }

    /// Names fade 0→1 while the width slide reveals them; on the way out the
    /// fade finishes FIRST (quick ease-out), so the shrinking capsule never
    /// shows visibly truncating text. The explicit animations are needed —
    /// a bare .opacity transition pops in at full alpha here.
    private var nameTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.animation(.easeInOut(duration: 0.2)),
            removal: .opacity.animation(.easeOut(duration: 0.1))
        )
    }

    /// The scoreline row. At rest it's `logo score logo time`; with
    /// `showNames` the team names slide in around the score.
    private func header(_ fixture: Fixture, showNames: Bool) -> some View {
        HStack(spacing: 6) {
            // The scoreline itself hugs its content on ONE line (the inner
            // `.fixedSize`). Keeping it as its own group lets it sit flush-left
            // while the clock is pushed to the trailing edge by the Spacer — so
            // when the capsule expands to the timeline's width the clock stays
            // pinned right instead of drifting in beside the score.
            HStack(spacing: 6) {
                CachedTeamLogo(url: logo(fixture.home.id), size: metrics.headerLogo)
                if showNames {
                    Text(fixture.home.name)
                        .font(.system(size: metrics.nameFont, design: .rounded))
                        .lineLimit(1)
                        .transition(nameTransition)
                }
                Text(scoreText(fixture))
                    .font(.system(size: metrics.scoreFont, weight: .bold, design: .rounded))
                    .fixedSize().layoutPriority(1)
                if showNames {
                    Text(fixture.away.name)
                        .font(.system(size: metrics.nameFont, design: .rounded))
                        .lineLimit(1)
                        .transition(nameTransition)
                }
                CachedTeamLogo(url: logo(fixture.away.id), size: metrics.headerLogo)
            }
            // Keep the scoreline on ONE line: at `45+x′` the wider clock would
            // otherwise skew the HStack's ideal-size negotiation and truncate a
            // team name. The capsule is free to grow wider instead.
            .fixedSize()
            if showNames {
                Spacer(minLength: 8)
            }
            trailing(fixture)
        }
    }

    @ViewBuilder private func trailing(_ fixture: Fixture) -> some View {
        if fixture.isLive {
            HStack(spacing: 4) {
                Circle().fill(.red).frame(width: 6, height: 6)
                Text(fixture.liveMinuteText(clockStale: LiveStore.shared.isClockStale(fixture.fixtureId)))
                    .font(.system(size: metrics.timeFont, weight: .bold, design: .rounded))
                    .foregroundStyle(.red)
            }
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
                .frame(minWidth: metrics.eventFont * 2.6, alignment: .trailing)
                .hidden()
                .overlay(alignment: .trailing) {
                    Text(row.minuteText)
                        .font(.system(size: metrics.eventFont, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
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
            if let text = row.text {
                Text(text)
                    .font(.system(size: metrics.eventFont, design: .rounded))
                    .foregroundStyle(.secondary)
                    .strikethrough(row.disallowed)
            }
            Spacer(minLength: 6)
        }
        .padding(.leading, metrics.rowSpacing)
    }

    private func logo(_ id: Int) -> String {
        TeamCatalog.team(for: id, in: session.teams).logo
    }

    private func scoreText(_ fixture: Fixture) -> String {
        fixture.status == "SCHEDULED" ? "vs" : fixture.scorelineText
    }
}

/// Capsule bounds in the fixed panel's top-left SwiftUI coordinate space.
private struct CapsuleFramesKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}
