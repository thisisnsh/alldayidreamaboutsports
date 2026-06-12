import SwiftUI

/// The menu bar dropdown: profile, "Fan of" flags, today's fixtures for
/// followed teams (live scores + celebration counts), and actions.
struct MenuPopoverView: View {
    @EnvironmentObject var session: AppSession
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let profile = session.profile {
                header(profile)
                if !session.fanTeams.isEmpty {
                    fanOfRow
                }
                Divider()
                fixturesSection
                Divider()
                actions
            } else {
                signedOut
            }
        }
        .padding(16)
        .frame(width: 320)
        .background(AppBackground())
        .installsWindowOpener()
        .appTheme(session.prefs.settings.theme ?? .system)
        .onAppear { Task { await session.refreshFixtures() } }
    }

    private func header(_ profile: Profile) -> some View {
        HStack(spacing: 10) {
            AsyncImage(url: profile.photoURL.flatMap(URL.init)) { image in
                image.resizable()
            } placeholder: {
                Image(systemName: "person.crop.circle.fill").resizable()
            }
            .frame(width: 36, height: 36)
            .clipShape(Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.name ?? "Fan").font(.system(size: 14, weight: .semibold))
                Text(profile.email ?? "").font(.caption).opacity(0.7)
            }
            Spacer()
        }
    }

    private var fanOfRow: some View {
        HStack(spacing: 6) {
            Text("Fan of").font(.caption).opacity(0.7)
            Text(session.fanTeams.map(\.flag).joined(separator: " "))
                .font(.system(size: 16))
            Spacer()
        }
    }

    private var fixturesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Today's matches")
                .font(.caption)
                .fontWeight(.semibold)
                .opacity(0.7)
            let followed = session.fixtures.filter { $0.involves(session.fanTeamCodes) }
            let shown = followed.isEmpty ? session.fixtures : followed
            if shown.isEmpty {
                Text("No matches today — rest day ☁️")
                    .font(.system(size: 13))
                    .opacity(0.7)
            } else {
                ForEach(shown.prefix(6)) { fixture in
                    FixtureRow(fixture: fixture)
                }
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                session.mainScreen = .teamPicker
                openWindow(id: WindowID.main)
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Become a Fan", systemImage: "heart.circle.fill")
            }
            Button {
                session.mainScreen = .settings
                openWindow(id: WindowID.main)
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            Button {
                session.signOut()
            } label: {
                Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
            }
            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
            }
        }
        .buttonStyle(.hoverHighlight)
        .font(.system(size: 13))
    }

    private var signedOut: some View {
        VStack(spacing: 10) {
            Text("⚽ Sign in to follow your teams")
                .font(.system(size: 13, weight: .medium))
            Button("Sign in") {
                session.mainScreen = .login
                openWindow(id: WindowID.main)
                NSApp.activate(ignoringOtherApps: true)
            }
            .buttonStyle(.primaryPill)
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.hoverHighlight)
                .font(.caption)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

private struct FixtureRow: View {
    let fixture: Fixture
    @EnvironmentObject var session: AppSession
    @State private var hovering = false

    var body: some View {
        Button {
            NSWorkspace.shared.open(fixture.fifaURL)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                if hovering, let totals = session.celebrationTotals[fixture.fixtureId] {
                    // Hover: the row becomes the celebration tally — both
                    // teams, regardless of who you're a fan of.
                    Text("Celebrations 🎉")
                        .font(.system(size: 10))
                        .opacity(0.7)
                    HStack(spacing: 6) {
                        Text(flag(fixture.home.code))
                        Text((totals[fixture.home.code] ?? 0).formattedCompact)
                            .font(.system(size: 12, weight: .bold))
                        Text("–").font(.system(size: 12, weight: .bold))
                        Text((totals[fixture.away.code] ?? 0).formattedCompact)
                            .font(.system(size: 12, weight: .bold))
                        Text(flag(fixture.away.code))
                        Spacer()
                        trailing
                    }
                } else {
                    HStack(spacing: 6) {
                        Text(flag(fixture.home.code))
                        // Long names truncate with … — score, flags and the
                        // time on the right never get squeezed.
                        Text(fixture.home.name).font(.system(size: 12)).lineLimit(1)
                        Text(score).font(.system(size: 12, weight: .bold))
                            .fixedSize().layoutPriority(1)
                        Text(fixture.away.name).font(.system(size: 12)).lineLimit(1)
                        Text(flag(fixture.away.code))
                        Spacer()
                        trailing
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverHighlight)
        .onHover { over in
            withAnimation(.easeOut(duration: 0.15)) { hovering = over }
        }
    }

    private var score: String {
        fixture.status == "SCHEDULED"
            ? "vs"
            : "\(fixture.home.goals)–\(fixture.away.goals)"
    }

    /// The right edge is always about time: minute when live, kickoff time
    /// when scheduled, FT when done.
    @ViewBuilder private var trailing: some View {
        if fixture.isLive {
            HStack(spacing: 4) {
                Circle().fill(.red).frame(width: 6, height: 6)
                Text(fixture.minute.map { "\($0)′" } ?? "LIVE")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.red)
            }
        } else if fixture.status == "FINISHED" {
            Text("FT").font(.system(size: 10, weight: .semibold)).foregroundStyle(.green)
        } else if let kickoff = fixture.kickoff {
            Text(kickoff, style: .time).font(.system(size: 11)).opacity(0.7)
        }
    }

    private func flag(_ code: String) -> String {
        TeamCatalog.team(for: code, in: session.teams).flag
    }
}
