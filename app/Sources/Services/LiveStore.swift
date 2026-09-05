import Foundation

/// The always-on live poll loop. Replaces the menu-only refresh timer and FCM's
/// background role: whenever the app is up, signed in, operational, and ≥1 fan
/// match is in its live window, this polls each such match's `matches/{id}.json`
/// (5s TTL) every `ControlPlane.pollSeconds` (±~15% jitter) — NOT gated on the
/// menu being open. Diffs each fixture against its previous observation and
/// fires the resulting events through `EventRouter` → `OverlayManager`.
///
/// The schedule (`fixtures-{date}.json`, 12h TTL) is the once-per-day bootstrap
/// (today±1); it provides kickoff times and which fan matches play. Live data is
/// never read from it.
///
/// POLL BY KICKOFF TIME, NOT cached status: a fan match enters its live window
/// from ~5 min before kickoff and stays until its match file reports FINISHED,
/// capped at kickoff+3.5h. A stale SCHEDULED in the fixtures file can never make
/// the app miss a live match.
@MainActor
final class LiveStore {
    static let shared = LiveStore()

    /// Lead time before kickoff at which we start polling a fan match.
    private static let preKickoffLead: TimeInterval = 5 * 60
    /// Hard cap on the trailing window (in case we never see FINISHED).
    private static let maxLiveWindow: TimeInterval = 3.5 * 60 * 60
    /// After a goal, re-read the celebration total for this long…
    private static let celebrationRefreshWindow: TimeInterval = 60
    /// …at this cadence, as everyone's taps trickle into the CDN file.
    private static let celebrationRefreshInterval: TimeInterval = 5

    private var loopTask: Task<Void, Never>?
    /// Per-fixture celebration refresh loops; a goal kicks one off (see
    /// `refreshCelebrations`). Cancelled on sign-out / loop stop.
    private var celebrationRefresh: [Int: Task<Void, Never>] = [:]
    /// Fan teams that scored in a fixture while its refresh window is open. When
    /// the window converges we drop ONE celebration-count notification per team
    /// — on every client, tapper or not (a later goal restarts the window and
    /// carries these forward so they're notified once, at the final tally).
    private var celebrationNotify: [Int: Set<Int>] = [:]
    /// Last-seen state per fixture — the diff baseline. A fixture not in here is
    /// being observed for the first time: it seeds the baseline and emits nothing.
    private var baseline: [Int: Fixture] = [:]

    /// Our own free-running clock anchor for a fixture: `baseSeconds` at
    /// `anchorDate`, ticking forward at 1x thereafter. Reset only at a half
    /// change (or seeded once on a mid-match join) — never corrected from the
    /// backend's noisy running-clock field. See `ingest` for anchor rules.
    /// `frozen` is the Debug demo's opt-out: it holds `baseSeconds` instead of
    /// ticking, so the clock reads the scripted minute (see
    /// `noteClockObservation`).
    struct ClockAnchor {
        var baseSeconds: Double
        var anchorDate: Date
        var period: MatchPeriod
        var frozen = false
    }
    private var clockAnchor: [Int: ClockAnchor] = [:]
    /// Fixtures whose match file has reported FINISHED (stop polling them).
    private var finished: Set<Int> = []
    /// One-shot launch reconciliation guard — see `reconcileFanMatches`. Reset on
    /// sign-out so the next signed-in session reconciles afresh.
    private var didReconcileThisLaunch = false
    /// App Nap opt-out, held ONLY while ≥1 fan match is in its live window (see
    /// `updateAppNapActivity`). nil = no live window / not asserting.
    private var liveActivity: NSObjectProtocol?

    private var session: AppSession { AppSession.shared }
    private var scores: ScoresProviding { Services.scores }

