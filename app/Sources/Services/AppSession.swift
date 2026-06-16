import AppKit
import Foundation
import SwiftUI

/// Central app state: identity, prefs (UserDefaults = source of truth, backend
/// = roaming backup), team catalog, and today's fixtures.
@MainActor
final class AppSession: ObservableObject {
    static let shared = AppSession()

    @Published var profile: Profile?
    @Published var prefs: UserPrefs = .empty
    @Published var leagues: [League] = []
    @Published var teamsByLeague: [Int: [Team]] = [1: TeamCatalog.fallback]
    @Published var fixtures: [Fixture] = []
    @Published var celebrationTotals: [Int: [String: Int]] = [:]
    @Published var signInError: String?

    private var api: BackendAPI { Services.api }
    private var scores: ScoresProviding { Services.scores }
    private let defaults = UserDefaults.standard
    private var isBootstrappingFixtures = false
    /// Working set of fixtures keyed by id — the live poll loop merges into this
    /// and `publishFixtures()` projects the visible, sorted list into `fixtures`.
    private var fixturesById: [Int: Fixture] = [:]

    private enum CacheKey {
        static let fixtures = "cachedFixtures"
        static let celebrationTotals = "cachedCelebrationTotals"
        static let fixtureBootstrapDay = "fixtureBootstrapDay"
    }

    var isSignedIn: Bool { profile != nil }
    /// Every catalog team, flattened — for id→team lookups across leagues.
    var allTeams: [Team] { teamsByLeague.values.flatMap { $0 } }
    /// Alias used by the overlay/menu lookups (`TeamCatalog.team(for:in:)`).
    var teams: [Team] { allTeams }
    /// The single league users can follow today (World Cup); others are "coming soon".
    var activeLeagueId: Int { leagues.first(where: \.active)?.id ?? AppEnvironment.leagueId }
    var fanTeamIds: Set<Int> { Set(prefs.footballTeams.compactMap(Int.init)) }
    var fanTeams: [Team] {
        prefs.footballTeams.compactMap(Int.init).map { TeamCatalog.team(for: $0, in: allTeams) }
    }

    // MARK: Lifecycle

    func bootstrap() {
        AppLog.info(.app, "session_bootstrap_start")
        #if DEV_BACKEND
        // Sign-in bypass: already signed in before the first frame. Profile
        // and fan teams come from Dev/DevConfig.swift (code is the source of
        // truth), but settings still load from UserDefaults so your toggles
        // survive a relaunch — same as production.
        profile = DevConfig.profile
        prefs = FakeStore.shared.prefs
        if let data = defaults.data(forKey: "prefs"),
           let stored = try? JSONDecoder().decode(UserPrefs.self, from: data) {
            prefs.settings = stored.settings
        }
        #else
        if let data = defaults.data(forKey: "profile"),
           let stored = try? JSONDecoder().decode(Profile.self, from: data),
           Keychain.get("sessionToken") != nil {
            profile = stored
        }
        if let data = defaults.data(forKey: "prefs"),
           let stored = try? JSONDecoder().decode(UserPrefs.self, from: data) {
            prefs = stored
        }
        #endif
        if let data = defaults.data(forKey: CacheKey.fixtures),
           let stored = try? JSONDecoder().decode([Fixture].self, from: data) {
            fixtures = stored
            fixturesById = Dictionary(uniqueKeysWithValues: stored.map { ($0.fixtureId, $0) })
        }
        if let data = defaults.data(forKey: CacheKey.celebrationTotals),
           let stored = try? JSONDecoder().decode([Int: [String: Int]].self, from: data) {
            celebrationTotals = stored
        }
        Task { await refreshCatalog() }
        // Fan teams sync with the backend ONCE per app start; every other
        // read is local. Changes go up via setFanTeams as they happen.
        Task { await syncFanTeamsOnLaunch() }
        // Always-on live polling: one loop, running whenever a fan match is in
        // its live window — no menu, no push.
        LiveStore.shared.start()
        AppLog.info(.app, "session_bootstrap_complete signed_in=\(isSignedIn) fan_teams=\(fanTeamIds.sorted()) cached_fixtures=\(fixtures.count)")
    }

