import AppKit
import Combine
import SwiftUI

// MARK: - Geometry

/// Where the hardware notch sits on a screen — or, on a display without one,
/// the virtual notch the island grows out of: top-center, menu-bar tall.
struct NotchGeometry {
    let hasNotch: Bool
    /// The camera housing's width; 0 on a notchless display.
    let notchWidth: CGFloat
    /// Height of the band under the screen's top edge that content stays
    /// below: the notch's height, or the menu bar's.
    let bandHeight: CGFloat

    /// Each side of the compact pin, beside the notch. Fixed — the compact
    /// pin lives in the menu bar and doesn't follow the size setting.
    static let earWidth: CGFloat = 96

    init(screen: NSScreen?) {
        guard let screen else {
            hasNotch = false
            notchWidth = 0
            bandHeight = OverlayLayout.fallbackMenuBarHeight
            return
        }
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            hasNotch = true
            notchWidth = screen.frame.width - left.width - right.width
            bandHeight = screen.safeAreaInsets.top
        } else {
            hasNotch = false
            notchWidth = 0
            // 0 when the menu bar auto-hides.
            let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
            bandHeight = menuBar > 0 ? menuBar : OverlayLayout.fallbackMenuBarHeight
        }
    }

    /// The space between the ears: the camera, or a hairline gap.
    var gap: CGFloat { hasNotch ? notchWidth : 8 }
    var compactWidth: CGFloat { gap + 2 * Self.earWidth }

    /// The resting island: exactly the hardware notch (black on black, so
    /// invisible), or a zero-height sliver on a notchless display.
    var restSize: CGSize {
        hasNotch ? CGSize(width: notchWidth, height: bandHeight) : CGSize(width: compactWidth, height: 0)
    }

    /// Drops emerge from and disappear into the bottom center of the camera
    /// housing. Without a notch, they use the screen's top-center edge.
    func dropOrigin(centerX: CGFloat) -> CGPoint {
        CGPoint(x: centerX, y: hasNotch ? bandHeight : 0)
    }

    func expandedWidth(_ metrics: NotchPillMetrics) -> CGFloat {
        max(metrics.islandWidth, compactWidth + 40)
    }
}

