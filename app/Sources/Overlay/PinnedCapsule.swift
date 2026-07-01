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

// MARK: - Snap zones

/// One of the six corners/edges a capsule can settle into. Origins are computed
/// in AppKit screen coordinates (origin bottom-left) from the screen's
/// `visibleFrame` (which already excludes the menu bar and Dock).
enum SnapZone: CaseIterable {
    case topLeading, topCenter, topTrailing
    case bottomLeading, bottomCenter, bottomTrailing

    private var isTop: Bool { self == .topLeading || self == .topCenter || self == .topTrailing }

    /// Bottom-left origin for a capsule of `size` in this zone on `screen`, with
    /// `margin` from the edges and `stackOffset` pushing later capsules along
    /// the vertical (down from the top, up from the bottom) so several pins in
    /// the same zone stack instead of overlapping.
    func origin(size: CGSize, on screen: NSScreen, margin: CGFloat, stackOffset: CGFloat) -> CGPoint {
        let vf = screen.visibleFrame
        let x: CGFloat
        switch self {
        case .topLeading, .bottomLeading: x = vf.minX + margin
        case .topCenter, .bottomCenter: x = vf.midX - size.width / 2
        case .topTrailing, .bottomTrailing: x = vf.maxX - margin - size.width
        }
        let y: CGFloat = isTop
            ? vf.maxY - margin - size.height - stackOffset
            : vf.minY + margin + stackOffset
        return CGPoint(x: x, y: y)
    }

    /// Center point of a capsule of `size` placed in this zone — used to pick
    /// the nearest zone on drag release.
    func center(size: CGSize, on screen: NSScreen, margin: CGFloat) -> CGPoint {
        let o = origin(size: size, on: screen, margin: margin, stackOffset: 0)
        return CGPoint(x: o.x + size.width / 2, y: o.y + size.height / 2)
    }
}

// MARK: - Size metrics

/// Every dimension in the capsule, scaled by the user's `CapsuleSize` setting.
/// Medium is the baseline; small/large step it down/up proportionally.
struct CapsuleMetrics {
    let nameFont: CGFloat
    let scoreFont: CGFloat
    let headerLogo: CGFloat
    let timeFont: CGFloat
    let countFont: CGFloat
    let countLogo: CGFloat
    let eventFont: CGFloat
    let eventIcon: CGFloat
    let eventLogo: CGFloat
    let hPad: CGFloat
    let vPad: CGFloat
    let rowSpacing: CGFloat
    let corner: CGFloat

    init(_ size: CapsuleSize) {
        switch size {
        case .small:
            nameFont = 11; scoreFont = 12; headerLogo = 16; timeFont = 10
            countFont = 10; countLogo = 14
            eventFont = 10; eventIcon = 11; eventLogo = 14
            hPad = 12; vPad = 8; rowSpacing = 4; corner = 14
        case .medium:
            nameFont = 13; scoreFont = 15; headerLogo = 20; timeFont = 12
            countFont = 12; countLogo = 16
            eventFont = 12; eventIcon = 13; eventLogo = 16
            hPad = 16; vPad = 11; rowSpacing = 6; corner = 18
        case .large:
            nameFont = 16; scoreFont = 19; headerLogo = 26; timeFont = 14
            countFont = 15; countLogo = 20
            eventFont = 15; eventIcon = 16; eventLogo = 20
            hPad = 20; vPad = 14; rowSpacing = 8; corner = 22
        }
    }
}

// MARK: - Manager

/// Owns the floating score capsules — one `NSPanel` per pinned fixture. Mirrors
/// `OverlayManager`'s panel handling but the panels are interactive (clicks are
/// absorbed, not passed through), draggable, and snap to one of six zones. All
/// panels float above every app, including full screen (`OverlayWindow`).
@MainActor
final class PinnedCapsuleManager: ObservableObject {
    static let shared = PinnedCapsuleManager()

    /// Which matches are pinned — the menu observes this to swap a fixture row
    /// into its "shown in capsule" state.
    @Published private(set) var pinnedFixtureIds: Set<Int> = []

    private static let margin: CGFloat = 16
    private static let stackGap: CGFloat = 12

    private var panels: [Int: NSPanel] = [:]
    private var zones: [Int: SnapZone] = [:]
    /// Pin order, so stacked capsules in a zone keep a stable top-to-bottom order.
    private var order: [Int] = []
    /// Capsules currently being dragged — skip auto-reposition so a new event
    /// arriving mid-drag doesn't yank the panel out from under the cursor.
    private var dragging: Set<Int> = []
    private var dragStartOrigin: [Int: CGPoint] = [:]

