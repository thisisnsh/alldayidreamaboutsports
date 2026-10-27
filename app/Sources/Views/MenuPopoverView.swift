import SwiftUI

/// The popover's pages. After onboarding the popover is the whole app:
/// matches, teams and settings all live in it, and nothing opens a window.
enum PopoverPage {
    case home, teams, settings
}

/// Which popover page is showing. A shared object rather than view state so
/// AppKit entry points (the right-click menu, ⌘,) can navigate too.
@MainActor
final class PopoverRouter: ObservableObject {
    static let shared = PopoverRouter()

    @Published private(set) var page: PopoverPage = .home
    /// Whether the last move went deeper, so the slide runs the matching way.
    @Published private(set) var forward = true
    /// The home header is asking "Quit the app?" in place of its controls.
    @Published var confirmingQuit = false
    /// The day the home page lists: -1 yesterday, 0 today, 1 tomorrow. Every
    /// open starts back on today.
    @Published var dayOffset = 0

    func go(_ page: PopoverPage) {
        guard page != self.page else { return }
        confirmingQuit = false
        forward = page != .home
        withAnimation(.easeOut(duration: 0.2)) { self.page = page }
        switch page {
        case .home:
            AppAnalytics.screenView(MenuPopoverView.screen)
        case .teams:
            AppAnalytics.teamPickerOpened()
            AppAnalytics.screenView(TeamsPage.screen)
            Task { await AppSession.shared.refreshCatalog() }
        case .settings:
            AppAnalytics.settingsOpened()
            AppAnalytics.screenView(SettingsPage.screen)
        }
    }

    /// Ask before quitting: brings up the home header's confirmation. Inline
    /// rather than an alert — an alert window takes focus and the transient
    /// popover would close underneath it.
    func askToQuit() {
        go(.home)
        withAnimation(.easeOut(duration: 0.15)) { confirmingQuit = true }
    }

    /// Jump without animation — used just before the popover shows, so it
    /// never opens mid-slide.
    func reset(to page: PopoverPage = .home) {
        confirmingQuit = false
        dayOffset = 0
        forward = true
        self.page = page
    }
}

/// The menu bar popover: a fixed-size frame that swaps between pages. One size
/// for every page: resizing a shown NSPopover shakes everything in it, so home
/// fills its spare room with placeholder rows instead of shrinking.
struct MenuPopoverView: View {
    @EnvironmentObject var session: AppSession
    @ObservedObject private var router = PopoverRouter.shared
    /// The analytics screen name for the home page. The `screen_view` itself is
    /// fired by `MenuPopoverController.showMenu()` — the hosting controller is
    /// built once and reused, so `.onAppear` here would only fire once a launch.
    static let screen = "menu"
    static let width: CGFloat = 360
    static let height: CGFloat = 540

    var body: some View {
        ZStack {
            switch router.page {
            case .home: HomePage().transition(slide)
            case .teams: TeamsPage().transition(slide)
            case .settings: SettingsPage().transition(slide)
            }
        }
        #if os(macOS)
        .frame(width: Self.width, height: Self.height)
        #else
        .frame(maxWidth: 680, maxHeight: .infinity)
        #endif
        .clipped()
        .background(AppBackground())
        .appTheme(session.prefs.settings.theme ?? .system)
        .respectReducedMotion()
    }

    private var slide: AnyTransition {
        .asymmetric(
            insertion: .move(edge: router.forward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: router.forward ? .leading : .trailing).combined(with: .opacity)
        )
    }
}

/// Header of a pushed page: a back button to the matches, the page title
/// centered, and an optional control on the right.
struct PageHeader<Trailing: View>: View {
    let title: String
    /// A tap on the title. Unmarked on purpose: Settings counts these to
    /// unlock the demo (see `DemoMode`).
    var onTitleTap: (() -> Void)? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        ZStack {
            Text(title).font(.system(size: 15, weight: .bold, design: .rounded))
                .contentShape(Rectangle())
                .onTapGesture { onTitleTap?() }
            HStack {
                Button {
                    PopoverRouter.shared.go(.home)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        Text("Matches")
                    }
                    .font(.system(size: 13))
                }
                .buttonStyle(.hoverHighlight)
                Spacer()
                // Lines up with the 16pt inset of the pages' content; the back
                // button gets its inset from its own hover pad.
                trailing.padding(.trailing, 8)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, onTitleTap: (() -> Void)? = nil) {
        self.init(title: title, onTitleTap: onTitleTap) { EmptyView() }
    }
}

