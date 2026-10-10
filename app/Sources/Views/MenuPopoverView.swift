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
    /// The popover's height, set by `MenuPopoverController` from the page and
    /// `homeFit`.
    @Published var height = MenuPopoverView.maxHeight
    /// How tall the home page wants to be to show all its matches without
    /// scrolling, as last measured. nil until it first lays out.
    @Published var homeFit: CGFloat?

    func go(_ page: PopoverPage) {
        guard page != self.page else { return }
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

    /// Jump without animation — used just before the popover shows, so it
    /// never opens mid-slide.
    func reset(to page: PopoverPage = .home) {
        forward = true
        self.page = page
    }
}

/// The menu bar popover: a fixed-width frame that swaps between pages. Home is
/// as tall as its matches need; Teams and Settings use the full height.
struct MenuPopoverView: View {
    @EnvironmentObject var session: AppSession
    @ObservedObject private var router = PopoverRouter.shared
    /// The analytics screen name for the home page. The `screen_view` itself is
    /// fired by `MenuPopoverController.showMenu()` — the hosting controller is
    /// built once and reused, so `.onAppear` here would only fire once a launch.
    static let screen = "menu"
    static let width: CGFloat = 360
    static let maxHeight: CGFloat = 540
    static let minHeight: CGFloat = 200

    static func height(for page: PopoverPage, homeFit: CGFloat?) -> CGFloat {
        guard page == .home, let homeFit else { return maxHeight }
        return min(maxHeight, max(minHeight, homeFit.rounded(.up)))
    }

