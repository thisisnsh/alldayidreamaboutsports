import SwiftUI

/// "Become a Fan": search, alphabetical flag grid with a tick on selected
/// tiles, and the current "Fan of" strip at the bottom. Saves on every toggle.
struct TeamPickerView: View {
    @EnvironmentObject var session: AppSession
    @State private var query = ""

    private var filtered: [Team] {
        let all = session.teams.sorted { $0.name < $1.name }
        guard !query.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)

    var body: some View {
        ZStack {
            AppBackground()
            pickerContent
        }
        .frame(width: 520, height: 560)
        .installsWindowOpener()
        .appTheme(session.prefs.settings.theme ?? .system)
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
                TextField("Search countries", text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(.thinMaterial))
            .padding(.horizontal, 16)
            .padding(.top, 12)

            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(filtered) { team in
                        TeamTile(
                            team: team,
                            selected: session.fanTeamCodes.contains(team.code)
                        ) {
                            toggle(team)
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
            HStack(spacing: 6) {
                Text("Fan of").font(.system(size: 13, weight: .semibold))
                if session.fanTeams.isEmpty {
                    Text("— pick your teams above").font(.system(size: 13)).opacity(0.6)
                } else {
                    Text(session.fanTeams.map(\.flag).joined(separator: " "))
                        .font(.system(size: 18))
                }
                Spacer()
            }
            .padding(14)
            .background(.thinMaterial)
        }
    }

    private func toggle(_ team: Team) {
        var codes = session.prefs.footballTeams
        if let index = codes.firstIndex(of: team.code) {
            codes.remove(at: index)
        } else {
            codes.append(team.code)
        }
        session.setFanTeams(codes)
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
                VStack(spacing: 6) {
                    Text(team.flag).font(.system(size: 34))
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
        .hoverLift()
    }
}
