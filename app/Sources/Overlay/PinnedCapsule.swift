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

/// Capsules share the notch pill's exact chrome (NotchPillView): this corner
/// radius, a solid black/white fill, and a soft drop shadow.
let capsuleCorner: CGFloat = 18

/// How long the event icon takes to wipe across the capsule.
let capsuleSweepDuration: Double = 1.0

// MARK: - Snap zones

/// Where a capsule lives: the top-left or top-right corner. Capsules never
/// move freely — a stack per side, reordered/switched via the context menu.
/// Origins are computed in AppKit screen coordinates (origin bottom-left) from
/// the screen's `visibleFrame` (which already excludes the menu bar and Dock).
enum SnapZone {
    case topLeading, topTrailing

    var opposite: SnapZone { self == .topLeading ? .topTrailing : .topLeading }

    /// Bottom-left origin for a capsule panel of `size` in this zone on
    /// `screen`. `inset` is the transparent chrome padding around the visible
    /// capsule (shadow + wiggle room), subtracted so the VISIBLE edge sits
    /// `margin` from the screen edge. `stackOffset` pushes later capsules down
    /// so several pins on the same side stack instead of overlapping.
    func origin(size: CGSize, on screen: NSScreen, margin: CGFloat, inset: CGFloat, stackOffset: CGFloat) -> CGPoint {
        let vf = screen.visibleFrame
        let x: CGFloat = switch self {
        case .topLeading: vf.minX + margin - inset
        case .topTrailing: vf.maxX - margin - size.width + inset
        }
        let y = vf.maxY - margin - size.height + inset - stackOffset
        return CGPoint(x: x, y: y)
    }
}

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

// MARK: - Event notice

/// A just-routed event for a pinned match — drives the capsule's wiggle and
/// the icon that wipes across the score. `id` makes every notice fresh so
/// `onChange` fires even when two identical events arrive back to back.
struct CapsuleNotice: Equatable {
    let id: UUID
    let icon: String
    let color: Color
}

// MARK: - Manager

/// Owns the floating score capsules — one `NSPanel` per pinned fixture. Mirrors
/// `OverlayManager`'s panel handling but the panels are interactive (clicks are
/// absorbed, not passed through). Capsules live in the top-left or top-right
/// corner only, stacked per side; the context menu reorders or switches sides.
/// All panels float above every app, including full screen (`OverlayWindow`).
@MainActor
final class PinnedCapsuleManager: ObservableObject {
    static let shared = PinnedCapsuleManager()

    /// Which matches are pinned — the menu observes this to swap a fixture row
    /// into its "shown in capsule" state.
    @Published private(set) var pinnedFixtureIds: Set<Int> = []
    /// Which side each capsule sits on. Published so context-menu items
    /// (Move left/right) reflect a move immediately.
    @Published private(set) var zones: [Int: SnapZone] = [:]
    /// Stack order (top to bottom within a zone). Published so Move up/down
    /// availability refreshes after a reorder.
    @Published private(set) var order: [Int] = []
    /// Latest event per pinned fixture — the capsule view watches its entry.
    @Published private(set) var notices: [Int: CapsuleNotice] = [:]

    private static let margin: CGFloat = 16
    private static let stackGap: CGFloat = 12
    /// Transparent padding around the visible capsule inside its borderless
    /// panel. The panel draws NO window shadow (a rectangular halo would betray
    /// the window boundary), so the SwiftUI shadow — and the wiggle offset —
    /// need room inside the frame to avoid being clipped.
    static let chromeInset: CGFloat = 24

    private var panels: [Int: NSPanel] = [:]

    func isPinned(_ fixtureId: Int) -> Bool { pinnedFixtureIds.contains(fixtureId) }

    func toggle(fixtureId: Int) {
        if isPinned(fixtureId) { unpin(fixtureId: fixtureId) } else { pin(fixtureId: fixtureId) }
    }

    func pin(fixtureId: Int) {
        guard panels[fixtureId] == nil, let screen else { return }
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
        zones[fixtureId] = .topTrailing
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
        notices[fixtureId] = nil
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
        notices.removeAll()
        pinnedFixtureIds.removeAll()
    }

    // MARK: Events

    /// An event was routed for a match; if that match is pinned, hand the
    /// event's icon to its capsule so it wiggles and wipes the icon across.
    /// Pills/celebrations are untouched — this is purely additive.
    func notify(_ event: MatchEvent) {
        guard isPinned(event.fixtureId) else { return }
        notices[event.fixtureId] = CapsuleNotice(
            id: UUID(),
            icon: pillIcon(for: event),
            color: pillIconColor(for: event)
        )
    }

    // MARK: Reordering — the context menu's Move up/down/left/right

    func zone(of fixtureId: Int) -> SnapZone? { zones[fixtureId] }

    /// Top-to-bottom capsule ids on one side.
    private func stack(in zone: SnapZone) -> [Int] {
        order.filter { zones[$0] == zone }
    }

