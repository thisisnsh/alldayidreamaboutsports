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
    @Published var liveMatches: [Fixture] = []
    @Published var celebrationTotals: [Int: [String: Int]] = [:]
    @Published var signInError: String?

    private var api: BackendAPI { Services.api }
    private var scores: ScoresProviding { Services.scores }
    private let defaults = UserDefaults.standard
    private var fixturesTimer: Timer?

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
        Task { await refreshCatalog() }
        Task { await refreshFixtures() }
        // Fan teams sync with the backend ONCE per app start; every other
        // read is local. Changes go up via setFanTeams as they happen.
        Task { await syncFanTeamsOnLaunch() }
        startFixturesTimer()
        // Topics mirror the signed-in state: signed out means subscribed to
        // nothing, even if fan teams are still stored locally.
        PushService.shared.syncTopics(to: isSignedIn ? fanTeamIds : [])
    }

    /// One launch-time reconciliation: server teams win on a fresh machine,
    /// local teams backfill an empty server. Never called again until the
    /// next launch — the menu always reads from local state.
    private func syncFanTeamsOnLaunch() async {
        guard isSignedIn, let server = try? await api.fetchPrefs() else { return }
        let serverTeams = server.fanOf["football"]?[String(AppEnvironment.leagueId)] ?? []
        if !serverTeams.isEmpty && prefs.footballTeams.isEmpty {
            prefs.fanOf = server.fanOf
            persistPrefs()
        } else if serverTeams != prefs.footballTeams {
            try? await api.putPrefs(roamingPrefs)
        }
        PushService.shared.syncTopics(to: fanTeamIds)
    }

    // MARK: Sign in / out

    func signInWithGoogle(presenting window: NSWindow?) {
        signInError = nil
        Task {
            do {
                let idToken = try await Services.google.signIn(presenting: window)
                let response = try await api.signIn(googleIdToken: idToken)
                Keychain.set(response.token, for: "sessionToken")
                profile = response.profile
                persist(profile: response.profile)
                // Fan teams come from the account: sign-out cleared the local
                // copy, so adopt whatever roams on the server (never push a
                // previous user's leftovers up). Settings stay device-local.
                prefs.fanOf = response.prefs.fanOf
                persistPrefs()
                PushService.shared.syncTopics(to: fanTeamIds)
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
        openWindow(WindowID.login)
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
        Task { try? await api.putPrefs(roamingPrefs) }
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
        guard let catalog = try? await scores.fetchCatalog(), !catalog.leagues.isEmpty else { return }
        leagues = catalog.leagues
        teamsByLeague = Dictionary(
            uniqueKeysWithValues: catalog.leagues.map { ($0.id, catalog.teams(for: $0.id)) },
        )
    }

    func refreshFixtures() async {
        if let today = try? await scores.fetchTodayFixtures() {
            fixtures = today
        }
        if let live = try? await scores.fetchLive() {
            liveMatches = live
            // All live matches, not just followed ones — the popover shows
            // celebration counts for every fixture on hover.
            for match in live {
                if let totals = try? await scores.fetchCelebrations(fixtureId: match.fixtureId) {
                    celebrationTotals[match.fixtureId] = totals
                }
            }
        }
    }

    private func startFixturesTimer() {
        fixturesTimer?.invalidate()
        let interval = ControlPlane.shared.pollingIntervalSeconds
        fixturesTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in
                // Poll only while a followed team is (or might be) playing —
                // FCM is the real-time channel, this is the consistency backstop.
                guard AppSession.shared.isSignedIn,
                      !AppSession.shared.fanTeamIds.isEmpty else { return }
                let followedLive = AppSession.shared.liveMatches
                    .contains { $0.involves(AppSession.shared.fanTeamIds) }
                let kickoffSoon = AppSession.shared.fixtures.contains {
                    $0.involves(AppSession.shared.fanTeamIds) &&
                    ($0.kickoff.map { abs($0.timeIntervalSinceNow) < 3 * 3600 } ?? false)
                }
                if followedLive || kickoffSoon || AppSession.shared.liveMatches.isEmpty {
                    await AppSession.shared.refreshFixtures()
                }
            }
        }
    }
}