/// The notch outline: square top edge flush with the screen, concave
/// "shoulders" flaring into the top edge at both top corners (the way the
/// hardware notch meets the bezel), and rounded bottom corners. The shoulders
/// draw OUTSIDE `rect` so the rect stays the island's body.
struct NotchIslandShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let top = max(0, min(topRadius, rect.height / 2))
        let bottom = max(0, min(bottomRadius, rect.height - top, rect.width / 2))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX - top, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY + top),
                          control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - bottom))
        path.addQuadCurve(to: CGPoint(x: rect.minX + bottom, y: rect.maxY),
                          control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - bottom, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY - bottom),
                          control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + top))
        path.addQuadCurve(to: CGPoint(x: rect.maxX + top, y: rect.minY),
                          control: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Controller

/// What the island itself is showing; a match card wins over the compact pin.
/// Event drops aren't a mode: they split off the notch as their own bars
/// (`NotchDropsLayer`) beneath whatever the island shows.
enum IslandMode: Equatable {
    /// Nothing: the island is the hardware notch (and its panel is hidden).
    case rest
    /// A pinned match, in the menu bar beside the notch: score left, clock right.
    case compact(Int)
    /// One match opened up: scoreline, status and its latest events.
    case card(Int)
}

/// The notch island: the notch itself grows sideways to hold a pinned score
/// and down to show a match card, then shrinks back into the hardware. Event
/// drops split off the notch as separate black bars in the same panel.
///
/// One panel, fixed size, at the top-center of the display chosen in
/// Settings; everything inside it animates. The panel only takes the mouse
/// while the pointer is over the island — everywhere else, drops included,
/// clicks fall through to whatever is underneath.
///
/// Holds one match at a time; pinning another replaces it. Floating capsules
/// (`PinnedCapsuleManager`) are the way to watch several matches at once.
@MainActor
final class NotchIsland: ObservableObject {
    static let shared = NotchIsland()

    /// The match pinned to the notch.
    @Published private(set) var pinnedFixtureId: Int?
    /// The match whose card is open.
    @Published private(set) var cardFixtureId: Int?

    /// Fixed panel size: room for the widest, tallest content (a large-size
    /// card, or a full set of long drops) plus shoulders and shadow.
    static let panelSize = CGSize(width: 760, height: 600)
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.8)

    private var panel: NSPanel?
    private var dropsShowing = false
    /// The island body's size as last laid out (shoulders excluded).
    private var islandSize: CGSize = .zero
    private var hovering = false
    private var mouseMonitors: [Any] = []
    private var cancellables: Set<AnyCancellable> = []
    private var collapseWork: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?
    private var displayObserver: NSObjectProtocol?

    private init() {
        OverlayManager.shared.$activeSet
            .map { !$0.isEmpty }
            .removeDuplicates()
            .sink { [weak self] showing in
                MainActor.assumeIsolated { self?.dropsChanged(showing) }
            }
            .store(in: &cancellables)
        AppSession.shared.$fixtures
            .sink { [weak self] fixtures in
                MainActor.assumeIsolated { self?.fixturesChanged(fixtures) }
            }
            .store(in: &cancellables)
        displayObserver = NotificationCenter.default.addObserver(
            forName: .overlayDisplayTargetDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.displayTargetDidChange() }
        }
    }

    func isPinned(_ fixtureId: Int) -> Bool { pinnedFixtureId == fixtureId }

    /// The one place the menu, the card and the context menu funnel through,
    /// so analytics live here.
    func toggle(fixtureId: Int) {
        if isPinned(fixtureId) {
            AppAnalytics.notchUnpinned(fixtureId: fixtureId)
            unpin()
        } else {
            AppAnalytics.notchPinned(fixtureId: fixtureId)
            pin(fixtureId)
        }
    }

    private func pin(_ fixtureId: Int) {
        withAnimation(Self.spring) { pinnedFixtureId = fixtureId }
        AppLog.info(.app, "notch_pinned fixture_id=\(fixtureId)")
        refresh()
    }

    private func unpin() {
        guard let fixtureId = pinnedFixtureId else { return }
        withAnimation(Self.spring) {
            pinnedFixtureId = nil
            if cardFixtureId == fixtureId { cardFixtureId = nil }
        }
        AppLog.info(.app, "notch_unpinned fixture_id=\(fixtureId)")
        refresh()
    }

    /// Open a match's card. If drops are showing, the set ends first so the
    /// card has the space under the notch to itself.
    func openCard(_ fixtureId: Int, source: String) {
        guard AppSession.shared.fixtures.contains(where: { $0.fixtureId == fixtureId }) else { return }
        AppAnalytics.notchCardOpened(fixtureId: fixtureId, source: source)
        if dropsShowing { OverlayManager.shared.endSet() }
        collapseWork?.cancel()
        withAnimation(Self.spring) { cardFixtureId = fixtureId }
        refresh()
    }

    func closeCard() {
        collapseWork?.cancel()
        guard cardFixtureId != nil else { return }
        withAnimation(Self.spring) { cardFixtureId = nil }
        refresh()
    }

    /// Called as a set is picked, before its drops land. Touching `shared`
    /// is the point: it makes sure the island exists and is subscribed to
    /// `activeSet` before the first drop is appended.
    func setWillShow() {}

    /// Reported by the island view after each layout.
    func islandSizeChanged(_ size: CGSize) {
        islandSize = size
        trackPointer()
    }

    // MARK: State

    private var isResting: Bool { !dropsShowing && cardFixtureId == nil && pinnedFixtureId == nil }

    private func dropsChanged(_ showing: Bool) {
        dropsShowing = showing
        // A new set takes over the island from an open card.
        if showing { closeCardImmediately() }
        refresh()
    }

    private func closeCardImmediately() {
        collapseWork?.cancel()
        cardFixtureId = nil
    }

    /// Retire a pin or card whose match rolled out of today's list. An empty
    /// list is a reload in flight, not every match vanishing.
    private func fixturesChanged(_ fixtures: [Fixture]) {
        guard !fixtures.isEmpty else { return }
        let ids = Set(fixtures.map(\.fixtureId))
        if let cardFixtureId, !ids.contains(cardFixtureId) { closeCardImmediately() }
        if let pinnedFixtureId, !ids.contains(pinnedFixtureId) {
            self.pinnedFixtureId = nil
            AppLog.info(.app, "notch_unpinned fixture_id=\(pinnedFixtureId) reason=gone")
        }
        refresh()
    }

    /// Show the panel whenever the island has anything to show; hide it once
    /// the island has shrunk back into the notch.
    private func refresh() {
        hideWork?.cancel()
        if isResting {
            panel?.ignoresMouseEvents = true
            setHovering(false)
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.isResting else { return }
                self.panel?.orderOut(nil)
            }
            hideWork = work
            // Long enough for the spring to settle back into the notch.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
        } else {
            showPanel()
        }
    }

    // MARK: Pointer

    /// Monitors (not tracking areas) follow the pointer, because the panel
    /// ignores the mouse until the pointer is over the island — and a window
    /// that ignores the mouse gets no tracking events.
    private func installMouseMonitors() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseUp]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.trackPointer() }
        }) {
            mouseMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.trackPointer() }
            return event
        }) {
            mouseMonitors.append(local)
        }
    }

    private func trackPointer() {
        guard let panel, panel.isVisible, !isResting,
              let screen = OverlayDisplayTarget.shared.selectedScreen else {
            setHovering(false)
            return
        }
        let island = CGRect(
            x: screen.frame.midX - islandSize.width / 2,
            y: screen.frame.maxY - islandSize.height,
            width: islandSize.width,
            height: islandSize.height
        )
        let inside = island.contains(NSEvent.mouseLocation)
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        setHovering(inside)
    }

    /// An open card folds back up shortly after the pointer leaves it.
    private func setHovering(_ inside: Bool) {
        guard inside != hovering else { return }
        hovering = inside
        collapseWork?.cancel()
        guard !inside, cardFixtureId != nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.closeCard() }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    // MARK: Panel

    private func showPanel() {
        guard let screen = OverlayDisplayTarget.shared.selectedScreen else { return }
        if panel == nil {
            panel = makePanel()
            installMouseMonitors()
        }
        guard let panel else { return }
        let frame = frame(on: screen)
        // `refresh` runs on every poll; only move the panel when it must.
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func frame(on screen: NSScreen) -> CGRect {
        let size = Self.panelSize
        return CGRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                      width: size.width, height: size.height).integral
    }

    private func displayTargetDidChange() {
        guard let panel else { return }
        guard let screen = OverlayDisplayTarget.shared.selectedScreen else {
            panel.orderOut(nil)
            return
        }
        panel.setFrame(frame(on: screen), display: true)
        if !isResting { panel.orderFrontRegardless() }
    }

    private func makePanel() -> NSPanel {
        let panel = IslandPanel(
            contentRect: CGRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The island draws its own shadow; AppKit's would outline the panel.
        panel.hasShadow = false
        panel.level = OverlayWindow.level
        panel.collectionBehavior = OverlayWindow.collectionBehavior
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = true
        panel.sharingType = .readOnly
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        // The island is the notch: always black, whatever the app's theme.
        panel.appearance = NSAppearance(named: .darkAqua)

        let hostingView = IslandHostingView(rootView: NotchIslandRoot().environmentObject(AppSession.shared))
        // The panel's frame is ours and fixed; never let the hosting view
        // drive window constraints off the animating island.
        hostingView.sizingOptions = []
        // The panel overlaps the notch, so macOS gives it a top safe-area
        // inset the notch's height — and SwiftUI would push the island down
        // below the notch. The island must start at the screen's top edge.
        hostingView.safeAreaRegions = []
        panel.contentView = hostingView
        return panel
    }
}

