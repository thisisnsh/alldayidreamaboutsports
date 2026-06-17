import SwiftUI

/// The menu bar dropdown: profile, "Fan of" flags, today's fixtures for
/// followed teams (live scores + celebration counts), and actions.
struct MenuPopoverView: View {
    @EnvironmentObject var session: AppSession
    @ObservedObject private var control = ControlPlane.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if control.killSwitch {
                maintenance
            } else if control.updateRequired {
                forcedUpdate
            } else if let profile = session.profile {
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
            Text("Fan of").font(.caption).opacity(0.7).fixedSize()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(session.fanTeams) { team in
                        CachedTeamLogo(url: team.logo, size: 18)
                    }
                }
            }
        }
    }

    private var fixturesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Today's matches")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .opacity(0.7)
                Spacer()
                // Hidden for now — `refreshFixtures()` and its wiring stay intact;
                // re-enable when we revisit the manual refresh UX.
                if false {
                    Button {
                        Task { await session.refreshFixtures() }
                    } label: {
                        Image(systemName: "arrow.clockwise").font(.caption).opacity(0.5)
                    }
                    .buttonStyle(.plain)
                }
            }
            let shown = session.fixtures.filter { $0.involves(session.fanTeamIds) }
            if shown.isEmpty {
                Text(session.fixtures.isEmpty
                     ? "No matches today — rest day ☁️"
                     : "None of your teams play today 💤")
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
                Task { await session.refreshCatalog() }
                dismissMenu()
                openWindow(id: WindowID.teamPicker)
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Become a Fan", systemImage: "heart.circle.fill")
            }
            Button {
                dismissMenu()
                NSWorkspace.shared.open(requestFeatureURL)
            } label: {
                Label("Request a feature", systemImage: "checklist.unchecked")
            }
            Button {
                dismissMenu()
                NSWorkspace.shared.open(reportBugURL)
            } label: {
                Label("Report a bug", systemImage: "ladybug")
            }
            Button {
                dismissMenu()
                openWindow(id: WindowID.settings)
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
        }
        // Icons vary in width (the lightbulb is narrow); pin every glyph to the
        // same column so the labels line up.
        .labelStyle(.fixedIcon)
        .buttonStyle(.hoverHighlight)
        .font(.system(size: 13))
    }

    /// Closes the open MenuBarExtra panel. The window-style menu has no SwiftUI
    /// dismiss action, so we close the panel directly — it's the key window
    /// while the menu is showing, and SwiftUI rebuilds it on the next open.
    private func dismissMenu() {
        MenuPopoverController.shared.close()
    }

    /// A pre-filled support email — the app repo is private, so there's no
    /// public issue tracker to point at. Build + OS go in the body so reports
    /// arrive with the version already attached.
    private var reportBugURL: URL {
        supportMail(subject: "Bug report — All Day I Dream About Sports")
    }

    /// Same support inbox, framed for feature ideas instead of bugs.
    private var requestFeatureURL: URL {
        supportMail(subject: "Feature request — All Day I Dream About Sports")
    }

    private func supportMail(subject: String) -> URL {
        let body = """


        ———
        \(AppEnvironment.profileName) \(AppEnvironment.appVersion) (Build \(AppEnvironment.buildNumber))
        macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
        """
        func encode(_ s: String) -> String {
            s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
        }
        return URL(string: "mailto:\(AppEnvironment.supportEmail)?subject=\(encode(subject))&body=\(encode(body))")!
    }

    private var signedOut: some View {
        VStack(spacing: 10) {
            Text("⚽ Sign in to follow your teams")
                .font(.system(size: 13, weight: .medium))
            Button("Sign in") {
                dismissMenu()
                openWindow(id: WindowID.login)
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

    private var maintenance: some View {
        VStack(spacing: 14) {
            Image(systemName: "wrench.and.screwdriver.fill")
                .font(.system(size: 32))
            Text("Hold on…")
                .font(.system(size: 18, weight: .bold, design: .rounded))
            Text(control.killMessage.isEmpty
                 ? "We're fixing something — back soon."
                 : control.killMessage)
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 260)
                .opacity(0.8)
            Button {
                dismissMenu()
                NSWorkspace.shared.open(reportBugURL)
            } label: {
                Label("Report a bug", systemImage: "ladybug")
            }
            .buttonStyle(.primaryPill)
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.hoverHighlight)
                .font(.caption)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private var forcedUpdate: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 32))
            Text("Update required")
                .font(.system(size: 18, weight: .bold, design: .rounded))
            Text("This version is too old to keep up with the matches. Update to keep celebrating.")
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 260)
                .opacity(0.8)
            Button {
                dismissMenu()
                if let appDelegate = NSApp.delegate as? AppDelegate {
                    appDelegate.updaterController.checkForUpdates(nil)
                }
            } label: {
                Label("Update now", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.primaryPill)
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.hoverHighlight)
                .font(.caption)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}