    /// One launch-time reconciliation: server teams win on a fresh machine,
    /// local teams backfill an empty server. Never called again until the
    /// next launch — the menu always reads from local state.
    private func syncFanTeamsOnLaunch() async {
        guard isSignedIn, ControlPlane.shared.isOperational else {
            AppLog.debug(.prefs, "fan_sync_skipped signed_in=\(isSignedIn) operational=\(ControlPlane.shared.isOperational)")
            return
        }
        AppLog.info(.prefs, "fan_sync_start local=\(prefs.footballTeams.sorted())")
        let server: UserPrefs
        do {
            server = try await api.fetchPrefs()
        } catch {
            AppLog.error(.prefs, "fan_sync_fetch_failed", error: error)
            return
        }
        guard isSignedIn, ControlPlane.shared.isOperational else { return }
        let serverTeams = server.fanOf["football"]?[String(AppEnvironment.leagueId)] ?? []
        if !serverTeams.isEmpty && prefs.footballTeams.isEmpty {
            prefs.fanOf = server.fanOf
            persistPrefs()
            AppLog.info(.prefs, "fan_sync_adopted_server teams=\(serverTeams.sorted())")
        } else if serverTeams != prefs.footballTeams {
            guard ControlPlane.shared.isOperational else { return }
            do {
                try await api.putPrefs(roamingPrefs)
                AppLog.info(.prefs, "fan_sync_uploaded_local teams=\(prefs.footballTeams.sorted())")
            } catch {
                AppLog.error(.prefs, "fan_sync_upload_failed", error: error)
            }
        }
        guard isSignedIn, ControlPlane.shared.isOperational else { return }
        AppLog.info(.prefs, "fan_sync_complete teams=\(fanTeamIds.sorted())")
    }

    // MARK: Sign in / out

    func signInWithGoogle(presenting window: NSWindow?) {
        guard ControlPlane.shared.isOperational else {
            signInError = "Sign-in is unavailable while the app is temporarily disabled."
            return
        }
        signInError = nil
        Task {
            do {
                let idToken = try await Services.google.signIn(presenting: window)
                guard ControlPlane.shared.isOperational else {
                    Services.google.signOut()
                    return
                }
                let response = try await api.signIn(googleIdToken: idToken)
                guard ControlPlane.shared.isOperational else {
                    Services.google.signOut()
                    return
                }
                Keychain.set(response.token, for: "sessionToken")
                profile = response.profile
                persist(profile: response.profile)
                // Fan teams come from the account: sign-out cleared the local
                // copy, so adopt whatever roams on the server (never push a
                // previous user's leftovers up). Settings stay device-local.
                prefs.fanOf = response.prefs.fanOf
                persistPrefs()
                await refreshCatalog()
                AppLog.info(.app, "sign_in_complete fan_teams=\(fanTeamIds.sorted())")
            } catch {
                signInError = error.localizedDescription
                AppLog.error(.app, "sign_in_failed", error: error)
            }
        }
    }

    /// What gets synced to the backend: fan teams only. Settings (theme,
    /// celebration style, event toggles…) live in UserDefaults on this Mac.
    private var roamingPrefs: UserPrefs {
        UserPrefs(fanOf: prefs.fanOf, settings: PrefSettings())
    }

    func signOut() {
        clearSession(showLogin: true)
    }

    /// `showLogin` is false for control-plane gates, which are shown the next
    /// time the menu opens.
    func clearSession(showLogin: Bool) {
        AppLog.info(.app, "session_clear show_login=\(showLogin)")
        stopAllActivity()
        Services.google.signOut()
        Keychain.delete("sessionToken")
        defaults.removeObject(forKey: "profile")
        profile = nil
        // Fan teams belong to the ACCOUNT (they roam via the backend), so
        // they leave with it — whoever signs in next starts from their own
        // server prefs. Settings belong to the DEVICE and stay.
        prefs.fanOf = UserPrefs.empty.fanOf
        persistPrefs()
        // Signed out = silent: drop the diff baseline so the next account never
        // replays this one's transitions, and clear anything on screen.
        LiveStore.shared.resetBaseline()
        OverlayManager.shared.dismissAll()
        if showLogin { openWindow(WindowID.login) }
    }