/// AppKit may nudge a window's frame off the menu bar / notch area; the
/// island has to sit flush with the screen's top edge.
private final class IslandPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Takes the first click even though the panel never becomes key, so a
/// single click on the island acts.
private final class IslandHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Views

private struct NotchIslandRoot: View {
    var body: some View {
        ZStack(alignment: .top) {
            NotchDropsLayer()
            // Above the drops, so a neck passing up into the notch never
            // covers the pinned score.
            NotchIslandView()
        }
        .coordinateSpace(name: NotchDropsLayer.space)
        .frame(width: NotchIsland.panelSize.width, height: NotchIsland.panelSize.height, alignment: .top)
            .ignoresSafeArea()
            .environment(\.colorScheme, .dark)
    }
}

private struct NotchIslandView: View {
    @ObservedObject private var island = NotchIsland.shared
    @ObservedObject private var capsules = PinnedCapsuleManager.shared
    @ObservedObject private var displayTarget = OverlayDisplayTarget.shared
    @EnvironmentObject private var session: AppSession

    private var mode: IslandMode {
        if let id = island.cardFixtureId, fixture(id) != nil { return .card(id) }
        if let id = island.pinnedFixtureId, fixture(id) != nil { return .compact(id) }
        return .rest
    }

    var body: some View {
        let geometry = NotchGeometry(screen: displayTarget.selectedScreen)
        let metrics = NotchPillMetrics(session.prefs.settings.notchDropSize ?? .medium)
        let mode = mode
        let shape = shape(mode, geometry, metrics)
        content(mode, geometry, metrics)
            .frame(width: width(mode, geometry, metrics), height: height(mode, geometry), alignment: .top)
            .background(shape.fill(Color.black))
            .clipShape(shape)
            .shadow(color: .black.opacity(isDropped(mode) ? 0.45 : 0), radius: 16, y: 8)
            .contentShape(shape)
            .onTapGesture { tapped(mode) }
            .contextMenu { contextMenu(mode) }
            .onGeometryChange(for: CGSize.self, of: \.size) { size in
                DispatchQueue.main.async { NotchIsland.shared.islandSizeChanged(size) }
            }
            .animation(NotchIsland.spring, value: mode)
            .respectReducedMotion()
    }