/// Lines menu-row labels up by pinning each icon to a fixed-width column —
/// SF Symbols like `lightbulb` are narrower than `gearshape`, so without this
/// the text would start at different x positions per row.
private struct FixedIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon
                .frame(width: 18, alignment: .center)
            configuration.title
        }
    }
}

extension LabelStyle where Self == FixedIconLabelStyle {
    static var fixedIcon: FixedIconLabelStyle { .init() }
}

private struct FixtureRow: View {
    let fixture: Fixture
    @EnvironmentObject var session: AppSession
    @State private var hovering = false

    var body: some View {
        // The row is hover-only (reveals the celebration tally) — clicking it
        // no longer navigates anywhere; the FIFA page was rarely what people
        // wanted and stole focus from the menu.
        Button {
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                if hovering, let totals = session.celebrationTotals[fixture.fixtureId] {
                    // Hover: the row becomes the celebration tally — both
                    // teams, regardless of who you're a fan of.
                    HStack(spacing: 6) {
                        CachedTeamLogo(url: logo(fixture.home.id), size: 16)
                        Text((totals[String(fixture.home.id)] ?? 0).formattedCompact)
                            .font(.system(size: 12, weight: .bold))
                        Text("–").font(.system(size: 12, weight: .bold))
                        Text((totals[String(fixture.away.id)] ?? 0).formattedCompact)
                            .font(.system(size: 12, weight: .bold))
                        CachedTeamLogo(url: logo(fixture.away.id), size: 16)
                        Spacer()
                        trailing
                    }
                    Text("Celebrations 🎉")
                        .font(.system(size: 10))
                        .opacity(0.7)
                } else {
                    HStack(spacing: 6) {
                        CachedTeamLogo(url: logo(fixture.home.id), size: 16)
                        // Long names truncate with … — score, logos and the
                        // time on the right never get squeezed.
                        Text(fixture.home.name).font(.system(size: 12)).lineLimit(1)
                        Text(score).font(.system(size: 12, weight: .bold))
                            .fixedSize().layoutPriority(1)
                        Text(fixture.away.name).font(.system(size: 12)).lineLimit(1)
                        CachedTeamLogo(url: logo(fixture.away.id), size: 16)
                        Spacer()
                        trailing
                    }
                    if let stage = fixture.stageLabel {
                        Text(stage).font(.system(size: 10)).opacity(0.6)
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
        if fixture.status == "SCHEDULED" { return "vs" }
        let goals = "\(fixture.home.goals)–\(fixture.away.goals)"
        // A shootout isn't in the goals count — show it alongside (e.g. 3–3 · pens 4–2).
        if let pso = fixture.shootout {
            return "\(goals) · pens \(pso.home)–\(pso.away)"
        }
        return goals
    }

    /// The right edge is always about time: minute when live, kickoff time
    /// when scheduled, FT when done.
    @ViewBuilder private var trailing: some View {
        if fixture.isLive {
            HStack(spacing: 4) {
                Circle().fill(.red).frame(width: 6, height: 6)
                Text(fixture.liveMinuteText)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.red)
            }
        } else if fixture.status == "FINISHED" {
            Text("FT").font(.system(size: 10, weight: .semibold)).foregroundStyle(.green)
        } else if let kickoff = fixture.kickoff {
            Text(kickoff, style: .time).font(.system(size: 11)).opacity(0.7)
        }
    }

    private func logo(_ id: Int) -> String {
        TeamCatalog.team(for: id, in: session.teams).logo
    }
}