/// A bare SF Symbol button for the popover's toolbars.
struct ToolbarIconButton: View {
    let symbol: String
    let help: String
    var size: CGFloat = 14
    let action: () -> Void
    @State private var hovering = false
    private var toolbarHeight: CGFloat {
        #if os(iOS)
        44
        #else
        26
        #endif
    }
    private var toolbarTarget: CGFloat {
        #if os(iOS)
        44
        #else
        28
        #endif
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: size < 14 ? .semibold : .regular))
                .frame(width: toolbarTarget, height: toolbarHeight)
                .background(
                    RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(hovering ? 0.1 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// One day's matches for the followed teams (today by default; the header's
/// arrows step to yesterday and tomorrow), grouped by state, with those teams
/// along the bottom.
struct HomePage: View {
    @EnvironmentObject var session: AppSession
    @ObservedObject private var router = PopoverRouter.shared
    /// The one row (or Now card) showing its timeline.
    @State private var expanded: Int?
    /// The match list's visible height and its matches' height, for how many
    /// placeholder rows fill the space under them.
    @State private var viewportHeight: CGFloat = 0
    @State private var listHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            fixturesList
            Divider()
            followingFooter
        }
    }

    private var header: some View {
        headerControls
    }

    private var headerControls: some View {
        HStack(spacing: 6) {
            if router.confirmingQuit {
                quitConfirmation
            } else {
                daySwitcher
                Spacer()
                ToolbarIconButton(symbol: "gearshape", help: "Settings") { router.go(.settings) }
                #if os(macOS)
                ToolbarIconButton(symbol: "power", help: "Quit") { router.askToQuit() }
                #endif
            }
        }
        // Same height either way, so confirming never resizes the popover.
        #if os(iOS)
        .frame(minHeight: 44)
        #else
        .frame(height: 26)
        #endif
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    /// `‹ Today ›`: steps one day back or forward, no further.
    private var daySwitcher: some View {
        HStack(spacing: 0) {
            dayArrow(-1, symbol: "chevron.left", help: "Previous day")
            Text(Self.dayTitle(router.dayOffset))
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .frame(minWidth: 84)
                .contentTransition(.opacity)
            dayArrow(1, symbol: "chevron.right", help: "Next day")
        }
        // The arrow's hover pad sits in the list's 16pt inset.
        .padding(.leading, -8)
    }

    private func dayArrow(_ step: Int, symbol: String, help: String) -> some View {
        let target = router.dayOffset + step
        let enabled = (-1 ... 1).contains(target)
        return ToolbarIconButton(symbol: symbol, help: help, size: 12) {
            expanded = nil
            withAnimation(.easeOut(duration: 0.15)) { router.dayOffset = target }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
    }

    static func dayTitle(_ offset: Int) -> String {
        switch offset {
        case -1: "Yesterday"
        case 1: "Tomorrow"
        default: "Today"
        }
    }

    /// Replaces the header's controls until answered. Return quits, Esc
    /// cancels.
    @ViewBuilder private var quitConfirmation: some View {
        // Shared baseline: centered on its own, the smaller text sits high.
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Quit the app?").font(.system(size: 13, weight: .semibold))
            Text("Alerts will stop.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        Spacer(minLength: 4)
        Button("Cancel") {
            withAnimation(.easeOut(duration: 0.15)) { router.confirmingQuit = false }
        }
        .buttonStyle(.hoverHighlight)
        .keyboardShortcut(.cancelAction)
        Button {
            AppAnalytics.appQuit(source: "menu")
            #if os(macOS)
            NSApp.terminate(nil)
            #endif
        } label: {
            Text("Quit").fontWeight(.semibold).foregroundStyle(.red)
        }
        .buttonStyle(.hoverHighlight)
        .keyboardShortcut(.defaultAction)
    }

    @ViewBuilder private var fixturesList: some View {
        if shownFixtures.isEmpty {
            VStack(spacing: 10) {
                if session.fanTeamIds.isEmpty {
                    Image(systemName: "heart.circle").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("Follow a team to see its matches").font(.system(size: 13, weight: .medium))
                    Button("Choose teams") { PopoverRouter.shared.go(.teams) }
                        .buttonStyle(.cardButton)
                } else if session.scheduleState == .loading {
                    ProgressView().controlSize(.small)
                    Text("Loading matches…").font(.system(size: 13)).foregroundStyle(.secondary)
                } else if session.scheduleState == .unavailable {
                    Image(systemName: "wifi.exclamationmark").font(.system(size: 24)).foregroundStyle(.secondary)
                    Text("Couldn't load matches").font(.system(size: 13, weight: .medium))
                    retryButton
                } else {
                    Text(emptyMessage).font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            // The rest of the menu reads as a match list waiting to fill.
            VStack(spacing: PlaceholderRow.spacing) {
                ForEach(0..<Self.placeholderLimit, id: \.self) { PlaceholderRow(index: $0) }
            }
            .padding(.horizontal, 8)
            // minHeight 0: without it the frame grows to all 12 rows, pushing
            // the header and footer out of the fixed-size popover.
            .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
            .clipped()
            .mask(Self.bottomFade)
        } else {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 12) {
                        fixtureSection("Live", fixtures: shownFixtures.filter { $0.isLive }, liveCards: true)
                        fixtureSection("Upcoming", fixtures: shownFixtures.filter {
                            !$0.isLive && $0.status != "FINISHED" && !$0.isCalledOff && ($0.kickoff ?? .distantPast) > Date()
                        })
                        fixtureSection("Finished", fixtures: shownFixtures.filter { $0.status == "FINISHED" })
                        fixtureSection("Match updates", fixtures: shownFixtures.filter {
                            !$0.isLive && $0.status != "FINISHED" && ($0.isCalledOff || ($0.kickoff ?? .distantPast) <= Date())
                        })
                    }
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { listHeight = $0 }
                    .padding(.horizontal, 8)
                    .padding(.top, Self.fadeHeight)
                    // Spare room under the matches holds placeholder rows, never
                    // enough to make the list scroll.
                    VStack(spacing: PlaceholderRow.spacing) {
                        ForEach(0..<placeholderCount, id: \.self) { PlaceholderRow(index: $0) }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, placeholderCount > 0 ? 12 : 0)
                    .padding(.bottom, Self.fadeHeight)
                }
            }
            .onGeometryChange(for: CGFloat.self, of: \.size.height) { viewportHeight = $0 }
            .mask(
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: Self.fadeHeight)
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: Self.fadeHeight)
                }
            )
            .frame(maxHeight: .infinity)
        }
    }

    @ViewBuilder private func fixtureSection(_ title: String, fixtures: [Fixture], liveCards: Bool = false) -> some View {
        if !fixtures.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .accessibilityAddTraits(.isHeader)
                ForEach(fixtures) { fixture in
                    if liveCards {
                        NowCard(fixture: fixture, expanded: $expanded)
                    } else {
                        FixtureRow(fixture: fixture, pinnable: router.dayOffset == 0, expanded: $expanded)
                    }
                }
            }
        }
    }

    private var retryButton: some View {
        Button("Try again") { Task { await session.refreshFixtures() } }
            .buttonStyle(.cardButton)
            .disabled(session.isRefreshingFixtures)
    }

    private static let fadeHeight: CGFloat = 10
    private static let placeholderLimit = 12

    private static let bottomFade = LinearGradient(
        stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.6), .init(color: .clear, location: 1)],
        startPoint: .top, endPoint: .bottom
    )

    /// Placeholder rows that fit under the matches without overflowing.
    private var placeholderCount: Int {
        let spare = viewportHeight - listHeight - 2 * Self.fadeHeight - 12
        let rows = Int((spare + PlaceholderRow.spacing) / (PlaceholderRow.height + PlaceholderRow.spacing))
        return min(Self.placeholderLimit, max(0, rows))
    }

    private var shownFixtures: [Fixture] { session.fixtures(dayOffset: router.dayOffset) }

    /// Nothing to list: either football is off entirely that day, or it's on
    /// but none of it is theirs.
    private var emptyMessage: String {
        let any = session.hasFixtures(dayOffset: router.dayOffset)
        switch router.dayOffset {
        case -1: return any ? "None of your teams played yesterday" : "No matches yesterday"
        case 1: return any ? "None of your teams play tomorrow" : "No matches tomorrow"
        default: return any ? "None of your teams play today 💤" : "No matches today — rest day ☁️"
        }
    }

    /// The followed teams, doubling as the way into Teams.
    private var followingFooter: some View {
        Button {
            PopoverRouter.shared.go(.teams)
        } label: {
            HStack(spacing: 8) {
                let fans = session.fanTeams
                if fans.isEmpty {
                    Image(systemName: "heart.circle.fill").font(.system(size: 16))
                    Text("Follow your teams")
                } else {
                    HStack(spacing: -3) {
                        ForEach(fans.prefix(6)) { team in
                            CachedTeamLogo(url: team.logo, size: 18)
                        }
                    }
                    Text("Following \(fans.count) \(fans.count == 1 ? "team" : "teams")")
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).opacity(0.5)
            }
            .font(.system(size: 12, weight: .medium))
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverHighlight)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

/// A compact two-or-more segment switch for a header row ("All |
/// Following"). Hand-rolled rather than
/// `.pickerStyle(.segmented)`: at caption size AppKit's segmented control
/// brings chrome (and a fixed height) far too heavy for a menu row.
struct PillPicker<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let label: (Option) -> String
    var onSelect: (Option) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                Segment(title: label(option), selected: selection == option) {
                    onSelect(option)
                    withAnimation(.easeOut(duration: 0.15)) { selection = option }
                }
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06))
        )
    }

    private struct Segment: View {
        let title: String
        let selected: Bool
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                Text(title)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .opacity(selected ? 1 : 0.6)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.primary.opacity(selected ? 0.12 : (hovering ? 0.06 : 0)))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityValue(selected ? "Selected" : "Not selected")
        }
    }
}