    // MARK: Shape per mode

    private func isDropped(_ mode: IslandMode) -> Bool {
        switch mode {
        case .card: true
        case .rest, .compact: false
        }
    }

    private func width(_ mode: IslandMode, _ geometry: NotchGeometry, _ metrics: NotchPillMetrics) -> CGFloat {
        switch mode {
        case .rest: geometry.restSize.width
        case .compact: geometry.compactWidth
        case .card: geometry.expandedWidth(metrics)
        }
    }

    /// nil = the content's own height (a card grows with what it holds).
    private func height(_ mode: IslandMode, _ geometry: NotchGeometry) -> CGFloat? {
        switch mode {
        case .rest: geometry.restSize.height
        case .compact: geometry.bandHeight
        case .card: nil
        }
    }

    private func shape(_ mode: IslandMode, _ geometry: NotchGeometry, _ metrics: NotchPillMetrics) -> NotchIslandShape {
        switch mode {
        case .rest:
            // The hardware notch's own corners, so the shrink lands seamlessly.
            NotchIslandShape(topRadius: geometry.hasNotch ? 6 : 0, bottomRadius: geometry.hasNotch ? 9 : 0)
        case .compact:
            NotchIslandShape(topRadius: 6, bottomRadius: min(10, geometry.bandHeight / 2))
        case .card:
            NotchIslandShape(topRadius: 12, bottomRadius: metrics.corner)
        }
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ mode: IslandMode, _ geometry: NotchGeometry, _ metrics: NotchPillMetrics) -> some View {
        switch mode {
        case .rest:
            Color.clear
        case let .compact(id):
            if let fixture = fixture(id) {
                CompactIsland(fixture: fixture, geometry: geometry)
                    .transition(.opacity)
            }
        case let .card(id):
            if let fixture = fixture(id) {
                IslandMatchCard(fixture: fixture, geometry: geometry, metrics: metrics)
                    .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .top)))
            }
        }
    }

    private func tapped(_ mode: IslandMode) {
        switch mode {
        case let .compact(id): island.openCard(id, source: "pin")
        case .card: island.closeCard()
        case .rest: break
        }
    }

    @ViewBuilder
    private func contextMenu(_ mode: IslandMode) -> some View {
        switch mode {
        case let .compact(id), let .card(id):
            if case .card = mode {
                Button("Close") { island.closeCard() }
            } else {
                Button("Show match") { island.openCard(id, source: "pin") }
            }
            Button(capsules.isPinned(id) ? "Stop floating" : "Float on screen") {
                capsules.toggle(fixtureId: id)
            }
            if island.isPinned(id) {
                Button("Unpin from notch") { island.toggle(fixtureId: id) }
            } else {
                Button("Pin to notch") { island.toggle(fixtureId: id) }
            }
        case .rest:
            EmptyView()
        }
    }

    private func fixture(_ id: Int) -> Fixture? {
        session.fixtures.first { $0.fixtureId == id }
    }
}