    func canMoveUp(_ fixtureId: Int) -> Bool {
        guard let zone = zones[fixtureId] else { return false }
        return stack(in: zone).firstIndex(of: fixtureId).map { $0 > 0 } ?? false
    }

    func canMoveDown(_ fixtureId: Int) -> Bool {
        guard let zone = zones[fixtureId] else { return false }
        let stack = stack(in: zone)
        return stack.firstIndex(of: fixtureId).map { $0 < stack.count - 1 } ?? false
    }

    func moveUp(_ fixtureId: Int) {
        guard let zone = zones[fixtureId] else { return }
        let stack = stack(in: zone)
        guard let index = stack.firstIndex(of: fixtureId), index > 0 else { return }
        swapInOrder(fixtureId, stack[index - 1])
        relayout(zone: zone)
    }

    func moveDown(_ fixtureId: Int) {
        guard let zone = zones[fixtureId] else { return }
        let stack = stack(in: zone)
        guard let index = stack.firstIndex(of: fixtureId), index < stack.count - 1 else { return }
        swapInOrder(fixtureId, stack[index + 1])
        relayout(zone: zone)
    }

    /// Both ids share a zone, so swapping their global positions in `order`
    /// swaps only their relative stack position.
    private func swapInOrder(_ a: Int, _ b: Int) {
        guard let ia = order.firstIndex(of: a), let ib = order.firstIndex(of: b) else { return }
        order.swapAt(ia, ib)
    }

    /// Switch sides — the capsule joins the destination stack at the bottom.
    func move(_ fixtureId: Int, to zone: SnapZone) {
        guard let previous = zones[fixtureId], previous != zone else { return }
        zones[fixtureId] = zone
        order.removeAll { $0 == fixtureId }
        order.append(fixtureId)
        relayout(zone: previous)
        relayout(zone: zone)
    }

    // MARK: Sizing — the SwiftUI content reports its natural size

    /// The capsule content measured a new size (setting change, hover expanded
    /// the event list, …). Resize the panel, then reflow its whole zone so
    /// stacking stays tight and the capsule stays glued to its corner.
    func reposition(fixtureId: Int, contentSize: CGSize) {
        guard let panel = panels[fixtureId] else { return }
        let size = CGSize(width: ceil(contentSize.width), height: ceil(contentSize.height))
        guard size.width > 1, size.height > 1 else { return }
        panel.setContentSize(size)
        if let zone = zones[fixtureId] { relayout(zone: zone) }
    }

