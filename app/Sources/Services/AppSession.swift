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
    private var isRefreshingFixtures = false

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
        }
        if let data = defaults.data(forKey: CacheKey.celebrationTotals),
           let stored = try? JSONDecoder().decode([Int: [String: Int]].self, from: data) {
            celebrationTotals = stored
        }
        Task { await refreshCatalog() }
        // Fan teams sync with the backend ONCE per app start; every other
        // read is local. Changes go up via setFanTeams as they happen.
        Task { await syncFanTeamsOnLaunch() }
        // Topics mirror the signed-in state: signed out means subscribed to
        // nothing, even if fan teams are still stored locally.
        PushService.shared.syncTopics(to: isSignedIn ? fanTeamIds : [])
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
        PushService.shared.syncTopics(to: fanTeamIds)
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
                PushService.shared.syncTopics(to: fanTeamIds)
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
        // Signed out = silent: no topics, nothing left on screen.
        PushService.shared.syncTopics(to: [])
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
        PushService.shared.syncTopics(to: Set(ids.compactMap(Int.init)))
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

    func refreshFixtures() async {
        guard isSignedIn, ControlPlane.shared.isOperational, !isRefreshingFixtures else {
            AppLog.debug(.fixtures, "refresh_skipped signed_in=\(isSignedIn) operational=\(ControlPlane.shared.isOperational) in_flight=\(isRefreshingFixtures)")
            return
        }
        isRefreshingFixtures = true
        defer { isRefreshingFixtures = false }

        let calendar = Calendar.current
        let now = Date()
        var byId = Dictionary(uniqueKeysWithValues: fixtures.map { ($0.fixtureId, $0) })
        AppLog.info(.fixtures, "refresh_start cached=\(fixtures.count) fan_teams=\(fanTeamIds.sorted())")

        // Date files are the schedule bootstrap only. The frequent loop below
        // polls individual match objects, not three full days of fixtures.
        let bootstrapDay = ISO8601DateFormatter.dateOnly.string(from: now)
        if defaults.string(forKey: CacheKey.fixtureBootstrapDay) != bootstrapDay {
            let dates = [-1, 0, 1].compactMap { calendar.date(byAdding: .day, value: $0, to: now) }
            var loadedAny = false
            for date in dates {
                guard isSignedIn, ControlPlane.shared.isOperational else { return }
                let fetched: [Fixture]
                do {
                    fetched = try await scores.fetchFixtures(date: date)
                    AppLog.info(.fixtures, "date_refresh_complete date=\(ISO8601DateFormatter.dateOnly.string(from: date)) fixtures=\(fetched.count)")
                } catch {
                    AppLog.error(.fixtures, "date_refresh_failed date=\(ISO8601DateFormatter.dateOnly.string(from: date))", error: error)
                    continue
                }
                guard isSignedIn, ControlPlane.shared.isOperational else { return }
                loadedAny = true
                for fixture in fetched {
                    // Preserve an active cached score until its individual
                    // match read below, so a date bootstrap cannot hide a goal
                    // transition and skip the corresponding celebration read.
                    if byId[fixture.fixtureId]?.needsFrequentRefresh(at: now) == true {
                        continue
                    }
                    byId[fixture.fixtureId] = fixture
                }
            }
            if loadedAny {
                defaults.set(bootstrapDay, forKey: CacheKey.fixtureBootstrapDay)
            }
        }

        guard isSignedIn, ControlPlane.shared.isOperational else { return }
        let refreshTargets = byId.values.filter {
            $0.involves(fanTeamIds) && $0.needsFrequentRefresh(at: now)
        }
        AppLog.info(.fixtures, "live_refresh_targets count=\(refreshTargets.count) ids=\(refreshTargets.map(\.fixtureId).sorted())")
        for previous in refreshTargets {
            guard isSignedIn, ControlPlane.shared.isOperational else { return }
            let current: Fixture
            do {
                current = try await scores.fetchFixture(fixtureId: previous.fixtureId)
                AppLog.info(.fixtures, "fixture_refresh_complete fixture_id=\(current.fixtureId) old_status=\(previous.status) new_status=\(current.status) old_score=\(previous.home.goals)-\(previous.away.goals) new_score=\(current.home.goals)-\(current.away.goals)")
            } catch {
                AppLog.error(.fixtures, "fixture_refresh_failed fixture_id=\(previous.fixtureId)", error: error)
                continue
            }
            guard isSignedIn, ControlPlane.shared.isOperational else { return }
            byId[current.fixtureId] = current

            // Celebration totals only need a CDN read when a goal/VAR
            // correction changes the score.
            if previous.score != current.score {
                do {
                    let totals = try await scores.fetchCelebrations(fixtureId: current.fixtureId)
                    guard isSignedIn, ControlPlane.shared.isOperational else { return }
                    AppLog.info(.celebrations, "score_change_totals_refresh fixture_id=\(current.fixtureId) teams=\(totals.count)")
                    mergeCelebrationTotals(totals, fixtureId: current.fixtureId)
                } catch {
                    AppLog.error(.celebrations, "score_change_totals_refresh_failed fixture_id=\(current.fixtureId)", error: error)
                }
            }
        }

        guard isSignedIn, ControlPlane.shared.isOperational else { return }
        fixtures = byId.values
            .filter { fixture in
                fixture.kickoff.map { calendar.isDate($0, inSameDayAs: now) } == true
                    || (fixture.isLive && fixture.involves(fanTeamIds))
            }
            .sorted { ($0.kickoff ?? .distantFuture) < ($1.kickoff ?? .distantFuture) }
        persistFixtureCache()
        AppLog.info(.fixtures, "refresh_complete visible=\(fixtures.count)")
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