/// The followed match being played right now: a big scoreline, the latest
/// events, and the pin. Expands to the full timeline.
private struct NowCard: View {
    let fixture: Fixture
    @Binding var expanded: Int?
    @EnvironmentObject var session: AppSession

    private var isExpanded: Bool { expanded == fixture.fixtureId }

    var body: some View {
        let timeline = capsuleTimeline(for: fixture)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                LiveMatchStatus(fixture: fixture)
                Spacer()
                if let league = session.leagueName(for: fixture.leagueId) {
                    Text(league).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            teamLine(fixture.home, goals: fixture.home.goals, other: fixture.away.goals)
            teamLine(fixture.away, goals: fixture.away.goals, other: fixture.home.goals)
            TimelineView(.periodic(from: .now, by: 5)) { context in
                if session.liveScoreStatus(fixture.fixtureId, at: context.date) != .current {
                    HStack {
                        Text("Showing the last known score")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Retry") { Task { await session.refreshFixtures() } }
                            .buttonStyle(.cardButton)
                            .disabled(session.isRefreshingFixtures)
                    }
                }
            }
            if let pens = fixture.shootout {
                Text("Penalties \(pens.home) – \(pens.away)").font(.system(size: 11, weight: .semibold)).opacity(0.7)
            }

            let shownEvents = isExpanded ? timeline : Array(timeline.suffix(3))
            if !shownEvents.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(shownEvents) { TimelineEventLine(row: $0) }
                }
            }