    /// Re-place every capsule assigned to `zone`, stacking them in `order`.
    /// The gap math subtracts the transparent chrome inset on both sides so
    /// VISIBLE capsules sit `stackGap` apart.
    private func relayout(zone: SnapZone) {
        guard let screen else { return }
        var offset: CGFloat = 0
        for fixtureId in order where zones[fixtureId] == zone {
            guard let panel = panels[fixtureId] else { continue }
            let size = panel.frame.size
            let origin = zone.origin(
                size: size, on: screen,
                margin: Self.margin, inset: Self.chromeInset, stackOffset: offset
            )
            panel.setFrameOrigin(origin)
            offset += size.height - 2 * Self.chromeInset + Self.stackGap
        }
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
        // No AppKit shadow: it hugs the rectangular FRAME, not the rounded
        // capsule, and reads as a visible window boundary. The SwiftUI shadow
        // (inside the chrome inset) is the only shadow — same as the pills.
        panel.hasShadow = false
        panel.level = OverlayWindow.level
        panel.collectionBehavior = OverlayWindow.collectionBehavior
        panel.ignoresMouseEvents = false // interactive — hover + context menu
        panel.sharingType = .readOnly
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true // context menu on a nonactivating panel
        panel.isMovableByWindowBackground = false
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
                teamId: team.id
            ))
        }
    }

    for team in [fixture.home, fixture.away] {
        add(team.goalEvents, type: .goal, team: team, prefix: "g")
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

/// The capsule content. At rest it's the tightest possible scoreline —
/// `logo score logo time` — in the notch pill's exact chrome. Hover expands it
/// with team names and every event so far. A routed event wiggles the capsule
/// and wipes the event's icon across the score like a windshield wiper. Reads
/// live from `AppSession`, so it updates as `LiveStore` polls.
struct PinnedCapsuleView: View {
    let fixtureId: Int
    @EnvironmentObject var session: AppSession
    @EnvironmentObject var manager: PinnedCapsuleManager
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false
    @State private var sweep: CapsuleNotice?
    @State private var sweepProgress: CGFloat = 0
    @State private var wiggle: CGFloat = 0

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
        Group {
            if hovering {
                VStack(alignment: .leading, spacing: metrics.rowSpacing) {
                    header(fixture)
                    ForEach(capsuleTimeline(for: fixture)) { row in
                        eventRow(row)
                    }
                }
            } else {
                compactHeader(fixture)
            }
        }
        .padding(.horizontal, metrics.hPad)
        .padding(.vertical, metrics.vPad)
        .overlay { wiper }
        // Clip content + wiper to the capsule shape (the wiper enters/exits
        // through the rounded edges); the shadowed fill below is NOT clipped.
        .clipShape(RoundedRectangle(cornerRadius: capsuleCorner, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: capsuleCorner, style: .continuous)
                .fill(scheme == .dark ? Color.black : Color.white)
                .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
        )
        .contextMenu {
            if manager.canMoveUp(fixtureId) {
                Button("Move up") { manager.moveUp(fixtureId) }
            }
            if manager.canMoveDown(fixtureId) {
                Button("Move down") { manager.moveDown(fixtureId) }
            }
            if manager.zone(of: fixtureId) == .topLeading {
                Button("Move right") { manager.move(fixtureId, to: .topTrailing) }
            } else {
                Button("Move left") { manager.move(fixtureId, to: .topLeading) }
            }
            Divider()
            Button("Close") { manager.unpin(fixtureId: fixtureId) }
        }
        .onHover { over in
            withAnimation(.easeOut(duration: 0.15)) { hovering = over }
        }
        .offset(x: wiggle)
        // Transparent room for the shadow and the wiggle inside the borderless
        // panel — the manager's layout math cancels this out at the edges.
        .padding(PinnedCapsuleManager.chromeInset)
        .onChange(of: manager.notices[fixtureId]) { _, notice in
            if let notice { run(notice) }
        }
    }

    /// At rest: `logo score logo time`.
    private func compactHeader(_ fixture: Fixture) -> some View {
        HStack(spacing: 6) {
            CachedTeamLogo(url: logo(fixture.home.id), size: metrics.headerLogo)
            Text(scoreText(fixture))
                .font(.system(size: metrics.scoreFont, weight: .bold, design: .rounded))
                .fixedSize()
            CachedTeamLogo(url: logo(fixture.away.id), size: metrics.headerLogo)
            trailing(fixture)
        }
    }

    /// On hover: the full matchup — `logo name score name logo time`.
    private func header(_ fixture: Fixture) -> some View {
        HStack(spacing: 6) {
            CachedTeamLogo(url: logo(fixture.home.id), size: metrics.headerLogo)
            Text(fixture.home.name)
                .font(.system(size: metrics.nameFont, design: .rounded)).lineLimit(1)
            Text(scoreText(fixture))
                .font(.system(size: metrics.scoreFont, weight: .bold, design: .rounded))
                .fixedSize().layoutPriority(1)
            Text(fixture.away.name)
                .font(.system(size: metrics.nameFont, design: .rounded)).lineLimit(1)
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

    /// One past event: `minute · icon · label · player? · team logo`, a step
    /// smaller than the header so the scoreline stays the loudest line.
    private func eventRow(_ row: CapsuleTimelineRow) -> some View {
        HStack(spacing: 6) {
            Text(row.minuteText)
                .font(.system(size: metrics.eventFont, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(minWidth: metrics.eventFont * 2.6, alignment: .trailing)
            Image(systemName: row.icon)
                .font(.system(size: metrics.eventIcon, weight: .semibold))
                .foregroundStyle(row.color)
                .frame(width: metrics.eventIcon + 6)
            Text(row.label)
                .font(.system(size: metrics.eventFont, weight: .semibold, design: .rounded))
            if let text = row.text {
                Text(text)
                    .font(.system(size: metrics.eventFont, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if let teamId = row.teamId {
                CachedTeamLogo(url: logo(teamId), size: metrics.eventLogo)
            }
        }
        .padding(.leading, metrics.rowSpacing)
    }

    // MARK: Event reaction — wiggle + windshield-wiper icon

    /// The event icon passing over the score. Always present (hidden when
    /// idle) so the sweep animation never targets a freshly inserted view.
    private var wiper: some View {
        GeometryReader { geo in
            Image(systemName: sweep?.icon ?? "circle")
                .font(.system(size: metrics.scoreFont + 4, weight: .semibold))
                .foregroundStyle(sweep?.color ?? .primary)
                .opacity(sweep == nil ? 0 : 1)
                .position(
                    x: -24 + (geo.size.width + 48) * sweepProgress,
                    y: geo.size.height / 2
                )
        }
        .allowsHitTesting(false)
    }

    private func run(_ notice: CapsuleNotice) {
        withAnimation(nil) {
            sweep = notice
            sweepProgress = 0
        }
        withAnimation(.easeInOut(duration: capsuleSweepDuration)) { sweepProgress = 1 }
        // One left-right shake: jump off-center, spring back under-damped so it
        // overshoots once and settles.
        wiggle = 8
        withAnimation(.spring(response: 0.35, dampingFraction: 0.3)) { wiggle = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + capsuleSweepDuration) {
            if sweep?.id == notice.id { sweep = nil }
        }
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