/// The pinned match, beside the notch: both crests and the score in the
/// left ear, the clock in the right. Sized to the menu bar, not the setting.
private struct CompactIsland: View {
    let fixture: Fixture
    let geometry: NotchGeometry
    @EnvironmentObject private var session: AppSession

    var body: some View {
        let font = min(13, geometry.bandHeight * 0.42)
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                CachedTeamLogo(url: logo(fixture.home.id), size: font + 3)
                Text(fixture.status == "SCHEDULED" ? "vs" : fixture.scorelineText)
                    .font(.system(size: font, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.spring, value: fixture.scorelineText)
                    .lineLimit(1)
                    .fixedSize()
                CachedTeamLogo(url: logo(fixture.away.id), size: font + 3)
            }
            .frame(width: NotchGeometry.earWidth)
            Color.clear.frame(width: geometry.gap)
            IslandClock(fixture: fixture, fontSize: font - 1)
                .frame(width: NotchGeometry.earWidth)
        }
        .foregroundStyle(.white)
        .frame(height: geometry.bandHeight)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Click for the match. Right-click for options.")
    }

    private func logo(_ id: Int) -> String {
        TeamCatalog.team(for: id, in: session.allTeams).logo
    }
}

/// The match clock in island form: a live dot + minute, FT, or the kickoff
/// time. Short enough for an ear (no "Updates delayed" text — a stale feed
/// just greys the dot).
private struct IslandClock: View {
    let fixture: Fixture
    let fontSize: CGFloat
    @EnvironmentObject private var session: AppSession

    var body: some View {
        Group {
            if fixture.isLive {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let current = session.liveScoreStatus(fixture.fixtureId, at: context.date) == .current
                    HStack(spacing: 4) {
                        Circle().fill(current ? Color.red : Color.gray).frame(width: 6, height: 6)
                        Text(fixture.liveMinuteText(
                            localElapsed: LiveStore.shared.localElapsedSeconds(fixture.fixtureId, at: context.date)
                        ))
                        .foregroundStyle(current ? Color.red : Color.secondary)
                        .monospacedDigit()
                    }
                }
            } else if fixture.status == "FINISHED" {
                Text("FT").foregroundStyle(.green)
            } else if let kickoff = fixture.kickoff {
                Text(kickoff, style: .time).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: fontSize, weight: .semibold, design: .rounded))
        .lineLimit(1)
        .fixedSize()
    }
}

