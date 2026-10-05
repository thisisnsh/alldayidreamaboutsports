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

/// The menu bar popover: a fixed-size frame that swaps between pages.
struct MenuPopoverView: View {
    @EnvironmentObject var session: AppSession
    @ObservedObject private var router = PopoverRouter.shared
    /// The analytics screen name for the home page. The `screen_view` itself is
    /// fired by `MenuPopoverController.showMenu()` — the hosting controller is
    /// built once and reused, so `.onAppear` here would only fire once a launch.
    static let screen = "menu"
    /// Fixed for every page: resizing an `NSPopover` while it's open jumps.
    static let size = CGSize(width: 360, height: 540)

    var body: some View {
        ZStack {
            switch router.page {
            case .home: HomePage().transition(slide)
            case .teams: TeamsPage().transition(slide)
            case .settings: SettingsPage().transition(slide)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipped()
        .background(AppBackground())
        .appTheme(session.prefs.settings.theme ?? .system)
    }

    private var slide: AnyTransition {
        .asymmetric(
            insertion: .move(edge: router.forward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: router.forward ? .leading : .trailing).combined(with: .opacity)
        )
    }
}

/// Header of a pushed page: a back button to the matches, the page title
/// centered, and an optional note on the right.
struct PageHeader: View {
    let title: String
    var note: String? = nil

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
                if let note {
                    Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 4)
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

/// Today's matches: the scope switch and the way to Teams and Settings on top,
/// the list in the middle, the followed teams along the bottom.
struct HomePage: View {
    @EnvironmentObject var session: AppSession
    /// Which slice of today the fixture list shows. Stored locally rather than
    /// in `prefs` — it's a view preference for this Mac, not synced state, and
    /// the menu rebuilds its view on every open so it has to outlive that.
    @AppStorage("menuFixtureScope", store: AppDefaults.shared) private var fixtureScope: FixtureScope = .mine

    var body: some View {
        VStack(spacing: 0) {
            header
            fixturesList
            Divider()
            followingFooter
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Today").font(.system(size: 15, weight: .bold, design: .rounded))
            Spacer()
            FixtureScopePicker(scope: $fixtureScope)
            ToolbarIconButton(symbol: "heart", help: "Teams") { PopoverRouter.shared.go(.teams) }
            ToolbarIconButton(symbol: "gearshape", help: "Settings") { PopoverRouter.shared.go(.settings) }
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder private var fixturesList: some View {
        let shown = shownFixtures
        if shown.isEmpty {
            VStack(spacing: 6) {
                Spacer()
                Text(emptyMessage).font(.system(size: 13)).opacity(0.7)
                if fixtureScope == .mine, session.hasFixturesToday {
                    Text("Switch to All Teams to see the full matchday.")
                        .font(.system(size: 11)).opacity(0.5)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(shown) { fixture in
                        FixtureRow(fixture: fixture, live: fixtureScope == .mine)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, Self.fadeHeight)
            }
            // Rows dissolve into the popover at both ends instead of being
            // sliced off by the scroll view's edge.
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

/// The two-segment scope switch in the "Today's matches" header. Hand-rolled
/// rather than `.pickerStyle(.segmented)`: at caption size AppKit's segmented
/// control brings chrome (and a fixed height) far too heavy for a menu row.
private struct FixtureScopePicker: View {
    @Binding var scope: FixtureScope

    var body: some View {
        HStack(spacing: 2) {
            ForEach(FixtureScope.allCases, id: \.self) { option in
                Segment(option: option, selected: scope == option) {
                    AppAnalytics.fixtureScopeChanged(option.rawValue)
                    withAnimation(.easeOut(duration: 0.15)) { scope = option }
                }
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06))
        )
    }

    private struct Segment: View {
        let option: FixtureScope
        let selected: Bool
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                Text(option.label)
                    .font(.system(size: 10, weight: selected ? .semibold : .regular))
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
        }
    }
}

private struct FixtureRow: View {
    let fixture: Fixture
    /// Whether this row may show live state — score, minute, FT
    /// tally. Only "My Teams" can: `LiveStore` polls `session.fixtures` alone,
    /// and `fixtures-{date}.json` is schedule data by construction (goals
    /// zeroed, status forced to SCHEDULED — see `toScheduleRow` in the
    /// backend's poller). A schedule row is teams + kickoff time, nothing else;
    /// showing it a "0 – 0" would be inventing a scoreline.
    var live: Bool = true
    @EnvironmentObject var session: AppSession
    @ObservedObject private var capsules = PinnedCapsuleManager.shared
    @State private var hovering = false

    private var isPinned: Bool { capsules.isPinned(fixture.fixtureId) }
    /// A capsule reads `session.fixtures`, so only a followed team's match can
    /// be pinned — and only from the list that's actually showing live state.
    private var pinnable: Bool { live && fixture.involves(session.fanTeamIds) }

    var body: some View {
        // The row is hover-only: it reveals the pin affordance and does not
        // navigate anywhere.
        Button {
        } label: {
            HStack(alignment: .center, spacing: 6) {
                if pinnable, isPinned || hovering {
                    pinSlot
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        CachedTeamLogo(url: logo(fixture.home.id), size: 16)
                        // Short codes ("MUN"), not full club names — the row is
                        // 320pt wide and the crest already says who it is. A
                        // codeless team falls back to its name and truncates
                        // with …; score, logos and the time never get squeezed.
                        Text(shortName(fixture.home)).font(.system(size: 12)).lineLimit(1)
                        Text(score).font(.system(size: 12, weight: .bold))
                            .fixedSize().layoutPriority(1)
                        Text(shortName(fixture.away)).font(.system(size: 12)).lineLimit(1)
                        CachedTeamLogo(url: logo(fixture.away.id), size: 16)
                        Spacer()
                        trailing
                    }
                    subtitle
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverHighlight)
        .onHover { over in
            withAnimation(.easeOut(duration: 0.15)) { hovering = over }
        }
    }

    /// Competition and stage remain visible while hovering the pin control.
    @ViewBuilder private var subtitle: some View {
        let league = session.leagueName(for: fixture.leagueId)
        if let text = [league, fixture.stageLabel]
            .compactMap({ $0 }).joined(separator: " · ").trimmedNonEmpty {
            Text(text).font(.system(size: 10)).opacity(0.6).lineLimit(1)
        }
    }

    /// Leading pin toggle, centered on the row. Only present on hover (or while
    /// pinned) so resting rows sit flush left with no reserved gutter.
    private var pinSlot: some View {
        Button {
            capsules.toggle(fixtureId: fixture.fixtureId)
        } label: {
            Image(systemName: "pin.fill")
                .font(.system(size: 11))
                .foregroundStyle(isPinned ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(.plain)
        .hoverLift()
        .frame(width: 16)
        .transition(.opacity)
        .help(isPinned ? "Unpin capsule" : "Pin scores to screen")
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
                Text(kickoff, style: .time).font(.system(size: 11)).opacity(0.7)
            }
        } else if fixture.isLive {
            HStack(spacing: 4) {
                Circle().fill(.red).frame(width: 6, height: 6)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(fixture.liveMinuteText(
                        localElapsed: LiveStore.shared.localElapsedSeconds(fixture.fixtureId, at: ctx.date)))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.red)
                }
            }
        } else if fixture.status == "FINISHED" {
            Text("FT").font(.system(size: 10, weight: .semibold)).foregroundStyle(.green)
        } else if let kickoff = fixture.kickoff {
            Text(kickoff, style: .time).font(.system(size: 11)).opacity(0.7)
        }
    }

    private func logo(_ id: Int) -> String {
        TeamCatalog.team(for: id, in: session.allTeams).logo
    }

    private func shortName(_ team: ScoreboardTeam) -> String {
        TeamCatalog.shortName(for: team.id, in: session.allTeams, fallback: team.name)
    }
}
