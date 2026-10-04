import AppKit
import Foundation
import SwiftUI

/// Central app state: local prefs, team catalog, and today's fixtures.
@MainActor
final class AppSession: ObservableObject {
    static let shared = AppSession()

    @Published var prefs: AppPrefs = .empty
    @Published var leagues: [League] = []
    @Published var teamsByLeague: [Int: [Team]] = TeamCatalog.fallbackByLeague
    @Published var fixtures: [Fixture] = []
    /// Every fixture kicking off today across all leagues — the menu's "All
    /// Teams" list. Schedule data only (`fixtures-{date}.json` publishes rows
    /// as SCHEDULED / 0-0 by construction): matches outside `fixtures` are
    /// never polled, so they carry a kickoff time and nothing live.
    @Published var todayFixtures: [Fixture] = []
    /// Shows the one-line "the World Cup has ended" note at the top of the
    /// picker. Set once, by `promptLeagueMigrationIfNeeded()`.
    @Published var showsLeagueMigrationNotice = false

    private var scores: ScoresProviding { Services.scores }
    private let defaults = AppDefaults.shared
    private var isBootstrappingFixtures = false
    /// Last automatic bootstrap attempt, so a failing date is retried about
    /// once a minute instead of on every 5s poll pass.
    private var lastBootstrapAttempt: Date?
    private static let bootstrapRetryInterval: TimeInterval = 60
    /// Working set of fixtures keyed by id — the live poll loop merges into this
    /// and `publishFixtures()` projects the visible, sorted list into `fixtures`.
    private var fixturesById: [Int: Fixture] = [:]
    /// The local day `publishFixtures()` last projected for — see
    /// `reprojectIfDayChanged()`.
    private var projectedDay: Date?

    private enum CacheKey {
        static let fanTeamIds = "fanTeamIds"
        static let settings = "settings"
        static let fixtures = "cachedFixtures"
        /// `"<utc day>:<file date>"` for each schedule file loaded on that UTC
        /// day — the bootstrap is complete once all three of today±1 are in.
        static let fixtureBootstrapDates = "fixtureBootstrapDates"
        static let leagueMigrationPrompted = "leagueMigrationPrompted"
    }

    /// Every catalog team, flattened — for id→team lookups across leagues.
    var allTeams: [Team] { teamsByLeague.values.flatMap { $0 } }
    /// Alias used by the overlay/menu lookups (`TeamCatalog.team(for:in:)`).
    var teams: [Team] { allTeams }
    /// The leagues users can follow today (the top five); the rest are "Coming
    /// soon" or, for a finished competition, "Ended".
    var activeLeagueIds: Set<Int> { Set(leagues.filter(\.active).map(\.id)) }
    /// Leagues that are over — still listed, teams still resolvable, never polled.
    var endedLeagueIds: Set<Int> { Set(leagues.filter(\.ended).map(\.id)) }
    var fanTeamIds: Set<Int> { Set(prefs.fanTeamIds.compactMap(Int.init)) }
    var fanTeams: [Team] {
        prefs.fanTeamIds.compactMap(Int.init).map { TeamCatalog.team(for: $0, in: allTeams) }
    }

    // MARK: Lifecycle

    func bootstrap() {
        AppLog.info(.app, "session_bootstrap_start")
        loadLocalPrefs()
        #if DEV_BACKEND
        // DevConfig is the single source of truth for who you follow in a demo
        // run — that's what keeps "My Teams" to the fixtures the timeline
        // actually scripts. It wins over anything `loadLocalPrefs()` restored,
        // so picking teams in a Debug build lasts only until the next launch.
        prefs.fanTeamIds = DevConfig.fanTeams
        #endif
        defaults.removeObject(forKey: "cachedCelebrationTotals")
        applyApplicationTheme()
        AppAnalytics.syncSettingProperties(prefs.settings)
        #if !DEV_BACKEND
        // A demo run starts from an empty board: DemoEngine seeds every fixture
        // itself, so restoring a cache would only leave rows from an older
        // reel (or an older DevConfig) sitting in "All Teams".
        if let data = defaults.data(forKey: CacheKey.fixtures),
           let stored = try? JSONDecoder().decode([Fixture].self, from: data) {
            fixturesById = Dictionary(stored.map { ($0.fixtureId, $0) }, uniquingKeysWith: { _, last in last })
            publishFixtures()
        }
        #endif
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
        AppLog.info(.app, "session_bootstrap_complete fan_teams=\(fanTeamIds.sorted()) cached_fixtures=\(fixtures.count)")
    }