            HStack(spacing: 8) {
                PinButtons(fixtureId: fixture.fixtureId)
                if timeline.count > 3 {
                    Button(isExpanded ? "Hide timeline" : "Full timeline") {
                        withAnimation(.easeOut(duration: 0.15)) {
                            expanded = isExpanded ? nil : fixture.fixtureId
                        }
                    }
                    .buttonStyle(.hoverHighlight)
                    .font(.system(size: 12))
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.06)))
    }

    private func teamLine(_ team: ScoreboardTeam, goals: Int, other: Int) -> some View {
        HStack(spacing: 10) {
            CachedTeamLogo(url: TeamCatalog.team(for: team.id, in: session.allTeams).logo, size: 24)
            Text(team.name).font(.system(size: 15, weight: .bold, design: .rounded)).lineLimit(1)
            Spacer()
            Text("\(goals)")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.spring, value: goals)
        }
        // The side that's behind reads quieter.
        .opacity(goals < other ? 0.7 : 1)
    }
}

/// Keeps a match on screen: a pinned capsule in any corner, any number at once.
private struct PinButtons: View {
    let fixtureId: Int
    @ObservedObject private var capsules = PinnedCapsuleManager.shared

    var body: some View {
        let pinned = capsules.isPinned(fixtureId)
        Button {
            capsules.toggle(fixtureId: fixtureId)
        } label: {
            #if os(iOS)
            Label(pinned ? "Unpin" : "Pin to Lock Screen", systemImage: pinned ? "pin.slash" : "pin.fill")
            #else
            Label(pinned ? "Unpin" : "Pin to screen", systemImage: pinned ? "pin.slash" : "pin.fill")
            #endif
        }
        .buttonStyle(.cardButton)
        .help(pinned ? "Close the pinned score" : "Pin the score in a corner of the screen")
    }
}

