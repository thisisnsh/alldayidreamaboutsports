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
    }

    /// One launch-time reconciliation: server teams win on a fresh machine,
    /// local teams backfill an empty server. Never called again until the
    /// next launch — the menu always reads from local state.
    private func syncFanTeamsOnLaunch() async {
        guard isSignedIn, ControlPlane.shared.isOperational,
              let server = try? await api.fetchPrefs(),
              isSignedIn, ControlPlane.shared.isOperational else { return }
        let serverTeams = server.fanOf["football"]?[String(AppEnvironment.leagueId)] ?? []
        if !serverTeams.isEmpty && prefs.footballTeams.isEmpty {
            prefs.fanOf = server.fanOf
            persistPrefs()
        } else if serverTeams != prefs.footballTeams {
            guard ControlPlane.shared.isOperational else { return }
            try? await api.putPrefs(roamingPrefs)
        }
        guard isSignedIn, ControlPlane.shared.isOperational else { return }
        PushService.shared.syncTopics(to: fanTeamIds)
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
            } catch {
                signInError = error.localizedDescription
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
        try? await api.deleteAccount()
        signOut() // clears fan teams + topics; device settings stay
    }

    // MARK: Prefs

    func setFanTeams(_ ids: [String]) {
        prefs.footballTeams = ids
        persistPrefs()
        PushService.shared.syncTopics(to: Set(ids.compactMap(Int.init)))
        Task {
            guard ControlPlane.shared.isOperational else { return }
            try? await api.putPrefs(roamingPrefs)
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
        guard isSignedIn, ControlPlane.shared.isOperational else { return }
        guard let catalog = try? await scores.fetchCatalog(),
              isSignedIn, ControlPlane.shared.isOperational,
              !catalog.leagues.isEmpty else { return }
        leagues = catalog.leagues
        teamsByLeague = Dictionary(
            uniqueKeysWithValues: catalog.leagues.map { ($0.id, catalog.teams(for: $0.id)) },
        )
    }

    func refreshFixtures() async {
        guard isSignedIn, ControlPlane.shared.isOperational, !isRefreshingFixtures else { return }
        isRefreshingFixtures = true
        defer { isRefreshingFixtures = false }

        let calendar = Calendar.current
        let now = Date()
        var byId = Dictionary(uniqueKeysWithValues: fixtures.map { ($0.fixtureId, $0) })

        // Date files are the schedule bootstrap only. The frequent loop below
        // polls individual match objects, not three full days of fixtures.
        let bootstrapDay = ISO8601DateFormatter.dateOnly.string(from: now)
        if defaults.string(forKey: CacheKey.fixtureBootstrapDay) != bootstrapDay {
            let dates = [-1, 0, 1].compactMap { calendar.date(byAdding: .day, value: $0, to: now) }
            var loadedAny = false
            for date in dates {
                guard isSignedIn, ControlPlane.shared.isOperational else { return }
                guard let fetched = try? await scores.fetchFixtures(date: date) else { continue }
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
        for previous in refreshTargets {
            guard isSignedIn, ControlPlane.shared.isOperational else { return }
            guard let current = try? await scores.fetchFixture(fixtureId: previous.fixtureId) else { continue }
            guard isSignedIn, ControlPlane.shared.isOperational else { return }
            byId[current.fixtureId] = current

            // Celebration totals only need a CDN read when a goal/VAR
            // correction changes the score.
            if previous.score != current.score,
               let totals = try? await scores.fetchCelebrations(fixtureId: current.fixtureId) {
                guard isSignedIn, ControlPlane.shared.isOperational else { return }
                mergeCelebrationTotals(totals, fixtureId: current.fixtureId)
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
    }

    func mergeCelebrationTotals(_ totals: [String: Int], fixtureId: Int) {
        var cached = celebrationTotals[fixtureId] ?? [:]
        for (teamId, total) in totals {
            cached[teamId] = max(cached[teamId] ?? 0, total)
        }
        celebrationTotals[fixtureId] = cached
        persistCelebrationCache()
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
