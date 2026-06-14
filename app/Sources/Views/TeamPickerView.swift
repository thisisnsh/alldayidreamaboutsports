import SwiftUI

/// "Become a Fan": search + per-league sections of team logos with a tick on
/// selected tiles, and the current "Fan of" strip at the bottom. The active
/// league (World Cup) is selectable; the rest show greyed as "Coming soon".
/// Saves on every toggle.
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

/// One league: header (logo + name + status), then its team grid. Non-active
/// leagues are dimmed and their tiles are not tappable.
private struct LeagueSection: View {
    @EnvironmentObject var session: AppSession
    let league: League
    let teams: [Team]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                CachedTeamLogo(url: league.logo, size: 22, fallbackSymbol: "trophy.fill")
                Text(league.name).font(.system(size: 14, weight: .bold, design: .rounded))
                if !league.active {
                    Spacer()
                    Text("Coming soon")
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
                        TeamTile(
                            team: team,
                            selected: session.fanTeamIds.contains(team.id),
                            enabled: league.active
                        ) {
                            toggle(team)
                        }
                    }
                }
            }
        }
        .opacity(league.active ? 1 : 0.55)
    }

    private func toggle(_ team: Team) {
        guard league.active else { return }
        var ids = session.prefs.footballTeams
        let key = String(team.id)
        if let index = ids.firstIndex(of: key) {
            ids.remove(at: index)
        } else {
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
