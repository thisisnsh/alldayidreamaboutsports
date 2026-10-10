import SwiftUI

/// The popover's Teams page: search, then every league's team grid. Saves on
/// every toggle.
struct TeamsPage: View {
    @EnvironmentObject var session: AppSession
    @State private var query = ""
    @State private var followingOnly = false
    static let screen = "team_picker"

    var body: some View {
        VStack(spacing: 8) {
            PageHeader(title: "Teams", note: "\(session.fanTeams.count) followed")
            TeamSearchField(query: $query)
                .padding(.horizontal, 12)
            Picker("Show teams", selection: $followingOnly) {
                Text("All teams").tag(false)
                Text("Following").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            if session.catalogState == .unavailable {
                DataStatusBanner(message: "Team list couldn't update", retrying: false) {
                    Task { await session.refreshCatalog() }
                }
                .padding(.horizontal, 12)
            }
            ScrollView {
                TeamLeagueList(query: query, columns: 3, followingOnly: followingOnly)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
            // Content fades out as it slides up under the search bar.
            .mask(
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: 12)
                    Rectangle()
                }
            )
        }
        // Fetch+cache all logos when the page opens; re-fetch if >24h old.
        .task { TeamLogoStore.shared.warm(session.leagues.map(\.logo) + session.allTeams.map(\.logo)) }
    }
}

struct TeamSearchField: View {
    @Binding var query: String

    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass").opacity(0.5)
            TextField("Search teams", text: $query)
                .textFieldStyle(.plain)
                .accessibilityLabel("Search teams")
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 9).fill(.thinMaterial))
    }
}

/// Every league's team grid, filtered by `query`. Shared by the popover's
/// Teams page (4 columns) and onboarding (6 columns). Every league is
/// followable, at full opacity — a finished competition is badged "Ended" and
/// one that hasn't started "Coming soon", but those are labels, not gates.
struct TeamLeagueList: View {
    @EnvironmentObject var session: AppSession
    let query: String
    let columns: Int
    var followingOnly = false
    /// Folded leagues. View state only: every league opens unfolded.
    @State private var collapsed: Set<Int> = []

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 18) {
            if !hasResults {
                VStack(spacing: 8) {
                    if session.catalogState == .loading, session.leagues.isEmpty {
                        ProgressView().controlSize(.small)
                        Text("Loading teams…")
                    } else if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Image(systemName: "magnifyingglass").font(.system(size: 24))
                        Text("No teams found").fontWeight(.semibold)
                        Text("Try another name or clear your search.")
                    } else if followingOnly {
                        Image(systemName: "heart.circle").font(.system(size: 24))
                        Text("You're not following any teams yet").fontWeight(.semibold)
                        Text("Choose All teams to find your clubs.")
                    } else {
                        Text("Team list unavailable").fontWeight(.semibold)
                        Button("Try again") { Task { await session.refreshCatalog() } }
                            .buttonStyle(.cardButton)
                    }
                }
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
            }
            ForEach(session.leagues) { league in
                let leagueTeams = teams(for: league)
                // While searching, hide leagues with no matches.
                if (query.isEmpty && !followingOnly) || !leagueTeams.isEmpty {
                    LeagueSection(
                        league: league,
                        teams: leagueTeams,
                        columns: columns,
                        // A search always shows its results, folded or not.
                        collapsed: query.isEmpty && collapsed.contains(league.id)
                    ) {
                        withAnimation(.easeOut(duration: 0.15)) {
                            if collapsed.contains(league.id) {
                                collapsed.remove(league.id)
                            } else {
                                collapsed.insert(league.id)
                            }
                        }
                    }
                }
            }
        }
    }

    private var hasResults: Bool { session.leagues.contains { !teams(for: $0).isEmpty } }

    private func teams(for league: League) -> [Team] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return (session.teamsByLeague[league.id] ?? [])
            .filter { !followingOnly || session.fanTeamIds.contains($0.id) }
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
            .sorted { $0.name < $1.name }
    }
}

/// How a league presents itself in the picker. Presentation only: every state
/// is followable, and none of them dims the section.
private enum LeagueState {
    /// Under way.
    case live
    /// Its current season is over — teams stay listed and pickable.
    case ended
    /// Known about, not launched yet.
    case comingSoon

    init(_ league: League) {
        if league.ended { self = .ended } else if league.active { self = .live } else { self = .comingSoon }
    }

    var badge: String? {
        switch self {
        case .live: return nil
        case .ended: return "Ended"
        case .comingSoon: return "Coming soon"
        }
    }
}