/// One event in a match timeline, for the popover: minute, team, what, who.
/// The capsule's timeline (`capsuleTimeline`) is the source, so the two agree.
private struct TimelineEventLine: View {
    let row: CapsuleTimelineRow
    @EnvironmentObject var session: AppSession

    var body: some View {
        HStack(spacing: 6) {
            Text(row.minuteText)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .frame(width: 44, alignment: .trailing)
            if let teamId = row.teamId {
                CachedTeamLogo(url: TeamCatalog.team(for: teamId, in: session.allTeams).logo, size: 12)
            } else {
                Color.clear.frame(width: 12, height: 12)
            }
            Image(systemName: row.icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(row.disallowed ? Color.secondary : row.color)
                .frame(width: 14)
            Text(row.label)
                .font(.system(size: 12, weight: .semibold))
                .strikethrough(row.disallowed)
                .fixedSize()
            if let text = row.text {
                Text(text).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail).strikethrough(row.disallowed)
            }
            Spacer(minLength: 0)
        }
    }
}

/// A grey stand-in shaped like a `FixtureRow` — crests, names, score, time
/// and the competition line — filling the menu's spare room. Each row fades a
/// little more than the one above.
private struct PlaceholderRow: View {
    let index: Int
    static let height: CGFloat = 38
    static let spacing: CGFloat = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Circle().frame(width: 16, height: 16)
                bar(width: 34)
                bar(width: 18)
                bar(width: 34)
                Circle().frame(width: 16, height: 16)
                Spacer()
                bar(width: 40)
            }
            bar(width: 120)
        }
        .foregroundStyle(Color.primary.opacity(0.14))
        .padding(.horizontal, 8)
        .frame(height: Self.height)
        .opacity(max(0.5, 1 - Double(index) * 0.06))
        .accessibilityHidden(true)
    }

    private func bar(width: CGFloat) -> some View {
        Capsule().frame(width: width, height: 8)
    }
}

private struct FixtureRow: View {
    let fixture: Fixture
    /// Only today's matches can be pinned to the screen — a capsule reads today's
    /// live list.
    var pinnable = true
    @Binding var expanded: Int?
    @EnvironmentObject var session: AppSession
    @ObservedObject private var capsules = PinnedCapsuleManager.shared
    @State private var hovering = false

    private var isPinned: Bool { capsules.isPinned(fixture.fixtureId) }
    private var isExpanded: Bool { expanded == fixture.fixtureId }