    func isPinned(_ fixtureId: Int) -> Bool { pinnedFixtureIds.contains(fixtureId) }

    func toggle(fixtureId: Int) {
        if isPinned(fixtureId) { unpin(fixtureId: fixtureId) } else { pin(fixtureId: fixtureId) }
    }

    func pin(fixtureId: Int) {
        guard panels[fixtureId] == nil, let screen else { return }
        let zone: SnapZone = .topTrailing
        // A small placeholder size; the first geometry callback resizes+places it.
        let initial = NSRect(x: 0, y: 0, width: 260, height: 96)
        let panel = Self.makePanel(frame: initial)
        panel.contentView = Self.makeHostingView(
            PinnedCapsuleView(fixtureId: fixtureId)
                .environmentObject(AppSession.shared)
                .environmentObject(self)
        )
        panel.appearance = overlayAppearance
        panels[fixtureId] = panel
        zones[fixtureId] = zone
        order.append(fixtureId)
        pinnedFixtureIds.insert(fixtureId)
        panel.orderFrontRegardless()
        AppLog.info(.app, "capsule_pinned fixture_id=\(fixtureId)")
    }

    func unpin(fixtureId: Int) {
        guard let panel = panels[fixtureId] else { return }
        let zone = zones[fixtureId]
        panel.orderOut(nil)
        panels[fixtureId] = nil
        zones[fixtureId] = nil
        order.removeAll { $0 == fixtureId }
        dragging.remove(fixtureId)
        dragStartOrigin[fixtureId] = nil
        pinnedFixtureIds.remove(fixtureId)
        if let zone { relayout(zone: zone) }
        AppLog.info(.app, "capsule_unpinned fixture_id=\(fixtureId)")
    }

    /// Tear every capsule down (sign-out / kill switch).
    func closeAll() {
        for panel in panels.values { panel.orderOut(nil) }
        panels.removeAll()
        zones.removeAll()
        order.removeAll()
        dragging.removeAll()
        dragStartOrigin.removeAll()
        pinnedFixtureIds.removeAll()
    }

    // MARK: Sizing — the SwiftUI content reports its natural size

    /// The capsule content measured a new size (setting change, or an event row
    /// appeared). Resize the panel, then reflow its whole zone so stacking stays
    /// tight and the capsule stays glued to its corner.
    func reposition(fixtureId: Int, contentSize: CGSize) {
        guard let panel = panels[fixtureId], !dragging.contains(fixtureId) else { return }
        let size = CGSize(width: ceil(contentSize.width), height: ceil(contentSize.height))
        guard size.width > 1, size.height > 1 else { return }
        panel.setContentSize(size)
        if let zone = zones[fixtureId] { relayout(zone: zone) }
    }

    /// Re-place every capsule assigned to `zone`, stacking them in pin order.
    private func relayout(zone: SnapZone) {
        guard let screen else { return }
        var offset: CGFloat = 0
        for fixtureId in order where zones[fixtureId] == zone && !dragging.contains(fixtureId) {
            guard let panel = panels[fixtureId] else { continue }
            let size = panel.frame.size
            let origin = zone.origin(size: size, on: screen, margin: Self.margin, stackOffset: offset)
            panel.setFrameOrigin(origin)
            offset += size.height + Self.stackGap
        }
    }

    // MARK: Dragging

    func beginDrag(fixtureId: Int) {
        guard let panel = panels[fixtureId] else { return }
        dragging.insert(fixtureId)
        dragStartOrigin[fixtureId] = panel.frame.origin
    }

    /// `translation` is the SwiftUI drag translation (y grows downward), so the
    /// vertical delta is negated for AppKit's bottom-left origin.
    func drag(fixtureId: Int, translation: CGSize) {
        guard dragging.contains(fixtureId), let panel = panels[fixtureId],
              let start = dragStartOrigin[fixtureId] else { return }
        panel.setFrameOrigin(CGPoint(x: start.x + translation.width, y: start.y - translation.height))
    }

    /// Snap to whichever zone's center is closest to where the capsule was
    /// dropped, then reflow the old and new zones.
    func endDrag(fixtureId: Int) {
        defer { dragging.remove(fixtureId); dragStartOrigin[fixtureId] = nil }
        guard dragging.contains(fixtureId), let panel = panels[fixtureId], let screen else { return }
        let size = panel.frame.size
        let dropped = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        let nearest = SnapZone.allCases.min { a, b in
            distance(dropped, a.center(size: size, on: screen, margin: Self.margin))
                < distance(dropped, b.center(size: size, on: screen, margin: Self.margin))
        } ?? .topTrailing
        let previous = zones[fixtureId]
        zones[fixtureId] = nearest
        dragging.remove(fixtureId)
        if let previous, previous != nearest { relayout(zone: previous) }
        relayout(zone: nearest)
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x, dy = a.y - b.y
        return dx * dx + dy * dy
    }

