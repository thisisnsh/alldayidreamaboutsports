import SwiftUI

/// The menu bar dropdown: "Fan of" flags, today's fixtures for
/// followed teams (live scores), and actions.
struct MenuPopoverView: View {
    @EnvironmentObject var session: AppSession
    @ObservedObject private var control = ControlPlane.shared
    @Environment(\.openWindow) private var openWindow
    /// Which slice of today the fixture list shows. Stored locally rather than
    /// in `prefs` — it's a view preference for this Mac, not synced state, and
    /// the menu rebuilds its view on every open so it has to outlive that.
    @AppStorage("menuFixtureScope", store: AppDefaults.shared) private var fixtureScope: FixtureScope = .mine
    /// The analytics screen name for everything in this popover, including the
    /// controls that live outside this file (the status-item controller, the
    /// capsule pin). The `screen_view` itself is fired by
    /// `MenuPopoverController.showMenu()` — the hosting controller is built once
    /// and reused, so `.onAppear` here would only ever fire once per launch.
    static let screen = "menu"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if control.killSwitch {
                maintenance
            } else if control.updateRequired {
                forcedUpdate
            } else {
                // A soft "Update available" nudge sits atop the normal menu —
                // the app still works, so unlike `updateRequired` it doesn't
                // replace the content.
                if control.updateAvailable {
                    updateBanner
                }
                header
                if !session.fanTeams.isEmpty {
                    fanOfRow
                }
                Divider()
                fixturesSection
                Divider()
                actions
            }
        }
        .padding(16)
        .frame(width: 320)
        .background(AppBackground())
        .installsWindowOpener()
        .appTheme(session.prefs.settings.theme ?? .system)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "soccerball")
                .font(.system(size: 22))
                .frame(width: 36, height: 36)
            Text("All Day I Dream About Sports").font(.system(size: 14, weight: .semibold))
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
            let shown = shownFixtures
            HStack {
                Text(fixtureScope == .mine ? "Today's live scores" : "Today's matches")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .opacity(0.7)
                Spacer()
                FixtureScopePicker(scope: $fixtureScope)
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
            if shown.isEmpty {
                Text(emptyMessage)
                    .font(.system(size: 13))
                    .opacity(0.7)
            } else if shown.count <= Self.unscrolledRows {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(shown) { fixture in
                        FixtureRow(fixture: fixture, live: fixtureScope == .mine)
                    }
                }
            } else {
                // "All Teams" is a whole matchday across five leagues (~30-50
                // rows) — scroll it rather than growing the menu past the
                // bottom of the screen.
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(shown) { fixture in
                            FixtureRow(fixture: fixture, live: fixtureScope == .mine)
                        }
                    }
                    // Keeps the first and last row clear of the fades, so a
                    // list parked at either end reads at full strength.
                    .padding(.vertical, Self.fadeInset)
                }
                .frame(height: Self.scrolledHeight + 2 * Self.fadeInset)
                // Rows dissolve into the menu at both ends instead of being
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
                // The inset is bled back out of the surrounding margins, so the
                // fades live in the gaps either side and the first row starts
                // exactly where the unscrolled list's does — the section keeps
                // the same footprint whether or not it scrolls.
                .padding(.vertical, -Self.fadeInset)
            }
        }
    }

    /// How many rows fit before the list starts scrolling, and the height it
    /// settles at then. A row is ~42pt with 8pt between, so the scrolling list
    /// is five rows plus a peek of the sixth — the cue that it scrolls. Both
    /// stay under the old `.prefix(6)` list's height, which is what the
    /// popover's fixed content size (`MenuPopoverController.showMenu`) is
    /// budgeted for: go past it and the last row loses its subtitle line.
    private static let unscrolledRows = 5
    private static let scrolledHeight: CGFloat = 5 * 42 + 4 * 8 + 20
    /// The top and bottom fades: short enough to read as a soft edge rather
    /// than a dimmed row, with a slightly taller inset behind them so a row at
    /// rest sits clear of the gradient. The inset is padding *outside* the
    /// height above — it overhangs into the section's margins rather than
    /// eating rows.
    private static let fadeHeight: CGFloat = 10
    private static let fadeInset: CGFloat = 12

    private var shownFixtures: [Fixture] {
        switch fixtureScope {
        case .mine: return session.fixtures
        case .all: return session.todayFixtures
        }
    }

    /// Nothing to list: either football is off entirely today, or it's on but
    /// none of it is theirs (only reachable in "My Teams").
    private var emptyMessage: String {
        session.hasFixturesToday
            ? "None of your teams play today 💤"
            : "No matches today — rest day ☁️"
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                AppAnalytics.teamPickerOpened()
                Task { await session.refreshCatalog() }
                dismissMenu()
                openWindow(id: WindowID.teamPicker)
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Become a Fan", systemImage: "heart.circle.fill")
            }
            Button {
                AppAnalytics.featureRequested()
                dismissMenu()
                NSWorkspace.shared.open(requestFeatureURL)
            } label: {
                Label("Request a feature", systemImage: "checklist.unchecked")
            }
            Button {
                AppAnalytics.bugReported(state: "normal")
                dismissMenu()
                NSWorkspace.shared.open(reportBugURL)
            } label: {
                Label("Report a bug", systemImage: "ladybug")
            }
            Button {
                AppAnalytics.settingsOpened()
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

    /// The Quit buttons in this menu are the same action from two different
    /// states — kill switch, forced update — so they share the one event and
    /// are told apart by `source`.
    private func quit(source: String) {
        AppAnalytics.appQuit(source: source)
        NSApp.terminate(nil)
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
                AppAnalytics.bugReported(state: "kill_switch")
                dismissMenu()
                NSWorkspace.shared.open(reportBugURL)
            } label: {
                Label("Report a bug", systemImage: "ladybug")
            }
            .buttonStyle(.primaryPill)
            Button("Quit") { quit(source: "menu_kill_switch") }
                .buttonStyle(.hoverHighlight)
                .font(.caption)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    /// Top-of-menu nudge when a newer build exists. The button opens the same
    /// Update window the forced path uses, whose "Update now" opens the App
    /// Store like the "Check for Updates" button in Settings.
    private var updateBanner: some View {
        Button {
            AppAnalytics.updateBannerTapped()
            dismissMenu()
            openWindow(id: WindowID.update)
            NSApp.activate(ignoringOtherApps: true)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Update available")
                        .font(.system(size: 13, weight: .semibold))
                    Text("A newer version is ready to install.")
                        .font(.system(size: 11))
                        .opacity(0.7)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .opacity(0.5)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverHighlight)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.accentColor.opacity(0.12))
        )
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
                openWindow(id: WindowID.update)
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Update now", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.primaryPill)
            Button("Quit") { quit(source: "menu_update_required") }
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
        // The row is hover-only (reveals the pin
        // affordance) — clicking it no longer navigates anywhere; the FIFA page
        // was rarely what people wanted and stole focus from the menu.
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
        TeamCatalog.team(for: id, in: session.teams).logo
    }

    private func shortName(_ team: ScoreboardTeam) -> String {
        TeamCatalog.shortName(for: team.id, in: session.teams, fallback: team.name)
    }
}
