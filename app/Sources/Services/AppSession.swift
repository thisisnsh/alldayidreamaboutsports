import AppKit
import Foundation
import SwiftUI

/// Central app state: identity, prefs (UserDefaults = source of truth, backend
/// = roaming backup), team catalog, and today's fixtures.
@MainActor
final class AppSession: ObservableObject {
    static let shared = AppSession()

    @Published var profile: Profile?
    @Published var mainScreen: MainScreen = .login
    @Published var prefs: UserPrefs = .empty
    @Published var teams: [Team] = TeamCatalog.fallback
    @Published var fixtures: [Fixture] = []
    @Published var liveMatches: [Fixture] = []
    @Published var celebrationTotals: [Int: [String: Int]] = [:]
    @Published var signInError: String?

    private var api: BackendAPI { Services.api }
    private var scores: ScoresProviding { Services.scores }
    private let defaults = UserDefaults.standard
    private var fixturesTimer: Timer?

    var isSignedIn: Bool { profile != nil }
    var fanTeamCodes: Set<String> { Set(prefs.footballTeams) }
    var fanTeams: [Team] {
        prefs.footballTeams.map { TeamCatalog.team(for: $0, in: teams) }
    }

    // MARK: Lifecycle

    func bootstrap() {
        #if DEV_BACKEND
        // Sign-in bypass: already signed in before the first frame. No login
        // window, no Keychain, no UserDefaults — the hardcoded data in
        // Dev/DevConfig.swift is the source of truth on every launch.
        profile = DevConfig.profile
        prefs = FakeStore.shared.prefs
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
        Task { await refreshTeams() }
        Task { await refreshFixtures() }
        startFixturesTimer()
        PushService.shared.syncTopics(to: fanTeamCodes)
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
                // Server prefs win on a fresh machine; local wins if user already picked teams.
                if prefs.footballTeams.isEmpty {
                    prefs = response.prefs
                    persistPrefs()
                } else {
                    try? await api.putPrefs(prefs)
                }
                PushService.shared.syncTopics(to: fanTeamCodes)
            } catch {
                signInError = error.localizedDescription
            }
        }
    }

    func signOut() {
        Services.google.signOut()
        Keychain.delete("sessionToken")
        defaults.removeObject(forKey: "profile")
        profile = nil
        mainScreen = .login
        openWindow(WindowID.main)
    }

    func deleteAccount() async {
        try? await api.deleteAccount()
        PushService.shared.syncTopics(to: [])
        prefs = .empty
        persistPrefs()
        signOut()
    }

    // MARK: Prefs

    func setFanTeams(_ codes: [String]) {
        prefs.footballTeams = codes
        persistPrefs()
        PushService.shared.syncTopics(to: Set(codes))
        Task { try? await api.putPrefs(prefs) }
    }

    func updateSettings(_ mutate: (inout PrefSettings) -> Void) {
        mutate(&prefs.settings)
        persistPrefs()
        Task { try? await api.putPrefs(prefs) }
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

    func refreshTeams() async {
        if let fresh = try? await scores.fetchTeams(), !fresh.isEmpty {
            teams = fresh.sorted { $0.name < $1.name }
        }
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
                guard !AppSession.shared.fanTeamCodes.isEmpty else { return }
                let followedLive = AppSession.shared.liveMatches
                    .contains { $0.involves(AppSession.shared.fanTeamCodes) }
                let kickoffSoon = AppSession.shared.fixtures.contains {
                    $0.involves(AppSession.shared.fanTeamCodes) &&
                    ($0.kickoff.map { abs($0.timeIntervalSinceNow) < 3 * 3600 } ?? false)
                }
                if followedLive || kickoffSoon || AppSession.shared.liveMatches.isEmpty {
                    await AppSession.shared.refreshFixtures()
                }
            }
        }
    }
}