    // MARK: Theme

    /// Re-apply the user's theme to every open capsule (Appearance can change
    /// while capsules are up). Mirrors `OverlayManager.applyOverlayTheme`.
    func applyTheme() {
        let appearance = overlayAppearance
        for panel in panels.values { panel.appearance = appearance }
    }

    // MARK: Panels

    private var screen: NSScreen? { NSScreen.main ?? NSScreen.screens.first }

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
        panel.hasShadow = true
        panel.level = OverlayWindow.level
        panel.collectionBehavior = OverlayWindow.collectionBehavior
        panel.ignoresMouseEvents = false // interactive — clicks never pass through
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = false // only the grip drags it
        return panel
    }

    /// Fixed-size hosting so the SwiftUI content doesn't drive window
    /// constraints; the panel frame is set from the measured content size.
    private static func makeHostingView<Content: View>(_ rootView: Content) -> NSHostingView<Content> {
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.sizingOptions = []
        return hostingView
    }
}

// MARK: - Timeline

/// One flattened row of a match's timeline (goal / card / penalty kick), built
/// straight from the `Fixture` scoreboard so the capsule needs no event stream.
struct CapsuleTimelineRow: Identifiable {
    let id: String
    let minute: Int?
    let extra: Int?
    let icon: String
    let color: Color
    let text: String
    let teamId: Int?

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

    func add(_ events: [MatchTimelineEvent], type: MatchEventType, team: ScoreboardTeam, prefix: String) {
        for (index, event) in events.enumerated() {
            rows.append(CapsuleTimelineRow(
                id: "\(fixture.fixtureId):\(prefix):\(team.id):\(index)",
                minute: event.minute,
                extra: event.extra,
                icon: pillIcon(for: type),
                color: pillIconColor(for: type),
                text: event.player ?? label(for: type),
                teamId: team.id
            ))
        }
    }

    for team in [fixture.home, fixture.away] {
        add(team.goalEvents, type: .goal, team: team, prefix: "g")
        add(team.yellowCardEvents, type: .yellowCard, team: team, prefix: "y")
        add(team.redCardEvents, type: .redCard, team: team, prefix: "r")
    }

    for (index, kick) in (fixture.shootout?.kicks ?? []).enumerated() {
        let scored = kick.scored
        rows.append(CapsuleTimelineRow(
            id: "\(fixture.fixtureId):pk:\(index)",
            minute: nil,
            extra: nil,
            icon: scored ? "checkmark.circle.fill" : "xmark.circle.fill",
            color: scored ? .green : .red,
            text: kick.player ?? (scored ? "Scored" : "Missed"),
            teamId: kick.teamId
        ))
    }

    return rows.sorted { $0.sortKey < $1.sortKey }
}

private func label(for type: MatchEventType) -> String {
    switch type {
    case .goal: "Goal"
    case .yellowCard: "Yellow card"
    case .redCard: "Red card"
    default: ""
    }
}

// MARK: - View

/// The capsule content: a header scoreline that grows with a celebration-count
/// row and per-event rows as the match unfolds. Reads live from `AppSession`,
/// so it updates as `LiveStore` polls. Hover reveals a top-center drag grip;
/// dragging moves the panel and releasing snaps it to the nearest zone.
struct PinnedCapsuleView: View {
    let fixtureId: Int
    @EnvironmentObject var session: AppSession
    @EnvironmentObject var manager: PinnedCapsuleManager
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false
    @State private var dragActive = false

