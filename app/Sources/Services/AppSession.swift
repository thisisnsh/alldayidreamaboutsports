import AppKit
import Foundation
import SwiftUI

/// Central app state: identity, local prefs, team catalog, and today's fixtures.
@MainActor
final class AppSession: ObservableObject {
    static let shared = AppSession()

    @Published var profile: Profile?
    @Published var prefs: AppPrefs = .empty
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
        static let fanTeamIds = "fanTeamIds"
        static let settings = "settings"
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
    var fanTeamIds: Set<Int> { Set(prefs.fanTeamIds.compactMap(Int.init)) }
    var fanTeams: [Team] {
        prefs.fanTeamIds.compactMap(Int.init).map { TeamCatalog.team(for: $0, in: allTeams) }
    }

    // MARK: Lifecycle

    func bootstrap() {
        AppLog.info(.app, "session_bootstrap_start")
        #if DEV_BACKEND
        // Sign-in bypass: already signed in before the first frame. Profile
        // comes from Dev/DevConfig.swift, while fan teams/settings are local.
        profile = DevConfig.profile
        prefs.fanTeamIds = DevConfig.fanTeams
        #else
        if let data = defaults.data(forKey: "profile"),
           let stored = try? JSONDecoder().decode(Profile.self, from: data),
           Keychain.get("sessionToken") != nil {
            profile = stored
        }
        #endif
        loadLocalPrefs()
        applyApplicationTheme()
        AppAnalytics.syncSettingProperties(prefs.settings)
        if let data = defaults.data(forKey: CacheKey.fixtures),
           let stored = try? JSONDecoder().decode([Fixture].self, from: data) {
            fixtures = stored
            fixturesById = Dictionary(uniqueKeysWithValues: stored.map { ($0.fixtureId, $0) })
        }
        if let data = defaults.data(forKey: CacheKey.celebrationTotals),
           let stored = try? JSONDecoder().decode([Int: [String: Int]].self, from: data) {
            celebrationTotals = stored
        }
        Task {
            await refreshCatalog()
            #if DEV_BACKEND
            await bootstrapFixturesIfNeeded(force: true)
            #endif
        }
        #if !DEV_BACKEND
        // Always-on live polling: one loop, running whenever a fan match is in
        // its live window — no menu, no push.
        LiveStore.shared.start()
        #endif
        AppLog.info(.app, "session_bootstrap_complete signed_in=\(isSignedIn) fan_teams=\(fanTeamIds.sorted()) cached_fixtures=\(fixtures.count)")
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
                await refreshCatalog()
                AppLog.info(.app, "sign_in_complete fan_teams=\(fanTeamIds.sorted())")
            } catch {
                signInError = error.localizedDescription
                AppLog.error(.app, "sign_in_failed", error: error)
            }
        }
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
        // Signed out = silent: wipe the cached fixtures/scores/celebrations so
        // the next session re-fetches fresh, and clear anything on screen. Fan
        // teams/settings stay in UserDefaults until app data goes.
        clearMatchCache()
        OverlayManager.shared.dismissAll()
        PinnedCapsuleManager.shared.closeAll()
        if showLogin {
            // Tear down Settings (or whatever utility window prompted the
            // sign-out) before re-presenting the login window, so the user
            // lands on a clean Sign In rather than a stack of stale windows.
            closeUtilityWindows(titles: ["Become a Fan", "Settings", "Update"])
            openWindow(WindowID.login)
        }
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
        signOut()
    }

    // MARK: Prefs

    func setFanTeams(_ rawIds: [String]) {
        // Defensive cap (config-driven): the picker already blocks over-adding.
        let maxFans = ControlPlane.shared.maxFanTeams
        let ids = rawIds.count > maxFans ? Array(rawIds.prefix(maxFans)) : rawIds
        if ids.count != rawIds.count {
            AppLog.info(.prefs, "fan_teams_capped raw=\(rawIds.count) max=\(maxFans)")
        }
        AppLog.info(.prefs, "fan_teams_changed old=\(prefs.fanTeamIds.sorted()) new=\(ids.sorted())")
        let before = Set(prefs.fanTeamIds)
        let after = Set(ids)
        prefs.fanTeamIds = ids
        persistFanTeamIds()
        let added = after.subtracting(before)
        for teamId in added {
            AppAnalytics.teamFollow(teamId: teamId, fanCount: ids.count)
        }
        for removed in before.subtracting(after) {
            AppAnalytics.teamUnfollow(teamId: removed, fanCount: ids.count)
        }
        // A newly-followed team's match may have already finished today — the
        // windowed poll loop won't pick it up once past kickoff+3.5h, so do a
        // one-shot reconcile against the per-match files for just these teams.
        let addedTeamIds = Set(added.compactMap(Int.init))
        if !addedTeamIds.isEmpty {
            Task { await LiveStore.shared.reconcileFanMatches(teamIds: addedTeamIds) }
        }
    }

    /// Re-apply the fan-team cap to the already-stored list. Called when Remote
    /// Config changes `max_fan_teams`: if the user follows more teams than the
    /// (possibly newly-lowered) cap allows, drop the trailing extras locally.
    /// Trailing = most-recently-added (picks are appended), so the oldest picks
    /// are kept. No-op when already within the cap.
    func enforceFanTeamCap() {
        let maxFans = ControlPlane.shared.maxFanTeams
        guard prefs.fanTeamIds.count > maxFans else { return }
        AppLog.info(.prefs, "fan_teams_cap_enforced count=\(prefs.fanTeamIds.count) max=\(maxFans)")
        setFanTeams(Array(prefs.fanTeamIds.prefix(maxFans)))
    }

    /// Settings are device-local and never sent to the backend. The anonymous
    /// analytics below see only which toggles flipped, never any identity.
    func updateSettings(_ mutate: (inout PrefSettings) -> Void) {
        let before = prefs.settings
        mutate(&prefs.settings)
        persistSettings()
        if before.theme != prefs.settings.theme {
            // SwiftUI's preferredColorScheme(nil) alone does not immediately
            // clear an existing AppKit window/popover override. Apply the
            // preference at the application level so open window chrome and
            // the menu update when switching back to System.
            applyApplicationTheme()
            // Overlay panels carry their own appearance overrides, so keep
            // them synchronized separately.
            OverlayManager.shared.applyOverlayTheme()
            PinnedCapsuleManager.shared.applyTheme()
        }
        reportSettingsChange(before: before, after: prefs.settings)
    }

    private func applyApplicationTheme() {
        NSApp.appearance = (prefs.settings.theme ?? .system).appKitAppearance
    }

    /// Emit one `setting_changed` per field that actually changed.
    private func reportSettingsChange(before: PrefSettings, after: PrefSettings) {
        if before.launchAtLogin != after.launchAtLogin {
            AppAnalytics.settingChanged(key: "launch_at_login", enabled: after.launchAtLogin ?? true)
        }
        if before.goalCenter != after.goalCenter {
            AppAnalytics.settingChanged(key: "goal_center", enabled: after.goalCenter ?? true)
        }
        if before.confetti != after.confetti {
            AppAnalytics.settingChanged(key: "confetti", enabled: after.confetti ?? true)
        }
        if before.confettiSound != after.confettiSound {
            AppAnalytics.settingChanged(key: "confetti_sound", enabled: after.confettiSound ?? true)
        }
        if before.theme != after.theme {
            AppAnalytics.themeChanged((after.theme ?? .system).rawValue)
        }
        let beforeNotifs = before.notifications ?? [:]
        let afterNotifs = after.notifications ?? [:]
        for (key, value) in afterNotifs where beforeNotifs[key] != value {
            AppAnalytics.settingChanged(key: "event_\(key)", enabled: value)
        }
    }

    private func loadLocalPrefs() {
        if let ids = defaults.stringArray(forKey: CacheKey.fanTeamIds) {
            prefs.fanTeamIds = ids
        }
        if let data = defaults.data(forKey: CacheKey.settings),
           let settings = try? JSONDecoder().decode(PrefSettings.self, from: data) {
            prefs.settings = settings
        }
    }

    private func persistFanTeamIds() {
        defaults.set(prefs.fanTeamIds, forKey: CacheKey.fanTeamIds)
    }

    private func persistSettings() {
        if let data = try? JSONEncoder().encode(prefs.settings) {
            defaults.set(data, forKey: CacheKey.settings)
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

    /// Manual refresh (the menu's ↻ button): force a schedule re-bootstrap, run
    /// one live poll pass now (fetch each live fan match, merge its score, fire
    /// any goal), then pull the latest celebration totals for fan matches that
    /// have played (live or finished).
    func refreshFixtures() async {
        await bootstrapFixturesIfNeeded(force: true)
        #if !DEV_BACKEND
        // Un-stick a past-window finished match too: refreshNow()/pollCycle is
        // window-gated and can't, but reconcile (non-window-gated) can.
        await LiveStore.shared.reconcileFanMatches()
        await LiveStore.shared.refreshNow()
        #endif
        await refreshCelebrationTotals()
    }

    /// Re-read `celebrate/{id}.json` once for each fan match that is live or
    /// finished — these are the only fixtures that can have a celebration tally.
    private func refreshCelebrationTotals() async {
        guard isSignedIn, ControlPlane.shared.isOperational else { return }
        let targets = fixtures.filter {
            $0.involves(fanTeamIds) && ($0.isLive || $0.status == "FINISHED")
        }
        for fixture in targets {
            guard isSignedIn, ControlPlane.shared.isOperational else { return }
            do {
                let totals = try await scores.fetchCelebrations(fixtureId: fixture.fixtureId)
                guard isSignedIn, ControlPlane.shared.isOperational else { return }
                mergeCelebrationTotals(totals, fixtureId: fixture.fixtureId)
            } catch ScoresError.notModified {
                // counts unchanged
            } catch {
                AppLog.error(.celebrations, "manual_totals_refresh_failed fixture_id=\(fixture.fixtureId)", error: error)
            }
        }
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

        // UTC: the fixtures-{date}.json keys are UTC days, so the today±1 math
        // must be UTC too — the local calendar can pick the wrong day near
        // midnight/DST and miss the +1 (or -1) file.
        let calendar = Calendar.utc
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

    /// Wipe the cached fixtures, live scores, and celebration tallies — the
    /// in-memory working set, their UserDefaults backing, and the once-per-day
    /// schedule gate — and reset the live-poll baseline and conditional-GET
    /// ETags so the next session re-fetches everything fresh from the CDN (no
    /// 304s against now-dropped data). Fan teams and settings are preserved.
    /// Called on sign-out and the kill-switch/forced-update gate (both via
    /// `clearSession`), and on quit (`applicationWillTerminate`).
    func clearMatchCache() {
        fixtures = []
        fixturesById = [:]
        celebrationTotals = [:]
        defaults.removeObject(forKey: CacheKey.fixtures)
        defaults.removeObject(forKey: CacheKey.celebrationTotals)
        defaults.removeObject(forKey: CacheKey.fixtureBootstrapDay)
        ScoresETagStore.shared.clear()
        LiveStore.shared.resetBaseline()
        AppLog.info(.fixtures, "match_cache_cleared")
    }
}
