import SwiftUI

/// "Become a Fan": search + per-league sections of team logos with a tick on
/// selected tiles, and the current "Fan of" strip at the bottom. The active
/// leagues (the top five) are selectable; a finished competition shows greyed
/// as "Ended" with its teams still listed and still deselectable, and anything
/// not launched yet shows as "Coming soon". Saves on every toggle.
struct TeamPickerView: View {
    @EnvironmentObject var session: AppSession
    @State private var query = ""

    var body: some View {
        ZStack {
            AppBackground()
            pickerContent
        }
        .frame(width: 560, height: 600)
        .installsWindowOpener()
        .appTheme(session.prefs.settings.theme ?? .system)
        // Fetch+cache all logos when the window opens; re-fetch if >24h old.
        .task { TeamLogoStore.shared.warm(session.leagues.map(\.logo) + session.allTeams.map(\.logo)) }
    }

    private func teams(for league: League) -> [Team] {
        let all = (session.teamsByLeague[league.id] ?? []).sorted { $0.name < $1.name }
        guard !query.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var pickerContent: some View {
        VStack(spacing: 0) {
            // In-content heading — left-aligned, tucked under the traffic lights.
            Text("Become a Fan")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 16)
                .padding(.top, 8)

            if session.showsLeagueMigrationNotice {
                migrationNotice
            }

            HStack {
                Image(systemName: "magnifyingglass").opacity(0.5)
                TextField("Search teams", text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(.thinMaterial))
            .padding(.horizontal, 16)
            .padding(.top, 12)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(session.leagues) { league in
                        let leagueTeams = teams(for: league)
                        // While searching, hide leagues with no matches.
                        if query.isEmpty || !leagueTeams.isEmpty {
                            LeagueSection(league: league, teams: leagueTeams)
                        }
                    }
                }
                .padding(16)
            }
            // Content fades out as it slides up under the search bar.
            .mask(
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: 20)
                    Rectangle()
                }
            )

            Divider()
            fanOfStrip
        }
    }

    /// Shown once, to someone whose only saved teams are World Cup sides. Their
    /// picks are not being taken away — the note says so, because the greyed
    /// "Ended" section below would otherwise read as exactly that.
    private var migrationNotice: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles").font(.system(size: 12)).opacity(0.7)
            Text("The World Cup has ended — pick a club side to follow. Your national teams stay saved for 2030.")
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    private var fanOfStrip: some View {
        HStack(spacing: 8) {
            Text("Fan of").font(.system(size: 13, weight: .semibold))
            if session.fanTeams.isEmpty {
                Text("— pick your teams above").font(.system(size: 13)).opacity(0.6)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(session.fanTeams) { team in
                            CachedTeamLogo(url: team.logo, size: 22)
                        }
                    }
                }
            }
            Spacer()
        }
        .padding(14)
        .background(.thinMaterial)
    }
}

/// How a league presents itself in the picker.
private enum LeagueState {
    /// Followable now.
    case live
    /// Over. Greyed and badged, but its teams stay listed and stay deselectable
    /// so anyone still following a national side can see and drop it.
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

    /// Ended leagues allow removal but not new picks — following a team whose
    /// competition is finished would just be a row that never plays.
    var allowsAdding: Bool { self == .live }
    var allowsRemoving: Bool { self != .comingSoon }
    var opacity: Double { self == .live ? 1 : 0.55 }
}

/// One league: header (logo + country + name + status), then its team grid.
private struct LeagueSection: View {
    @EnvironmentObject var session: AppSession
    let league: League
    let teams: [Team]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)
    private var state: LeagueState { LeagueState(league) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                CachedTeamLogo(url: league.logo, size: 22, fallbackSymbol: "trophy.fill")
                Text(league.name).font(.system(size: 14, weight: .bold, design: .rounded))
                // With five leagues on screen the country is what tells them
                // apart at a glance.
                if let country = league.country, !country.isEmpty {
                    Text(country)
                        .font(.system(size: 11, weight: .medium))
                        .opacity(0.5)
                }
                if let badge = state.badge {
                    Spacer()
                    Text(badge)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(Color.primary.opacity(0.1)))
                }
            }

            if !league.scheduled {
                Text("Not scheduled")
                    .font(.system(size: 12)).opacity(0.6)
            } else if teams.isEmpty {
                Text("No teams yet").font(.system(size: 12)).opacity(0.6)
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(teams) { team in
                        let selected = session.fanTeamIds.contains(team.id)
                        TeamTile(
                            team: team,
                            selected: selected,
                            // An ended league's tiles stay live only for the
                            // teams already followed, so they can be dropped.
                            enabled: state.allowsAdding || (selected && state.allowsRemoving)
                        ) {
                            toggle(team)
                        }
                    }
                }
            }
        }
        .opacity(state.opacity)
    }

    private func toggle(_ team: Team) {
        var ids = session.prefs.fanTeamIds
        let key = String(team.id)
        if let index = ids.firstIndex(of: key) {
            guard state.allowsRemoving else { return }
            ids.remove(at: index)
        } else {
            guard state.allowsAdding else { return }
            // Cap how many teams a user can follow (config-driven). Adding past
            // the cap is a no-op so the user can't silently lose later picks.
            guard ids.count < ControlPlane.shared.maxFanTeams else { return }
            ids.append(key)
        }
        session.setFanTeams(ids)
    }
}

private struct TeamTile: View {
    let team: Team
    let selected: Bool
    let enabled: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 6) {
                    CachedTeamLogo(url: team.logo, size: 38)
                    Text(team.name)
                        .font(.system(size: 11, weight: .medium))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(selected ? Color.primary.opacity(0.12) : Color.primary.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(selected ? Color.primary : .clear, lineWidth: 2)
                )

                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(scheme == .dark ? .black : .white, Color.primary)
                        .offset(x: 6, y: -6)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .hoverLift()
    }
}