    private var metrics: CapsuleMetrics { CapsuleMetrics(session.prefs.settings.capsuleSize ?? .medium) }
    private var fixture: Fixture? { session.fixtures.first { $0.fixtureId == fixtureId } }

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
        // Measure the natural size (macOS 14 has no onGeometryChange) and hand
        // it to the manager, which resizes + re-anchors the panel.
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: CapsuleSizeKey.self, value: geo.size)
            }
        )
        .onPreferenceChange(CapsuleSizeKey.self) { size in
            DispatchQueue.main.async { manager.reposition(fixtureId: fixtureId, contentSize: size) }
        }
    }

    @ViewBuilder private func capsule(_ fixture: Fixture) -> some View {
        let rows = capsuleTimeline(for: fixture)
        let totals = session.celebrationTotals[fixtureId]
        VStack(alignment: .leading, spacing: metrics.rowSpacing) {
            header(fixture)
            if let totals, totals.values.contains(where: { $0 > 0 }) {
                celebrationRow(fixture, totals: totals)
            }
            ForEach(rows) { row in
                eventRow(row)
            }
        }
        .padding(.horizontal, metrics.hPad)
        .padding(.vertical, metrics.vPad)
        .padding(.top, hovering ? metrics.rowSpacing : 0) // room for the grip
        .background(
            RoundedRectangle(cornerRadius: metrics.corner, style: .continuous)
                .fill(scheme == .dark ? Color.black : Color.white)
                .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
        )
        .overlay(alignment: .top) { dragGrip }
        .onHover { over in
            withAnimation(.easeOut(duration: 0.15)) { hovering = over }
        }
    }

    private func header(_ fixture: Fixture) -> some View {
        HStack(spacing: 6) {
            CachedTeamLogo(url: logo(fixture.home.id), size: metrics.headerLogo)
            Text(fixture.home.name).font(.system(size: metrics.nameFont)).lineLimit(1)
            Text(scoreText(fixture))
                .font(.system(size: metrics.scoreFont, weight: .bold))
                .fixedSize().layoutPriority(1)
            Text(fixture.away.name).font(.system(size: metrics.nameFont)).lineLimit(1)
            CachedTeamLogo(url: logo(fixture.away.id), size: metrics.headerLogo)
            Spacer(minLength: 8)
            trailing(fixture)
        }
    }

    @ViewBuilder private func trailing(_ fixture: Fixture) -> some View {
        if fixture.isLive {
            HStack(spacing: 4) {
                Circle().fill(.red).frame(width: 6, height: 6)
                Text(fixture.liveMinuteText)
                    .font(.system(size: metrics.timeFont, weight: .bold))
                    .foregroundStyle(.red)
            }
        } else if fixture.status == "FINISHED" {
            Text("FT").font(.system(size: metrics.timeFont, weight: .semibold)).foregroundStyle(.green)
        } else if let kickoff = fixture.kickoff {
            Text(kickoff, style: .time).font(.system(size: metrics.timeFont)).opacity(0.7)
        }
    }

    private func celebrationRow(_ fixture: Fixture, totals: [String: Int]) -> some View {
        HStack(spacing: 6) {
            CachedTeamLogo(url: logo(fixture.home.id), size: metrics.countLogo)
            Text((totals[String(fixture.home.id)] ?? 0).formattedCompact)
                .font(.system(size: metrics.countFont, weight: .bold))
            Text("–").font(.system(size: metrics.countFont, weight: .bold))
            Text((totals[String(fixture.away.id)] ?? 0).formattedCompact)
                .font(.system(size: metrics.countFont, weight: .bold))
            CachedTeamLogo(url: logo(fixture.away.id), size: metrics.countLogo)
            Text("Celebrations 🎉").font(.system(size: metrics.countFont - 2)).opacity(0.7)
        }
    }

    private func eventRow(_ row: CapsuleTimelineRow) -> some View {
        HStack(spacing: 6) {
            Text(row.minuteText)
                .font(.system(size: metrics.eventFont, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(minWidth: metrics.eventFont * 2.6, alignment: .leading)
            Image(systemName: row.icon)
                .font(.system(size: metrics.eventIcon, weight: .semibold))
                .foregroundStyle(row.color)
            Text(row.text).font(.system(size: metrics.eventFont)).lineLimit(1)
            Spacer(minLength: 6)
            if let teamId = row.teamId {
                CachedTeamLogo(url: logo(teamId), size: metrics.eventLogo)
            }
        }
    }

    private var dragGrip: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(scheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.10))
            )
            .padding(.top, 3)
            .opacity(hovering ? 1 : 0)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if !dragActive {
                            dragActive = true
                            manager.beginDrag(fixtureId: fixtureId)
                        }
                        manager.drag(fixtureId: fixtureId, translation: value.translation)
                    }
                    .onEnded { _ in
                        dragActive = false
                        manager.endDrag(fixtureId: fixtureId)
                    }
            )
    }

    private func logo(_ id: Int) -> String {
        TeamCatalog.team(for: id, in: session.teams).logo
    }

    private func scoreText(_ fixture: Fixture) -> String {
        fixture.status == "SCHEDULED" ? "vs" : fixture.scorelineText
    }
}

/// Reports the capsule's natural size up to the manager for panel sizing.
private struct CapsuleSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}