    /// Closes the menu (killing its refresh timer).
    func stopAllActivity() {
        MenuPopoverController.shared.close()
    }

    // MARK: Prefs

    func setFanTeams(_ ids: [String]) {
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
        // `fixtures` is fan-filtered and is what the poll loop reads, so
        // re-project it now — otherwise a newly-followed team's live match
        // isn't polled until something else happens to republish.
        publishFixtures()
        // A newly-followed team's match may have already finished today — the
        // windowed poll loop won't pick it up once past kickoff+3.5h, so do a
        // one-shot reconcile against the per-match files for just these teams.
        let addedTeamIds = Set(added.compactMap(Int.init))
        if !addedTeamIds.isEmpty {
            Task { await LiveStore.shared.reconcileFanMatches(teamIds: addedTeamIds) }
        }
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
            AppAnalytics.settingChanged(.launchAtLogin, enabled: after.launchAtLogin ?? false)
        }
        if before.goalCenter != after.goalCenter {
            AppAnalytics.settingChanged(.goalCenter, enabled: after.goalCenter ?? true)
        }
        if before.confetti != after.confetti {
            AppAnalytics.settingChanged(.confetti, enabled: after.confetti ?? true)
        }
        // The enum-valued settings take the `value:` overload; the booleans
        // above take `enabled:`.
        if before.theme != after.theme {
            AppAnalytics.settingChanged(.theme, value: (after.theme ?? .system).rawValue)
        }
        if before.capsuleSize != after.capsuleSize {
            AppAnalytics.settingChanged(.capsuleSize, value: (after.capsuleSize ?? .medium).rawValue)
        }
        if before.capsulePosition != after.capsulePosition {
            AppAnalytics.settingChanged(.capsulePosition, value: (after.capsulePosition ?? .top).rawValue)
        }
        if before.notchDropSize != after.notchDropSize {
            AppAnalytics.settingChanged(.notchDropSize, value: (after.notchDropSize ?? .medium).rawValue)
        }
        let beforeNotifs = before.notifications ?? [:]
        let afterNotifs = after.notifications ?? [:]
        for (key, value) in afterNotifs where beforeNotifs[key] != value {
            AppAnalytics.eventTypeToggled(type: key, enabled: value)
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

    // MARK: Data refresh

    func refreshCatalog() async {
        AppLog.info(.catalog, "refresh_start")
        let catalog: Catalog
        do {
            catalog = try await scores.fetchCatalog().validated()
        } catch {
            AppLog.error(.catalog, "refresh_failed", error: error)
            return
        }
        guard !catalog.leagues.isEmpty else {
            AppLog.info(.catalog, "refresh_discarded leagues=0")
            return
        }
        leagues = catalog.leagues
        teamsByLeague = Dictionary(
            uniqueKeysWithValues: catalog.leagues.map { ($0.id, catalog.teams(for: $0.id)) },
        )
        AppLog.info(.catalog, "refresh_complete leagues=\(leagues.count) teams=\(allTeams.count)")
        promptLeagueMigrationIfNeeded()
    }

    /// Once, on the first catalog refresh after the top-five switch: if every
    /// team the user follows belongs to a competition that has ended (i.e. they
    /// only ever followed World Cup sides), open the picker so they can pick a
    /// club. The national teams stay saved — they become followable again in
    /// 2030 without the user re-picking — and the notice explains why.
    private func promptLeagueMigrationIfNeeded() {
        guard !defaults.bool(forKey: CacheKey.leagueMigrationPrompted) else { return }
        // Wait for a catalog that actually knows which leagues have ended.
        let ended = endedLeagueIds
        guard !ended.isEmpty, !activeLeagueIds.isEmpty else { return }
        let followed = fanTeamIds
        guard !followed.isEmpty else {
            // Nothing followed: there is nothing to migrate and no story to
            // tell. Burn the flag anyway so it can never fire later.
            defaults.set(true, forKey: CacheKey.leagueMigrationPrompted)
            return
        }
        // Only when EVERY followed team we can place is in an ended competition.
        // A user who already follows a club has nothing to be told. Ids the
        // catalog cannot place are skipped rather than counted as clubs — one
        // stale id must not silently suppress the whole prompt.
        let leagueOfTeam = Dictionary(
            allTeams.map { ($0.id, $0.leagueId) }, uniquingKeysWith: { first, _ in first },
        )
        let placed = followed.compactMap { leagueOfTeam[$0] }
        let allEnded = !placed.isEmpty && placed.allSatisfy(ended.contains)
        defaults.set(true, forKey: CacheKey.leagueMigrationPrompted)
        guard allEnded else { return }
        AppLog.info(.prefs, "league_migration_prompt fan_teams=\(followed.sorted())")
        showsLeagueMigrationNotice = true
        openWindow(WindowID.teamPicker)
    }

    /// Manual refresh (the menu's ↻ button): force a schedule re-bootstrap, run
    /// one live poll pass now (fetch each live fan match, merge its score, fire
    /// any new goal).
    func refreshFixtures() async {
        await bootstrapFixturesIfNeeded(force: true)
        #if !DEV_BACKEND
        // Un-stick a past-window finished match too: refreshNow()/pollCycle is
        // window-gated and can't, but reconcile (non-window-gated) can.
        await LiveStore.shared.reconcileFanMatches()
        await LiveStore.shared.refreshNow()
        #endif
    }

    /// The schedule bootstrap: once per day, read `fixtures-{date}.json` for
    /// today±1 (12h TTL) for kickoff times + which fan matches play. Live scores
    /// are never read from here — that's the poll loop's job. Never overwrites a
    /// live-polled fixture with a (possibly stale) schedule row. Each date is
    /// tracked on its own: one that failed is retried (at most once a minute)
    /// until it loads, even when its neighbours already did.
    func bootstrapFixturesIfNeeded(force: Bool = false) async {
        guard !isBootstrappingFixtures else { return }
        let now = Date()
        let bootstrapDay = ISO8601DateFormatter.dateOnly.string(from: now)
        // UTC: the fixtures-{date}.json keys are UTC days, so the today±1 math
        // must be UTC too — the local calendar can pick the wrong day near
        // midnight/DST and miss the +1 (or -1) file.
        let calendar = Calendar.utc
        let dates = [-1, 0, 1].compactMap { calendar.date(byAdding: .day, value: $0, to: now) }
        let key = { (date: Date) in "\(bootstrapDay):\(ISO8601DateFormatter.dateOnly.string(from: date))" }
        // Only entries from today's UTC bootstrap count: a new day re-reads all three.
        var loaded = Set(defaults.stringArray(forKey: CacheKey.fixtureBootstrapDates) ?? [])
            .filter { $0.hasPrefix("\(bootstrapDay):") }
        let pending = force ? dates : dates.filter { !loaded.contains(key($0)) }
        guard !pending.isEmpty else { return }
        if !force, let last = lastBootstrapAttempt,
           now.timeIntervalSince(last) < Self.bootstrapRetryInterval {
            return
        }
        lastBootstrapAttempt = now
        isBootstrappingFixtures = true
        defer { isBootstrappingFixtures = false }

        AppLog.info(.fixtures, "bootstrap_start cached=\(fixturesById.count) fan_teams=\(fanTeamIds.sorted()) pending=\(pending.count)")
        for date in pending {
            let fetched: [Fixture]
            do {
                fetched = try await scores.fetchFixtures(date: date)
                AppLog.info(.fixtures, "date_bootstrap_complete date=\(ISO8601DateFormatter.dateOnly.string(from: date)) fixtures=\(fetched.count)")
            } catch ScoresError.notModified {
                loaded.insert(key(date))
                continue
            } catch {
                AppLog.error(.fixtures, "date_bootstrap_failed date=\(ISO8601DateFormatter.dateOnly.string(from: date))", error: error)
                continue
            }
            loaded.insert(key(date))
            for fixture in fetched {
                // Don't clobber observed match state with a schedule row (always
                // SCHEDULED / 0-0 by construction): not a fixture the live loop
                // is actively polling, and never a final result — once a match
                // is FINISHED it's out of the poll loop, and its matches/{id}
                // file answers 304, so nothing would ever restore the score.
                if let existing = fixturesById[fixture.fixtureId],
                   existing.needsFrequentRefresh(at: now) || existing.status == "FINISHED" {
                    continue
                }
                fixturesById[fixture.fixtureId] = fixture
            }
        }
        defaults.set(loaded.sorted(), forKey: CacheKey.fixtureBootstrapDates)
        publishFixtures()
        AppLog.info(.fixtures, "bootstrap_complete fixtures=\(fixturesById.count) loaded_dates=\(loaded.count)")
    }

    /// Merge one freshly-polled live fixture into the working set. Called by
    /// `LiveStore` each poll cycle; `publishFixtures()` projects the visible list.
    func applyLiveFixture(_ fixture: Fixture) {
        fixturesById[fixture.fixtureId] = fixture
    }

    /// Project the working set into the two published, sorted lists and persist
    /// them. Visible = a match that kicks off today, or a live one whatever day
    /// it started on; `fixtures` narrows that to the user's own teams.
    /// `fixtures` — NOT `todayFixtures` — is what `LiveStore` polls, so a
    /// fuller today list costs nothing beyond the schedule file we already read.
    func publishFixtures() {
        let calendar = Calendar.current
        let now = Date()
        projectedDay = calendar.startOfDay(for: now)
        todayFixtures = fixturesById.values
            .filter { fixture in
                fixture.kickoff.map { calendar.isDate($0, inSameDayAs: now) } == true
                    || fixture.isLive
            }
            .sorted { ($0.kickoff ?? .distantFuture) < ($1.kickoff ?? .distantFuture) }
        fixtures = todayFixtures.filter { $0.involves(fanTeamIds) }
        persistFixtureCache()
    }

    /// The visible lists are a projection onto the LOCAL day, but the schedule
    /// bootstrap is gated on the UTC day — so crossing local midnight inside one
    /// UTC day re-projects nothing on its own. The poll loop calls this every
    /// pass so the new day's rows (already in the working set) show up.
    func reprojectIfDayChanged() {
        guard projectedDay != Calendar.current.startOfDay(for: Date()) else { return }
        AppLog.info(.fixtures, "fixtures_reprojected reason=local_day_changed")
        publishFixtures()
    }

    /// Every followed-team fixture in the working set (today±1 UTC), whatever
    /// local day it falls on. The poll loop picks its targets from here by
    /// kickoff window, not from the day-filtered `fixtures` the menu shows.
    var fanWorkingSet: [Fixture] {
        let fans = fanTeamIds
        return fixturesById.values.filter { $0.involves(fans) }
    }

    /// Is there any football on today at all, fan teams or not? The menu needs
    /// this to tell "none of your teams play today" from "nobody plays today" —
    /// `fixtures` alone can no longer answer it now that it is fan-filtered.
    var hasFixturesToday: Bool { !todayFixtures.isEmpty }

    /// The competition a fixture belongs to, for the menu's fixture rows. Falls
    /// back to the bundled names while catalog.json is still loading.
    func leagueName(for leagueId: Int) -> String? {
        leagues.first { $0.id == leagueId }?.name ?? League.fallbackNames[leagueId]
    }

    private func persistFixtureCache() {
        // The wider list: the schedule bootstrap runs once a UTC day, so a
        // relaunch later that day rebuilds the working set from this cache
        // alone — caching only the fan matches would empty "All Teams".
        if let data = try? JSONEncoder().encode(todayFixtures) {
            defaults.set(data, forKey: CacheKey.fixtures)
        }
    }


    /// Wipe the cached fixtures and live scores — the
    /// in-memory working set, their UserDefaults backing, and the once-per-day
    /// schedule gate — and reset the live-poll baseline and conditional-GET
    /// ETags so the next session re-fetches everything fresh from the CDN (no
    /// 304s against now-dropped data). Fan teams and settings are preserved.
    /// Called on quit (`applicationWillTerminate`).
    func clearMatchCache() {
        fixtures = []
        todayFixtures = []
        fixturesById = [:]
        defaults.removeObject(forKey: CacheKey.fixtures)
        defaults.removeObject(forKey: CacheKey.fixtureBootstrapDates)
        lastBootstrapAttempt = nil
        ScoresETagStore.shared.clear()
        LiveStore.shared.resetBaseline()
        AppLog.info(.fixtures, "match_cache_cleared")
    }
}