    /// Closes the menu (killing its refresh timer). Leaves ControlPlane polling
    /// so the app can recover from a remote gate.
    func stopAllActivity() {
        MenuPopoverController.shared.close()
    }

    func deleteAccount() async {
        do {
            try await api.deleteAccount()
            AppLog.info(.app, "account_delete_complete")
        } catch {
            AppLog.error(.app, "account_delete_failed", error: error)
        }
        signOut() // clears fan teams + topics; device settings stay
    }

    // MARK: Prefs

    func setFanTeams(_ ids: [String]) {
        AppLog.info(.prefs, "fan_teams_changed old=\(prefs.footballTeams.sorted()) new=\(ids.sorted())")
        prefs.footballTeams = ids
        persistPrefs()
        Task {
            guard ControlPlane.shared.isOperational else { return }
            do {
                try await api.putPrefs(roamingPrefs)
                AppLog.info(.prefs, "fan_teams_upload_complete teams=\(ids.sorted())")
            } catch {
                AppLog.error(.prefs, "fan_teams_upload_failed", error: error)
            }
        }
    }

    /// Settings are device-local: persisted to UserDefaults, never sent to
    /// the backend — only fan teams are worth a database row.
    func updateSettings(_ mutate: (inout PrefSettings) -> Void) {
        mutate(&prefs.settings)
        persistPrefs()
    }

    private func persistPrefs() {
        if let data = try? JSONEncoder().encode(prefs) {
            defaults.set(data, forKey: "prefs")
        }
    }

    private func persist(profile: Profile) {
        if let data = try? JSONEncoder().encode(profile) {
            defaults.set(data, forKey: "profile")
        }
    }

    // MARK: Data refresh

    func refreshCatalog() async {
        guard isSignedIn, ControlPlane.shared.isOperational else {
            AppLog.debug(.catalog, "refresh_skipped signed_in=\(isSignedIn) operational=\(ControlPlane.shared.isOperational)")
            return
        }
        AppLog.info(.catalog, "refresh_start")
        let catalog: Catalog
        do {
            catalog = try await scores.fetchCatalog()
        } catch {
            AppLog.error(.catalog, "refresh_failed", error: error)
            return
        }
        guard isSignedIn, ControlPlane.shared.isOperational, !catalog.leagues.isEmpty else {
            AppLog.info(.catalog, "refresh_discarded signed_in=\(isSignedIn) operational=\(ControlPlane.shared.isOperational) leagues=\(catalog.leagues.count)")
            return
        }
        leagues = catalog.leagues
        teamsByLeague = Dictionary(
            uniqueKeysWithValues: catalog.leagues.map { ($0.id, catalog.teams(for: $0.id)) },
        )
        AppLog.info(.catalog, "refresh_complete leagues=\(leagues.count) teams=\(allTeams.count)")
    }

    /// Manual refresh (the menu's ↻ button): force a schedule re-bootstrap and
    /// re-publish. Live scores still flow from `LiveStore`'s poll loop.
    func refreshFixtures() async {
        await bootstrapFixturesIfNeeded(force: true)
        publishFixtures()
    }