    /// Start the loop if it isn't already running. Idempotent.
    func start() {
        guard loopTask == nil else { return }
        AppLog.info(.fixtures, "live_loop_start")
        loopTask = Task { @MainActor in
            await self.run()
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        cancelCelebrationRefresh()
        updateAppNapActivity(active: false)
        AppLog.info(.fixtures, "live_loop_stop")
    }

    /// While ≥1 fan match is in its live window, hold a `.background` activity
    /// assertion so macOS App Nap doesn't throttle/suspend the poll loop's
    /// `Task.sleep` ticks — the app is an `LSUIElement` accessory app and would
    /// otherwise nap while idle in the menu bar, freezing live scores. We use
    /// `.background` (NOT `.idleSystemSleepDisabled`) so the Mac still sleeps
    /// normally; wake/foreground reconciliation (AppDelegate) recovers after sleep.
    private func updateAppNapActivity(active: Bool) {
        if active, liveActivity == nil {
            liveActivity = ProcessInfo.processInfo.beginActivity(
                options: .background, reason: "Polling live fan matches",
            )
            AppLog.info(.fixtures, "app_nap_activity_begin")
        } else if !active, let token = liveActivity {
            ProcessInfo.processInfo.endActivity(token)
            liveActivity = nil
            AppLog.info(.fixtures, "app_nap_activity_end")
        }
    }

    /// Drop the diff baseline (e.g. on sign-out) so the next observation seeds
    /// fresh and never replays events across an account switch.
    func resetBaseline() {
        baseline = [:]
        clockAnchor = [:]
        finished = []
        didReconcileThisLaunch = false
        cancelCelebrationRefresh()
    }

    /// Our local clock's current elapsed seconds for a fixture, or `nil` if no
    /// anchor has been established yet (not yet observed running). `at` lets a
    /// `TimelineView` tick re-evaluate this every second without re-polling.
    func localElapsedSeconds(_ fixtureId: Int, at now: Date = Date()) -> Double? {
        guard let anchor = clockAnchor[fixtureId] else { return nil }
        guard !anchor.frozen else { return anchor.baseSeconds }
        return anchor.baseSeconds + now.timeIntervalSince(anchor.anchorDate)
    }

    /// Manual refresh (the menu's ↻ button): run one poll pass right now — fetch
    /// each live fan match's `matches/{id}.json`, diff/merge the score, fire any
    /// new goal's events, and kick off the celebration refresh on a score move.
    func refreshNow() async {
        guard session.isSignedIn, ControlPlane.shared.isOperational else { return }
        await pollCycle()
    }

    /// One-shot reconciliation, NOT gated on the live window: for each fan match
    /// that has already kicked off but that the windowed poll loop won't poll
    /// (past kickoff+3.5h with no FINISHED ever observed), fetch `matches/{id}.json`
    /// once and merge it over the possibly-stale schedule row. This fixes a match
    /// that finished while the app was closed — or before its team was followed —
    /// which would otherwise show the frozen `fixtures-{date}.json` value (itself
    /// edge-cached up to 12h) until the next daily bootstrap.
    ///
    /// Scope keeps requests tiny: only fan matches, only kicked-off, and only
    /// those outside the live window (in-window matches are already handled by
    /// `pollCycle`, so this never double-fetches them). `teamIds` narrows it to a
    /// newly-followed team; nil reconciles every fan team (the launch pass).
    /// Reuses `ingest`, whose baseline guard emits no events on first observation
    /// — so reconciling a long-finished match never replays its goals.
    func reconcileFanMatches(teamIds: Set<Int>? = nil) async {
        guard session.isSignedIn, ControlPlane.shared.isOperational else { return }
        let teams = teamIds ?? session.fanTeamIds
        guard !teams.isEmpty else { return }
        let now = Date()
        let targets = session.fixtures.filter { fixture in
            fixture.involves(teams)
                && fixture.status != "FINISHED" // schedule already terminal — trust it
                && (fixture.kickoff.map { $0 <= now } ?? false) // has kicked off
                && !isInLiveWindow(fixture, at: now) // pollCycle owns in-window matches
        }
        guard !targets.isEmpty else { return }
        AppLog.info(.fixtures, "reconcile_start targets=\(targets.map(\.fixtureId).sorted())")

        var merged = false
        for previous in targets {
            guard session.isSignedIn, ControlPlane.shared.isOperational else { return }
            let current: Fixture
            do {
                current = try await scores.fetchFixture(fixtureId: previous.fixtureId)
            } catch ScoresError.notModified {
                continue
            } catch {
                AppLog.error(.fixtures, "reconcile_fetch_failed fixture_id=\(previous.fixtureId)", error: error)
                AppAnalytics.pollFailed(stage: "reconcile", fixtureId: previous.fixtureId, error: error)
                continue
            }
            ingest(current)
            merged = true
        }
        if merged { session.publishFixtures() }
    }

    private func run() async {
        while !Task.isCancelled {
            if session.isSignedIn, ControlPlane.shared.isOperational {
                await session.bootstrapFixturesIfNeeded()
                // Once per launch, reconcile any already-played fan match the
                // windowed poll loop won't touch (finished while the app was
                // closed). Independent of the bootstrap gate so it also fires
                // after a crash relaunch where the schedule cache survived.
                if !didReconcileThisLaunch {
                    await reconcileFanMatches()
                    didReconcileThisLaunch = true
                }
                await pollCycle()
            } else {
                // Signed out / gated: hold no power assertion while we idle-spin.
                updateAppNapActivity(active: false)
            }
            // ±~15% jitter so a fleet of clients doesn't hit the same 5s boundary.
            let base = max(1, ControlPlane.shared.pollSeconds)
            let jitter = base * Double.random(in: -0.15 ... 0.15)
            let interval = max(1, base + jitter)
            try? await Task.sleep(for: .seconds(interval))
        }
    }

    /// One poll pass: read each fan match in its live window, diff, fire events,
    /// refresh celebration totals on a score change, and publish to the session.
    private func pollCycle() async {
        let now = Date()
        let targets = session.fixtures.filter { fixture in
            fixture.involves(session.fanTeamIds) && isInLiveWindow(fixture, at: now)
        }
        // Defeat App Nap while a fan match is live; release it when none are.
        updateAppNapActivity(active: !targets.isEmpty)
        guard !targets.isEmpty else { return }
        AppLog.debug(.fixtures, "poll_cycle targets=\(targets.map(\.fixtureId).sorted())")

        for previous in targets {
            guard session.isSignedIn, ControlPlane.shared.isOperational else { return }
            let current: Fixture
            do {
                current = try await scores.fetchFixture(fixtureId: previous.fixtureId)
            } catch ScoresError.notModified {
                continue // byte-identical to last read — nothing to diff
            } catch {
                AppLog.error(.fixtures, "poll_fetch_failed fixture_id=\(previous.fixtureId)", error: error)
                AppAnalytics.pollFailed(stage: "poll", fixtureId: previous.fixtureId, error: error)
                continue
            }
            guard session.isSignedIn, ControlPlane.shared.isOperational else { return }

            let fanGoalTeams = ingest(current)

            // A score move (goal / VAR correction) is the only thing that grows
            // the celebration total — taps then trickle in for a while, so we
            // re-read for a minute rather than once. Fan goals additionally
            // schedule the convergence notification for the teams that scored.
            if previous.score != current.score || !fanGoalTeams.isEmpty {
                refreshCelebrations(fixtureId: current.fixtureId, notifyTeams: fanGoalTeams)
            }
        }
        session.publishFixtures()
    }

    /// A goal just fired: re-read `celebrate/{id}.json` every
    /// `celebrationRefreshInterval`s for `celebrationRefreshWindow` so the count
    /// climbs as everyone's taps land in the CDN file — a single snapshot misses
    /// the late tappers. Restarts the window if another goal lands mid-loop.
    ///
    /// When the window converges, drops a celebration-count notification for
    /// each fan team that scored — on EVERY client, so tappers and non-tappers
    /// alike see the same final tally rather than a partial, per-client snapshot.
    private func refreshCelebrations(fixtureId: Int, notifyTeams: [Int]) {
        celebrationNotify[fixtureId, default: []].formUnion(notifyTeams)
        celebrationRefresh[fixtureId]?.cancel()
        celebrationRefresh[fixtureId] = Task { @MainActor in
            let deadline = Date().addingTimeInterval(Self.celebrationRefreshWindow)
            while !Task.isCancelled, Date() < deadline {
                guard session.isSignedIn, ControlPlane.shared.isOperational else { break }
                do {
                    let totals = try await scores.fetchCelebrations(fixtureId: fixtureId)
                    guard session.isSignedIn, ControlPlane.shared.isOperational else { break }
                    session.mergeCelebrationTotals(totals, fixtureId: fixtureId)
                } catch ScoresError.notModified {
                    // counts unchanged
                } catch {
                    AppLog.error(.celebrations, "celebration_refresh_failed fixture_id=\(fixtureId)", error: error)
                    AppAnalytics.pollFailed(stage: "celebration", fixtureId: fixtureId, error: error)
                }
                try? await Task.sleep(for: .seconds(Self.celebrationRefreshInterval))
            }
            // A newer goal cancelled us and restarted the window — it now owns
            // these teams and the state, and will notify once at the later end.
            guard !Task.isCancelled else { return }
            if session.isSignedIn, ControlPlane.shared.isOperational {
                for teamId in celebrationNotify[fixtureId] ?? [] {
                    OverlayManager.shared.notifyCelebrationCount(fixtureId: fixtureId, teamId: String(teamId))
                }
            }
            celebrationNotify[fixtureId] = nil
            celebrationRefresh[fixtureId] = nil
        }
    }

    private func cancelCelebrationRefresh() {
        for task in celebrationRefresh.values { task.cancel() }
        celebrationRefresh.removeAll()
        celebrationNotify.removeAll()
    }

    /// Latest event in the current period; excludes e.g. 45+7′ after 2H starts.
    private func latestEventMinute(in current: Fixture, period: MatchPeriod) -> Int? {
        let bounds: ClosedRange<Int>
        let cap: Int
        switch period {
        case .first: bounds = 0 ... 45; cap = 45
        case .second: bounds = 46 ... 90; cap = 90
        case .extraFirst: bounds = 91 ... 105; cap = 105
        case .extraSecond: bounds = 106 ... 120; cap = 120
        default: return nil
        }

        var latest: Int?
        func consider(minute: Int?, extra: Int?) {
            guard let minute, bounds.contains(minute) else { return }
            let displayed = minute + (minute == cap ? max(0, extra ?? 0) : 0)
            latest = max(latest ?? displayed, displayed)
        }
        for team in [current.home, current.away] {
            for event in team.goalEvents { consider(minute: event.minute, extra: event.extra) }
            for event in team.yellowCardEvents { consider(minute: event.minute, extra: event.extra) }
            for event in team.redCardEvents { consider(minute: event.minute, extra: event.extra) }
            for event in team.subs { consider(minute: event.minute, extra: event.extra) }
        }
        for event in current.varEvents { consider(minute: event.minute, extra: event.extra) }
        return latest
    }

    /// The only two places our local clock's base is touched — never from the
    /// snapshot's running-clock field (`minute`/`extra`), which is the buggy,
    /// jittery source we're deliberately avoiding.
    ///   1. Half change (incl. kickoff): the half dictates the base (0/45/90/105).
    ///   2. Mid-match join: the very first observation of an already-running
    ///      fixture (app opened mid-match) seeds once from the snapshot's minute.
    /// Same half continuing → free-run, unless a newer event advances the clock.
    private func establishClockAnchor(isFirstObservation: Bool, current: Fixture) {
        guard current.running == true, let period = current.period,
              [.first, .second, .extraFirst, .extraSecond].contains(period)
        else { return }
        // A demo-pinned clock owns itself — the dev fake's own poll reads must
        // never rebase it back onto a free-running half.
        guard clockAnchor[current.fixtureId]?.frozen != true else { return }

        let now = Date()
        if let anchor = clockAnchor[current.fixtureId] {
            if anchor.period != period {
                clockAnchor[current.fixtureId] = ClockAnchor(
                    baseSeconds: Fixture.fixedBaseSeconds(for: period), anchorDate: now, period: period
                )
            }
        } else if isFirstObservation {
            // Mid-match join: seed once from the snapshot's minute.
            let seedSeconds = current.minute.map { Double($0) * 60 } ?? Fixture.fixedBaseSeconds(for: period)
            clockAnchor[current.fixtureId] = ClockAnchor(baseSeconds: seedSeconds, anchorDate: now, period: period)
        } else {
            // First time this (already-tracked) fixture is seen running — e.g.
            // the ordinary kickoff transition out of SCHEDULED.
            clockAnchor[current.fixtureId] = ClockAnchor(
                baseSeconds: Fixture.fixedBaseSeconds(for: period), anchorDate: now, period: period
            )
        }

        guard let anchor = clockAnchor[current.fixtureId] else { return }
        let localSeconds = anchor.baseSeconds + now.timeIntervalSince(anchor.anchorDate)
        let localMinute = localSeconds <= 0 ? 0 : Int(ceil(localSeconds / 60))
        guard let eventMinute = latestEventMinute(in: current, period: period),
              eventMinute > localMinute
        else { return }
        clockAnchor[current.fixtureId] = ClockAnchor(
            baseSeconds: Double(eventMinute) * 60,
            anchorDate: now,
            period: period
        )
        AppLog.info(
            .fixtures,
            "clock_anchor_corrected fixture_id=\(current.fixtureId) local_minute=\(localMinute) event_minute=\(eventMinute)"
        )
    }

    /// The clock rule for the Debug demo backend, which publishes scripted
    /// fixtures directly (`AppSession.applyLiveFixture`). The demo compresses
    /// a whole match into a couple of minutes of beats, so the app's real rule
    /// (anchor at the half's base, then free-run at 1x) would sit at 1′ while
    /// the pills fire 16′, 36′, 45′ — and snap back to 1′ whenever a beat put
    /// the fixture back in the first half. So here the clock is PINNED to the
    /// minute (plus stoppage) the moment itself carries, and held there until
    /// the next beat moves it.
    func noteClockObservation(_ current: Fixture) {
        guard current.running == true, let period = current.period,
              [.first, .second, .extraFirst, .extraSecond].contains(period)
        else { return }
        let baseSeconds = current.minute.map { Double($0 + (current.extra ?? 0)) * 60 }
            ?? Fixture.fixedBaseSeconds(for: period)
        clockAnchor[current.fixtureId] = ClockAnchor(
            baseSeconds: baseSeconds, anchorDate: Date(), period: period, frozen: true
        )
    }

    /// Merge one freshly-read fixture into state, diffing against the baseline,
    /// and return the fan teams that scored in this delta (drives the post-goal
    /// celebration notification).
    /// BASELINE GUARD: the first observation seeds the baseline and emits NO
    /// events (don't replay pre-launch goals); only later deltas fire overlays.
    @discardableResult
    private func ingest(_ current: Fixture) -> [Int] {
        let prev = baseline[current.fixtureId]

        // Cheap stale-snapshot guard: a CDN edge can momentarily serve a
        // SCHEDULED snapshot for a match we've already seen LIVE/HALF_TIME —
        // ignore it (don't wipe the live baseline or replay a kickoff later).
        // Minute regressions are NOT guarded: the feed legitimately recalibrates
        // the clock backward (e.g. ET snapping 114→109).
        if let prev, prev.isLive, current.status == "SCHEDULED" {
            AppLog.info(.fixtures, "stale_snapshot_ignored fixture_id=\(current.fixtureId) prev=\(prev.status) next=\(current.status)")
            AppAnalytics.snapshotRejected(reason: "stale_snapshot")
            return []
        }

        establishClockAnchor(isFirstObservation: prev == nil, current: current)

        session.applyLiveFixture(current)

        var fanGoalTeams: [Int] = []
        if prev == nil {
            AppLog.info(.fixtures, "baseline_seeded fixture_id=\(current.fixtureId) status=\(current.status) score=\(current.home.goals)-\(current.away.goals)")
        } else {
            let events = MatchDiff.diff(prev: prev, next: current)
            for event in events {
                EventRouter.shared.route(event)
            }
            let fans = session.fanTeamIds
            fanGoalTeams = events.compactMap { event in
                guard event.type == .goal, let team = event.teamId, fans.contains(team) else { return nil }
                return team
            }
            if !events.isEmpty {
                AppLog.info(.fixtures, "diff_fired fixture_id=\(current.fixtureId) events=\(events.count)")
                // Once per state change — this branch is what keeps the live
                // loop's thousand quiet reads per match silent in analytics.
                AppAnalytics.matchEventsEmitted(events)
            }
        }

        baseline[current.fixtureId] = current
        if current.status == "FINISHED", finished.insert(current.fixtureId).inserted {
            // First time we see this match end — its events will never recur, so
            // drop them from the dedupe store instead of letting it grow forever.
            EventRouter.shared.purgeEvents(forFixture: current.fixtureId)
        }
        return fanGoalTeams
    }

    /// True from ~5 min before kickoff until the match file reports FINISHED,
    /// capped at kickoff+3.5h — driven by the SCHEDULE's kickoff time, never the
    /// fixtures file's possibly-stale cached status (§3 coupling).
    private func isInLiveWindow(_ fixture: Fixture, at now: Date) -> Bool {
        if finished.contains(fixture.fixtureId) { return false }
        guard let kickoff = fixture.kickoff else {
            // No kickoff to key off: fall back to the file's own status.
            return fixture.isLive
        }
        let start = kickoff.addingTimeInterval(-Self.preKickoffLead)
        let end = kickoff.addingTimeInterval(Self.maxLiveWindow)
        return now >= start && now <= end
    }
}