    var body: some View {
        // Clicking a row opens its timeline (and the pin) in place. The detail
        // sits outside the button so its own pin button gets the click.
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    expanded = isExpanded ? nil : fixture.fixtureId
                }
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        CachedTeamLogo(url: logo(fixture.home.id), size: 16)
                        // Short codes ("MUN"), not full club names — the crest
                        // already says who it is. A codeless team falls back to
                        // its name and truncates with …; score, logos and the
                        // time never get squeezed.
                        Text(shortName(fixture.home)).font(.system(size: 12)).lineLimit(1)
                        Text(score).font(.system(size: 12, weight: .bold))
                            .fixedSize().layoutPriority(1)
                        Text(shortName(fixture.away)).font(.system(size: 12)).lineLimit(1)
                        CachedTeamLogo(url: logo(fixture.away.id), size: 16)
                        if isPinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(Color.accentColor)
                                .help("Pinned")
                        }
                        Spacer()
                        trailing
                    }
                    subtitle
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isExpanded ? "Hides the timeline" : "Shows the timeline")
            if isExpanded {
                detail
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(isExpanded ? 0.06 : (hovering ? 0.08 : 0)))
        )
        .onHover { over in
            withAnimation(.easeOut(duration: 0.12)) { hovering = over }
        }
    }

    /// What opens under the row: the timeline once there's play to show, the
    /// kickoff otherwise, and the pin for today's matches.
    @ViewBuilder private var detail: some View {
        VStack(alignment: .leading, spacing: 6) {
            let timeline = capsuleTimeline(for: fixture)
            if !timeline.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(timeline) { TimelineEventLine(row: $0) }
                }
            } else if let note = detailNote {
                Text(note).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if pinnable {
                HStack(spacing: 8) { PinButtons(fixtureId: fixture.fixtureId) }
            }
        }
    }

    private var detailNote: String? {
        let kickoff = fixture.kickoff.map { $0.formatted(date: .omitted, time: .shortened) }
        switch fixture.status {
        case "SCHEDULED":
            if (fixture.kickoff ?? .distantFuture) <= Date() {
                return "Waiting for a confirmed match update."
            }
            return kickoff.map { "Kicks off at \($0)." }
        case "FINISHED": return "No goals or cards."
        default: return fixture.isLive ? "Nothing yet." : nil
        }
    }

    /// Competition and stage, under the teams.
    @ViewBuilder private var subtitle: some View {
        let league = session.leagueName(for: fixture.leagueId)
        if let text = [league, fixture.stageLabel]
            .compactMap({ $0 }).joined(separator: " · ").trimmedNonEmpty {
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private var score: String {
        if fixture.status == "SCHEDULED" { return "vs" }
        return fixture.scorelineText
    }

    /// The right edge is always about time: minute when live, kickoff time
    /// when scheduled, FT when done.
    @ViewBuilder private var trailing: some View {
        if fixture.isLive {
            LiveMatchStatus(fixture: fixture)
        } else if fixture.status == "FINISHED" {
            Text("FT").font(.system(size: 12, weight: .semibold)).foregroundStyle(.green)
        } else if fixture.isCalledOff {
            Text(fixture.rawStatus == "PST" ? "Postponed" : "Called off")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        } else if (fixture.kickoff ?? .distantFuture) <= Date() {
            Text("Awaiting update").font(.system(size: 12)).foregroundStyle(.secondary)
        } else if let kickoff = fixture.kickoff {
            Text(kickoff, style: .time).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private func logo(_ id: Int) -> String {
        TeamCatalog.team(for: id, in: session.allTeams).logo
    }

    private func shortName(_ team: ScoreboardTeam) -> String {
        TeamCatalog.shortName(for: team.id, in: session.allTeams, fallback: team.name)
    }
}

/// A clock only claims to be live while the latest read is confirmed current.
struct LiveMatchStatus: View {
    let fixture: Fixture
    var fontSize: CGFloat = 12
    @EnvironmentObject var session: AppSession

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let status = session.liveScoreStatus(fixture.fixtureId, at: context.date)
            HStack(spacing: 5) {
                if status == .current {
                    Circle().fill(.red).frame(width: 6, height: 6)
                    Text(fixture.liveMinuteText(localElapsed: LiveStore.shared.localElapsedSeconds(fixture.fixtureId, at: context.date)))
                        .foregroundStyle(.red)
                } else {
                    Image(systemName: status == .checking ? "arrow.clockwise" : "wifi.exclamationmark")
                    Text(status == .checking ? "Checking…" : "Updates delayed")
                }
            }
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundStyle(.secondary)
            .fixedSize()
            .accessibilityElement(children: .combine)
        }
    }
}

struct DataStatusBanner: View {
    let message: String
    var retrying = false
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.exclamationmark").accessibilityHidden(true)
            Text(message).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(retrying ? "Retrying…" : "Retry", action: retry)
                .buttonStyle(.cardButton).disabled(retrying)
        }
        .foregroundStyle(.secondary)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
    }
}