    /// The schedule bootstrap: once per day, read `fixtures-{date}.json` for
    /// today±1 (12h TTL) for kickoff times + which fan matches play. Live scores
    /// are never read from here — that's the poll loop's job. Never overwrites a
    /// live-polled fixture with a (possibly stale) schedule row.
    func bootstrapFixturesIfNeeded(force: Bool = false) async {
        guard isSignedIn, ControlPlane.shared.isOperational, !isBootstrappingFixtures else { return }
        let now = Date()
        let bootstrapDay = ISO8601DateFormatter.dateOnly.string(from: now)
        if !force, defaults.string(forKey: CacheKey.fixtureBootstrapDay) == bootstrapDay {
            return
        }
        isBootstrappingFixtures = true
        defer { isBootstrappingFixtures = false }

        let calendar = Calendar.current
        AppLog.info(.fixtures, "bootstrap_start cached=\(fixturesById.count) fan_teams=\(fanTeamIds.sorted())")
        let dates = [-1, 0, 1].compactMap { calendar.date(byAdding: .day, value: $0, to: now) }
        var loadedAny = false
        for date in dates {
            guard isSignedIn, ControlPlane.shared.isOperational else { return }
            let fetched: [Fixture]
            do {
                fetched = try await scores.fetchFixtures(date: date)
                AppLog.info(.fixtures, "date_bootstrap_complete date=\(ISO8601DateFormatter.dateOnly.string(from: date)) fixtures=\(fetched.count)")
            } catch ScoresError.notModified {
                loadedAny = true
                continue
            } catch {
                AppLog.error(.fixtures, "date_bootstrap_failed date=\(ISO8601DateFormatter.dateOnly.string(from: date))", error: error)
                continue
            }
            guard isSignedIn, ControlPlane.shared.isOperational else { return }
            loadedAny = true
            for fixture in fetched {
                // Don't clobber a fixture the live loop is actively polling — the
                // schedule file can be up to 12h stale on score/status.
                if fixturesById[fixture.fixtureId]?.needsFrequentRefresh(at: now) == true {
                    continue
                }
                fixturesById[fixture.fixtureId] = fixture
            }
        }
        if loadedAny {
            defaults.set(bootstrapDay, forKey: CacheKey.fixtureBootstrapDay)
        }
        publishFixtures()
        AppLog.info(.fixtures, "bootstrap_complete fixtures=\(fixturesById.count)")
    }

    /// Merge one freshly-polled live fixture into the working set. Called by
    /// `LiveStore` each poll cycle; `publishFixtures()` projects the visible list.
    func applyLiveFixture(_ fixture: Fixture) {
        fixturesById[fixture.fixtureId] = fixture
    }

    /// Project the working set into the published, sorted, visible `fixtures`
    /// list and persist it. Visible = kicks off today, or a live fan match.
    func publishFixtures() {
        let calendar = Calendar.current
        let now = Date()
        fixtures = fixturesById.values
            .filter { fixture in
                fixture.kickoff.map { calendar.isDate($0, inSameDayAs: now) } == true
                    || (fixture.isLive && fixture.involves(fanTeamIds))
            }
            .sorted { ($0.kickoff ?? .distantFuture) < ($1.kickoff ?? .distantFuture) }
        persistFixtureCache()
    }

    /// Optimistically fold the user's own taps into the local total so their
    /// celebration shows instantly, before the server round-trip. The later
    /// server merge uses max(), so this never double-counts.
    func addLocalCelebrations(_ taps: Int, teamId: String, fixtureId: Int) {
        guard taps > 0 else { return }
        var cached = celebrationTotals[fixtureId] ?? [:]
        cached[teamId] = (cached[teamId] ?? 0) + taps
        celebrationTotals[fixtureId] = cached
        persistCelebrationCache()
        AppLog.info(.celebrations, "local_taps_merged fixture_id=\(fixtureId) team_id=\(teamId) taps=\(taps)")
    }

    func mergeCelebrationTotals(_ totals: [String: Int], fixtureId: Int) {
        var cached = celebrationTotals[fixtureId] ?? [:]
        for (teamId, total) in totals {
            cached[teamId] = max(cached[teamId] ?? 0, total)
        }
        celebrationTotals[fixtureId] = cached
        persistCelebrationCache()
        AppLog.info(.celebrations, "totals_merged fixture_id=\(fixtureId) totals=\(cached)")
    }

    private func persistFixtureCache() {
        if let data = try? JSONEncoder().encode(fixtures) {
            defaults.set(data, forKey: CacheKey.fixtures)
        }
    }

    private func persistCelebrationCache() {
        if let data = try? JSONEncoder().encode(celebrationTotals) {
            defaults.set(data, forKey: CacheKey.celebrationTotals)
        }
    }
}