    var body: some View {
        ZStack {
            switch router.page {
            case .home: HomePage().transition(slide)
            case .teams: TeamsPage().transition(slide)
            case .settings: SettingsPage().transition(slide)
            }
        }
        .frame(width: Self.width, height: router.height)
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
    @ViewBuilder var trailing: Trailing

    var body: some View {
        ZStack {
            Text(title).font(.system(size: 15, weight: .bold, design: .rounded))
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
    init(title: String) {
        self.init(title: title) { EmptyView() }
    }
}

/// A bare SF Symbol button for the popover's toolbars.
struct ToolbarIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .frame(width: 28, height: 26)
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

/// Today's matches grouped by state, with followed teams along the bottom.
struct HomePage: View {
    @EnvironmentObject var session: AppSession
    /// Which slice of today the fixture list shows. Stored locally rather than
    /// in `prefs` — it's a view preference for this Mac, not synced state, and
    /// the menu rebuilds its view on every open so it has to outlive that.
    @AppStorage("menuFixtureScope", store: AppDefaults.shared) private var fixtureScope: FixtureScope = .mine
    /// The one row (or Now card) showing its timeline.
    @State private var expanded: Int?
    /// Natural heights of the three parts, for `PopoverRouter.homeFit`.
    @State private var headerHeight: CGFloat = 0
    @State private var listHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            header.onGeometryChange(for: CGFloat.self, of: \.size.height) { headerHeight = $0; reportFit() }
            fixturesList
            Divider()
            followingFooter.onGeometryChange(for: CGFloat.self, of: \.size.height) { footerHeight = $0; reportFit() }
        }
    }

    /// The height that shows every match without scrolling or leftover space.
    private func reportFit() {
        guard headerHeight > 0, listHeight > 0, footerHeight > 0 else { return }
        let fit = headerHeight + listHeight + 1 + footerHeight // 1 = divider
        if PopoverRouter.shared.homeFit != fit { PopoverRouter.shared.homeFit = fit }
    }

    /// The empty state's share of the fit — its own frame just fills whatever
    /// it's given, so it can't be measured.
    private static let emptyListHeight: CGFloat = 140

    private var header: some View {
        HStack(spacing: 6) {
            Text("Today").font(.system(size: 15, weight: .bold, design: .rounded))
            Spacer()
            PillPicker(options: FixtureScope.allCases, selection: $fixtureScope, label: \.label) {
                AppAnalytics.fixtureScopeChanged($0.rawValue)
            }
            ToolbarIconButton(symbol: "gearshape", help: "Settings") { PopoverRouter.shared.go(.settings) }
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder private var fixturesList: some View {
        if shownFixtures.isEmpty {
            VStack(spacing: 10) {
                Spacer()
                if fixtureScope == .mine, session.fanTeamIds.isEmpty {
                    Image(systemName: "heart.circle").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("Follow a team to see its matches").font(.system(size: 13, weight: .medium))
                    Button("Choose teams") { PopoverRouter.shared.go(.teams) }
                        .buttonStyle(.cardButton)
                } else if session.scheduleState == .loading {
                    ProgressView().controlSize(.small)
                    Text("Loading today's matches…").font(.system(size: 13)).foregroundStyle(.secondary)
                } else if session.scheduleState == .unavailable {
                    Image(systemName: "wifi.exclamationmark").font(.system(size: 24)).foregroundStyle(.secondary)
                    Text("Couldn't load today's matches").font(.system(size: 13, weight: .medium))
                    retryButton
                } else {
                    Text(emptyMessage).font(.system(size: 13)).foregroundStyle(.secondary)
                    if fixtureScope == .mine, session.hasFixturesToday {
                        Button("View all matches") { fixtureScope = .all }
                            .buttonStyle(.cardButton)
                    }
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { listHeight = Self.emptyListHeight; reportFit() }
        } else {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 12) {
                    if session.scheduleState == .unavailable {
                        DataStatusBanner(message: "Schedule couldn't update", retrying: session.isRefreshingFixtures) {
                            Task { await session.refreshFixtures() }
                        }
                    }
                    fixtureSection("Live", fixtures: followedFixtures.filter { $0.isLive }, liveCards: true)
                    fixtureSection("Upcoming", fixtures: followedFixtures.filter {
                        !$0.isLive && $0.status != "FINISHED" && !$0.isCalledOff && ($0.kickoff ?? .distantPast) > Date()
                    })
                    fixtureSection("Finished", fixtures: followedFixtures.filter { $0.status == "FINISHED" })
                    fixtureSection("Match updates", fixtures: followedFixtures.filter {
                        !$0.isLive && $0.status != "FINISHED" && ($0.isCalledOff || ($0.kickoff ?? .distantPast) <= Date())
                    })
                    fixtureSection("Other matches · schedule only", fixtures: shownFixtures.filter {
                        !$0.involves(session.fanTeamIds)
                    })
                }
                .padding(.horizontal, 8)
                .padding(.vertical, Self.fadeHeight)
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { listHeight = $0; reportFit() }
            }
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

    private var followedFixtures: [Fixture] {
        shownFixtures.filter { $0.involves(session.fanTeamIds) }
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
                        FixtureRow(fixture: fixture, live: fixture.involves(session.fanTeamIds), expanded: $expanded)
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

    private var shownFixtures: [Fixture] {
        switch fixtureScope {
        case .mine: return session.fixtures
        case .all: return session.todayFixtures
        }
    }

    /// Nothing to list: either football is off entirely today, or it's on but
    /// none of it is theirs (only reachable in "My Teams").
    private var emptyMessage: String {
        if session.fanTeamIds.isEmpty, fixtureScope == .mine { return "Follow a team to see its matches" }
        return session.hasFixturesToday
            ? "None of your teams play today 💤"
            : "No matches today — rest day ☁️"
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

/// Which of today's matches the menu lists: only the followed teams' (the
/// default), or the whole day across every league. Both come out of the one
/// schedule file the app already downloads — "All Teams" adds no fetching.
enum FixtureScope: String, CaseIterable {
    case mine
    case all

    var label: String {
        switch self {
        case .mine: return "My Teams"
        case .all: return "All Teams"
        }
    }
}

/// A compact two-or-more segment switch for a header row ("My Teams | All
/// Teams", "All | Following"). Hand-rolled rather than
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
    @ObservedObject private var capsules = PinnedCapsuleManager.shared

    private var isExpanded: Bool { expanded == fixture.fixtureId }
    private var isPinned: Bool { capsules.isPinned(fixture.fixtureId) }

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
                Button {
                    capsules.toggle(fixtureId: fixture.fixtureId)
                } label: {
                    Label(isPinned ? "Unpin from screen" : "Pin to screen", systemImage: "pin.fill")
                }
                .buttonStyle(.cardButton)
                .help(isPinned ? "Unpin the floating score" : "Float this score on screen")
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
                .frame(width: 34, alignment: .trailing)
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
            if let text = row.text {
                Text(text).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).strikethrough(row.disallowed)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct FixtureRow: View {
    let fixture: Fixture
    /// Whether this row may show live state — score, minute, FT
    /// tally. Only a followed team's match can: `LiveStore` polls `session.fixtures` alone,
    /// and `fixtures-{date}.json` is schedule data by construction (goals
    /// zeroed, status forced to SCHEDULED — see `toScheduleRow` in the
    /// backend's poller). A schedule row is teams + kickoff time, nothing else;
    /// showing it a "0 – 0" would be inventing a scoreline.
    var live: Bool = true
    @Binding var expanded: Int?
    @EnvironmentObject var session: AppSession
    @ObservedObject private var capsules = PinnedCapsuleManager.shared
    @State private var hovering = false

    private var isPinned: Bool { capsules.isPinned(fixture.fixtureId) }
    private var isExpanded: Bool { expanded == fixture.fixtureId }
    /// A capsule reads `session.fixtures`, so only a followed team's match can
    /// be pinned — and only from a row that's actually showing live state.
    private var pinnable: Bool { live && fixture.involves(session.fanTeamIds) }

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
                                .help("Pinned to screen")
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
    /// kickoff otherwise, and the pin for a followed match.
    @ViewBuilder private var detail: some View {
        VStack(alignment: .leading, spacing: 6) {
            let timeline = live ? capsuleTimeline(for: fixture) : []
            if !timeline.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(timeline) { TimelineEventLine(row: $0) }
                }
            } else if let note = detailNote {
                Text(note).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if !live {
                HStack {
                    followButton(fixture.home)
                    followButton(fixture.away)
                }
            }
            if pinnable {
                Button {
                    capsules.toggle(fixtureId: fixture.fixtureId)
                } label: {
                    Label(isPinned ? "Unpin from screen" : "Pin to screen", systemImage: "pin.fill")
                }
                .buttonStyle(.cardButton)
            }
        }
    }

    private func followButton(_ team: ScoreboardTeam) -> some View {
        Button("Follow \(shortName(team))") {
            session.setFanTeams(session.prefs.fanTeamIds + [String(team.id)])
        }
        .buttonStyle(.cardButton)
        .accessibilityLabel("Follow \(team.name) for live scores and alerts")
    }

    private var detailNote: String? {
        let kickoff = fixture.kickoff.map { $0.formatted(date: .omitted, time: .shortened) }
        if !live {
            let when = kickoff.map { "Scheduled for \($0). " } ?? ""
            return when + "Follow either team for live scores and alerts."
        }
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
        if !live || fixture.status == "SCHEDULED" { return "vs" }
        return fixture.scorelineText
    }

    /// The right edge is always about time: minute when live, kickoff time
    /// when scheduled, FT when done.
    @ViewBuilder private var trailing: some View {
        if !live {
            if let kickoff = fixture.kickoff {
                Text(kickoff, style: .time).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        } else if fixture.isLive {
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
