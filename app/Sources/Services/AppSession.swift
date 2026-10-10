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
    /// Followed-team fixtures on the local days either side of today (keys -1
    /// and 1), for the menu's day arrows. Today itself is `fixtures`.
    @Published private(set) var neighborFixtures: [Int: [Fixture]] = [:]
    /// Which of yesterday (-1), today (0) and tomorrow (1) have any football
    /// at all, followed teams or not — tells "none of yours" from "none".
    @Published private(set) var daysWithFixtures: Set<Int> = []
    @Published private(set) var scheduleState: DataLoadState = .loading
    @Published private(set) var catalogState: DataLoadState = .loading
    @Published private(set) var liveScoreUpdates: [Int: LiveScoreUpdate] = [:]
    @Published private(set) var isRefreshingFixtures = false
    private var isRefreshingCatalog = false

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
    /// Every followed match the app has seen past SCHEDULED, by id: final
    /// scores and the events seen while it was live. Kept across quits (unlike
    /// the fixture cache) because a finished match's file may no longer carry
    /// its events — this is what yesterday's list reads them from.
    private var archive: [Int: Fixture] = [:]
    /// How long an archived match is kept after kickoff.
    private static let archiveDays = 3

    private enum CacheKey {
        static let fanTeamIds = "fanTeamIds"
        static let settings = "settings"
        static let fixtures = "cachedFixtures"
        static let archive = "matchArchive"
        /// `"<utc day>:<file date>"` for each schedule file loaded on that UTC
        /// day — the bootstrap is complete once all three of today±1 are in.
        static let fixtureBootstrapDates = "fixtureBootstrapDates"
    }

    /// Every catalog team, flattened — for id→team lookups across leagues.
    var allTeams: [Team] { teamsByLeague.values.flatMap { $0 } }
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
        applyApplicationTheme()
        AppAnalytics.syncSettingProperties(prefs.settings)
        #if !DEV_BACKEND
        loadArchive()
        // A demo run starts from an empty board: DemoEngine seeds every fixture
        // itself, so restoring a cache would only leave rows from an older
        // reel (or an older DevConfig) sitting in "All Teams".
        if let data = defaults.data(forKey: CacheKey.fixtures) {
            do {
                let stored = try JSONDecoder().decode([Fixture].self, from: data)
                fixturesById.merge(stored.map { ($0.fixtureId, $0) }, uniquingKeysWith: { _, last in last })
                publishFixtures()
            } catch {
                // A rejected old cache must not leave the schedule marked as
                // loaded, or polling would have no fixtures until tomorrow.
                defaults.removeObject(forKey: CacheKey.fixtures)
                defaults.removeObject(forKey: CacheKey.fixtureBootstrapDates)
                AppLog.info(.fixtures, "fixture_cache_rejected")
            }
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
        // its live window, menu open or not.
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
        guard !isRefreshingCatalog else { return }
        isRefreshingCatalog = true
        catalogState = .loading
        defer { isRefreshingCatalog = false }
        AppLog.info(.catalog, "refresh_start")
        let catalog: Catalog
        do {
            catalog = try await scores.fetchCatalog().validated()
        } catch ScoresError.notModified where !leagues.isEmpty {
            // 304: the catalog already loaded this launch is still current.
            catalogState = .ready
            AppLog.info(.catalog, "refresh_not_modified leagues=\(leagues.count)")
            return
        } catch ScoresError.notModified {
            // 304 but nothing usable loaded (the ETag is stored before
            // validation): drop it so the next try is a full read.
            ScoresETagStore.shared.remove(for: "catalog.json")
            AppLog.info(.catalog, "refresh_not_modified_empty")
            catalogState = .unavailable
            return
        } catch {
            AppLog.error(.catalog, "refresh_failed", error: error)
            catalogState = .unavailable
            return
        }
        guard !catalog.leagues.isEmpty else {
            AppLog.info(.catalog, "refresh_discarded leagues=0")
            catalogState = .unavailable
            return
        }
        leagues = catalog.leagues
        teamsByLeague = Dictionary(
            uniqueKeysWithValues: catalog.leagues.map { ($0.id, catalog.teams(for: $0.id)) },
        )
        catalogState = .ready
        AppLog.info(.catalog, "refresh_complete leagues=\(leagues.count) teams=\(allTeams.count)")
    }

    /// Manual refresh (the menu's ↻ button): force a schedule re-bootstrap, run
    /// one live poll pass now (fetch each live fan match, merge its score, fire
    /// any new goal).
    func refreshFixtures() async {
        guard !isRefreshingFixtures else { return }
        isRefreshingFixtures = true
        defer { isRefreshingFixtures = false }
        await bootstrapFixturesIfNeeded(force: true)
        #if !DEV_BACKEND
        // Un-stick a past-window finished match too: refreshNow()/pollCycle is
        // window-gated and can't, but reconcile (non-window-gated) can.
        await LiveStore.shared.reconcileFanMatches()
        await LiveStore.shared.refreshNow()
        #endif
    }

    /// The schedule bootstrap: once per day, read `fixtures-{date}.json` for
    /// today±2 (12h TTL) for kickoff times + which fan matches play. ±2 UTC
    /// days, not ±1, so the menu's local yesterday and tomorrow are covered
    /// whatever the time zone. Live scores
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
        let dates = [-2, -1, 0, 1, 2].compactMap { calendar.date(byAdding: .day, value: $0, to: now) }
        let key = { (date: Date) in "\(bootstrapDay):\(ISO8601DateFormatter.dateOnly.string(from: date))" }
        // Only entries from today's UTC bootstrap count: a new day re-reads them all.
        var loaded = Set(defaults.stringArray(forKey: CacheKey.fixtureBootstrapDates) ?? [])
            .filter { $0.hasPrefix("\(bootstrapDay):") }
        let pending = force ? dates : dates.filter { !loaded.contains(key($0)) }
        guard !pending.isEmpty else {
            scheduleState = .ready
            return
        }
        if !force, let last = lastBootstrapAttempt,
           now.timeIntervalSince(last) < Self.bootstrapRetryInterval {
            return
        }
        lastBootstrapAttempt = now
        isBootstrappingFixtures = true
        scheduleState = .loading
        defer { isBootstrappingFixtures = false }
        // A failed forced refresh must remain retryable even if yesterday's
        // attempt for this UTC day succeeded.
        for date in pending { loaded.remove(key(date)) }

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
                   existing.needsFrequentRefresh(at: now) || existing.status == "FINISHED"
                    || archive[fixture.fixtureId] != nil {
                    continue
                }
                fixturesById[fixture.fixtureId] = fixture
            }
        }
        defaults.set(loaded.sorted(), forKey: CacheKey.fixtureBootstrapDates)
        scheduleState = dates.allSatisfy { loaded.contains(key($0)) } ? .ready : .unavailable
        publishFixtures()
        AppLog.info(.fixtures, "bootstrap_complete fixtures=\(fixturesById.count) loaded_dates=\(loaded.count)")
    }

    /// Merge one freshly-polled live fixture into the working set. Called by
    /// `LiveStore` each poll cycle; `publishFixtures()` projects the visible list.
    func applyLiveFixture(_ fixture: Fixture) {
        fixturesById[fixture.fixtureId] = fixture
        confirmLiveScore(fixture.fixtureId)
        #if !DEV_BACKEND
        // The demo replays its reel every launch; nothing of it is kept.
        if fixture.status != "SCHEDULED", archive[fixture.fixtureId] != fixture {
            archive[fixture.fixtureId] = fixture
            persistArchive()
        }
        #endif
    }

    /// The last state archived for a match, events included — `LiveStore`
    /// merges a fresh read over it so events the file no longer carries stay.
    func archivedFixture(_ fixtureId: Int) -> Fixture? {
        archive[fixtureId]
    }

    private func loadArchive() {
        guard let data = defaults.data(forKey: CacheKey.archive),
              let stored = try? JSONDecoder().decode([Fixture].self, from: data) else { return }
        let cutoff = Calendar.current.date(byAdding: .day, value: -Self.archiveDays, to: Date()) ?? .distantPast
        archive = Dictionary(
            stored.filter { ($0.kickoff ?? .distantPast) >= cutoff }.map { ($0.fixtureId, $0) },
            uniquingKeysWith: { _, last in last }
        )
        fixturesById.merge(archive) { _, archived in archived }
        publishFixtures()
    }

    private func persistArchive() {
        let cutoff = Calendar.current.date(byAdding: .day, value: -Self.archiveDays, to: Date()) ?? .distantPast
        archive = archive.filter { ($0.value.kickoff ?? .distantPast) >= cutoff }
        if let data = try? JSONEncoder().encode(Array(archive.values)) {
            defaults.set(data, forKey: CacheKey.archive)
        }
    }

    func confirmLiveScore(_ fixtureId: Int) {
        liveScoreUpdates[fixtureId] = LiveScoreUpdate(confirmedAt: Date())
    }

    func markLiveScoreUnavailable(_ fixtureId: Int) {
        var update = liveScoreUpdates[fixtureId] ?? LiveScoreUpdate()
        update.failed = true
        liveScoreUpdates[fixtureId] = update
    }

    func liveScoreStatus(_ fixtureId: Int, at date: Date) -> LiveScoreUpdate.Status {
        (liveScoreUpdates[fixtureId] ?? LiveScoreUpdate()).status(at: date)
    }

    /// Project the working set into the published, sorted per-day lists and
    /// persist it. Today = a followed match that kicks off today, or a live one
    /// whatever day it started on; yesterday and tomorrow are by kickoff alone,
    /// so a live match never shows twice.
    func publishFixtures() {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        projectedDay = today
        // A "live" row that kicked off half a day ago is a leftover whose end
        // was never seen, not a match in play.
        func live(_ fixture: Fixture) -> Bool {
            fixture.isLive && (fixture.kickoff ?? now) > now.addingTimeInterval(-12 * 60 * 60)
        }
        // Rows older than the menu's yesterday (and the archive) are done with.
        if let cutoff = calendar.date(byAdding: .day, value: -Self.archiveDays, to: today) {
            fixturesById = fixturesById.filter { _, fixture in
                live(fixture) || (fixture.kickoff ?? .distantFuture) >= cutoff
            }
        }
        func dayOffset(_ fixture: Fixture) -> Int? {
            guard let kickoff = fixture.kickoff else { return nil }
            return calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: kickoff)).day
        }
        let sorted = fixturesById.values
            .sorted { ($0.kickoff ?? .distantFuture) < ($1.kickoff ?? .distantFuture) }
        var days: Set<Int> = []
        var neighbors: [Int: [Fixture]] = [-1: [], 1: []]
        var todays: [Fixture] = []
        let fans = fanTeamIds
        for fixture in sorted {
            let offset = live(fixture) ? 0 : dayOffset(fixture)
            guard let offset, (-1 ... 1).contains(offset) else { continue }
            days.insert(offset)
            guard fixture.involves(fans) else { continue }
            if offset == 0 { todays.append(fixture) } else { neighbors[offset, default: []].append(fixture) }
        }
        fixtures = todays
        neighborFixtures = neighbors
        daysWithFixtures = days
        persistFixtureCache()
    }

    /// The followed matches on `offset` days from today (-1, 0 or 1).
    func fixtures(dayOffset offset: Int) -> [Fixture] {
        offset == 0 ? fixtures : neighborFixtures[offset] ?? []
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

    /// Is there any football at all `offset` days from today, fan teams or
    /// not? The menu needs this to tell "none of your teams play" from "nobody
    /// plays" — the fan-filtered lists alone can't answer it.
    func hasFixtures(dayOffset offset: Int) -> Bool { daysWithFixtures.contains(offset) }

    /// The competition a fixture belongs to, for the menu's fixture rows. Falls
    /// back to the bundled names while catalog.json is still loading.
    func leagueName(for leagueId: Int) -> String? {
        leagues.first { $0.id == leagueId }?.name ?? League.fallbackNames[leagueId]
    }

    private func persistFixtureCache() {
        // The whole working set: the schedule bootstrap runs once a UTC day,
        // so a relaunch later that day rebuilds it from this cache alone.
        if let data = try? JSONEncoder().encode(Array(fixturesById.values)) {
            defaults.set(data, forKey: CacheKey.fixtures)
        }
    }


    /// Wipe the cached fixtures and live scores — the
    /// in-memory working set, their UserDefaults backing, and the once-per-day
    /// schedule gate — and reset the live-poll baseline and conditional-GET
    /// ETags so the next session re-fetches everything fresh from the CDN (no
    /// 304s against now-dropped data). Fan teams, settings and the match
    /// archive are preserved. Called on quit (`applicationWillTerminate`).
    func clearMatchCache() {
        fixtures = []
        neighborFixtures = [:]
        daysWithFixtures = []
        fixturesById = [:]
        liveScoreUpdates = [:]
        scheduleState = .loading
        defaults.removeObject(forKey: CacheKey.fixtures)
        defaults.removeObject(forKey: CacheKey.fixtureBootstrapDates)
        lastBootstrapAttempt = nil
        ScoresETagStore.shared.clear()
        LiveStore.shared.resetBaseline()
        AppLog.info(.fixtures, "match_cache_cleared")
    }
}