/// One match, opened up under the notch: crests and names either side of a
/// big score, the clock and competition, its latest events, and the pin /
/// float controls.
private struct IslandMatchCard: View {
    let fixture: Fixture
    let geometry: NotchGeometry
    let metrics: NotchPillMetrics
    @EnvironmentObject private var session: AppSession
    @ObservedObject private var island = NotchIsland.shared
    @ObservedObject private var capsules = PinnedCapsuleManager.shared

    /// The most recent events; the menu has the full timeline.
    private static let eventLimit = 6

    var body: some View {
        let rows = Array(capsuleTimeline(for: fixture).suffix(Self.eventLimit))
        VStack(spacing: metrics.rowSpacing) {
            HStack(alignment: .center, spacing: 8) {
                team(fixture.home)
                Text(fixture.status == "SCHEDULED" ? "vs" : fixture.scorelineText)
                    .font(.system(size: metrics.title * 2, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.spring, value: fixture.scorelineText)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(maxWidth: .infinity)
                team(fixture.away)
            }
            HStack(spacing: 6) {
                IslandClock(fixture: fixture, fontSize: metrics.subtitle)
                if let text = [session.leagueName(for: fixture.leagueId), fixture.stageLabel]
                    .compactMap({ $0 }).joined(separator: " · ").trimmedNonEmpty {
                    Text(text)
                        .font(.system(size: metrics.subtitle, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if !rows.isEmpty {
                Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1)
                VStack(alignment: .leading, spacing: metrics.rowSpacing / 2) {
                    ForEach(rows) { IslandTimelineLine(row: $0, fontSize: metrics.subtitle + 1) }
                }
            }
            HStack(spacing: 8) {
                Spacer()
                IslandButton(
                    title: island.isPinned(fixture.fixtureId) ? "Unpin" : "Pin to notch",
                    icon: island.isPinned(fixture.fixtureId) ? "pin.slash" : "pin",
                    fontSize: metrics.subtitle
                ) { island.toggle(fixtureId: fixture.fixtureId) }
                IslandButton(
                    title: capsules.isPinned(fixture.fixtureId) ? "Stop floating" : "Float",
                    icon: "pip",
                    fontSize: metrics.subtitle
                ) { capsules.toggle(fixtureId: fixture.fixtureId) }
            }
        }
        .foregroundStyle(.white)
        .padding(.top, geometry.bandHeight + 6)
        .padding(.horizontal, metrics.hPad)
        .padding(.bottom, metrics.vPad)
    }

    private func team(_ team: ScoreboardTeam) -> some View {
        VStack(spacing: 4) {
            CachedTeamLogo(url: TeamCatalog.team(for: team.id, in: session.allTeams).logo, size: metrics.disc)
            Text(team.name)
                .font(.system(size: metrics.subtitle + 1, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(width: metrics.islandWidth * 0.3)
    }
}

/// One past event in the card: minute, team crest, icon, what, who.
private struct IslandTimelineLine: View {
    let row: CapsuleTimelineRow
    let fontSize: CGFloat
    @EnvironmentObject private var session: AppSession

    var body: some View {
        HStack(spacing: 6) {
            Text(row.minuteText)
                .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: fontSize * 3, alignment: .trailing)
            if let teamId = row.teamId {
                CachedTeamLogo(url: TeamCatalog.team(for: teamId, in: session.allTeams).logo, size: fontSize + 2)
            } else {
                Color.clear.frame(width: fontSize + 2, height: fontSize + 2)
            }
            Image(systemName: row.icon)
                .font(.system(size: fontSize - 1, weight: .semibold))
                .foregroundStyle(row.disallowed ? Color.secondary : (row.color == .primary ? .white : row.color))
                .frame(width: fontSize + 4)
            Text(row.label)
                .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                .strikethrough(row.disallowed)
            if let text = row.text {
                Text(text)
                    .font(.system(size: fontSize, design: .rounded))
                    .foregroundStyle(.secondary)
                    .strikethrough(row.disallowed)
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
    }
}

/// A small pill button on the black island.
private struct IslandButton: View {
    let title: String
    let icon: String
    let fontSize: CGFloat
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.white.opacity(hovering ? 0.22 : 0.12)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