/// One league: a header that folds it (logo + name + status) with its bulk
/// follow control, then its team grid.
private struct LeagueSection: View {
    @EnvironmentObject var session: AppSession
    let league: League
    let teams: [Team]
    let columns: Int
    let collapsed: Bool
    let toggleCollapsed: () -> Void

    private var state: LeagueState { LeagueState(league) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Button(action: toggleCollapsed) {
                    HStack(spacing: 7) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(collapsed ? -90 : 0))
                            .opacity(0.5)
                        CachedTeamLogo(url: league.logo, size: 24, fallbackSymbol: "trophy.fill", neutralBacking: true)
                        Text(league.name)
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .lineLimit(1)
                        if let badge = state.badge {
                            Text(badge)
                                .font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Color.primary.opacity(0.1)))
                        } else if followedCount > 0 {
                            Text("\(followedCount) followed")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(league.name)
                .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
                bulkButton
            }

            if !collapsed {
                if !league.scheduled {
                    Text("Not scheduled")
                        .font(.system(size: 12)).opacity(0.6)
                } else if teams.isEmpty {
                    Text("No teams yet").font(.system(size: 12)).opacity(0.6)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
                        ForEach(teams) { team in
                            TeamTile(team: team, selected: session.fanTeamIds.contains(team.id)) {
                                toggle(team)
                            }
                        }
                    }
                }
            }
        }
    }

    private var followedCount: Int {
        (session.teamsByLeague[league.id] ?? []).filter { session.fanTeamIds.contains($0.id) }.count
    }

    private func toggle(_ team: Team) {
        var ids = session.prefs.fanTeamIds
        let key = String(team.id)
        if let index = ids.firstIndex(of: key) {
            ids.remove(at: index)
        } else {
            ids.append(key)
        }
        session.setFanTeams(ids)
    }

    // MARK: Follow all / unfollow all

    /// The teams the button acts on: whatever the section is showing. Under a
    /// search that's the matching subset, so what the button does always
    /// matches what's in front of you.
    private var shownIds: [String] { teams.map { String($0.id) } }
    private var unfollowed: [String] {
        let followed = Set(session.prefs.fanTeamIds)
        return shownIds.filter { !followed.contains($0) }
    }

    /// One control at a time, to fit the narrow popover: "Follow all" while
    /// anything shown is unfollowed, "Unfollow all" once everything is.
    @ViewBuilder private var bulkButton: some View {
        if !teams.isEmpty, league.scheduled {
            if !unfollowed.isEmpty {
                Button(action: followAll) {
                    Text("Follow all").font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.hoverHighlight)
            } else {
                Button(action: unfollowAll) {
                    Text("Unfollow all").font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.hoverHighlight)
            }
        }
    }

    /// One `setFanTeams` call, not one per team: it persists, logs, emits a
    /// per-team analytics event and kicks off `reconcileFanMatches`, so a loop
    /// would fire that whole tail twenty times.
    private func followAll() {
        let added = unfollowed
        // The individual `team_follow` events still fire per team; this is the
        // marker that says they came from one bulk action.
        AppAnalytics.leagueFollowAll(leagueId: league.id, count: added.count)
        session.setFanTeams(session.prefs.fanTeamIds + added)
    }

    private func unfollowAll() {
        let shown = Set(shownIds)
        let remaining = session.prefs.fanTeamIds.filter { !shown.contains($0) }
        AppAnalytics.leagueUnfollowAll(leagueId: league.id,
                                       count: session.prefs.fanTeamIds.count - remaining.count)
        session.setFanTeams(remaining)
    }
}

private struct TeamTile: View {
    let team: Team
    let selected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 5) {
                    CachedTeamLogo(url: team.logo, size: 36, neutralBacking: true)
                    Text(team.name)
                        .font(.system(size: 12, weight: .medium))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .frame(height: 30, alignment: .top)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .padding(.horizontal, 3)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(selected ? Color.primary.opacity(0.12) : Color.primary.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(selected ? Color.primary : .clear, lineWidth: 2)
                )

                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(scheme == .dark ? .black : .white, Color.primary)
                        .padding(5)
                }
            }
        }
        .buttonStyle(.plain)
        .hoverLift()
        .accessibilityLabel(team.name)
        .accessibilityValue(selected ? "Following" : "Not followed")
        .accessibilityHint(selected ? "Unfollow this team" : "Follow for live scores and alerts")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
