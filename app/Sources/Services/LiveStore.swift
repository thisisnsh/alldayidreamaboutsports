import Foundation

/// The always-on live poll loop: whenever the app is up and ≥1 fan
/// match is in its live window, this polls each such match's `matches/{id}.json`
/// (5s TTL) every `pollSeconds` (±~15% jitter) — NOT gated on the
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

    /// Live poll interval — matches the `matches/{id}.json` 5s TTL.
    private static let pollSeconds: TimeInterval = 5
    /// Lead time before kickoff at which we start polling a fan match.
    private static let preKickoffLead: TimeInterval = 5 * 60
    /// How far ahead of a fan match's live window we start holding the App Nap
    /// assertion. A napped loop's `Task.sleep` can stretch to minutes, so
    /// taking it only once the window is open would let the first goals slip
    /// by until the user clicks the menu (which activates the app). Polls in
    /// this lead have no targets, so they cost nothing on the network.
    private static let appNapLead: TimeInterval = 30 * 60
    /// Hard cap on the trailing window (in case we never see FINISHED).
    private static let maxLiveWindow: TimeInterval = 3.5 * 60 * 60
    /// How long a fixture's baseline may go unconfirmed and still count as "the
    /// state one poll ago". Past this the app wasn't watching (see the
    /// observation-gap guard in `ingest`). At the 5s poll cadence this is ~24
    /// missed cycles — far beyond a few failed fetches, and short enough that a
    /// real gap is caught on the first read after it.
    private static let maxObservationGap: TimeInterval = 2 * 60

    private var loopTask: Task<Void, Never>?
    /// The poll pass currently running, if any — see `pollCycle`.
    private var pollInFlight: Task<Void, Never>?
    /// Last-seen state per fixture — the diff baseline. A fixture not in here is
    /// being observed for the first time: it seeds the baseline and emits nothing.
    private var baseline: [Int: Fixture] = [:]
    /// When each fixture's baseline was last confirmed current. Stamped on every
    /// successful read INCLUDING a 304 (byte-identical = still current, which a
    /// quiet stretch like half-time can serve for minutes). The gap since this
    /// stamp is what tells a live delta apart from a slept-through catch-up.
    private var baselineObservedAt: [Int: Date] = [:]
    /// A 304 for a rejected representation must not make the retained score look fresh.
    private var rejectedSnapshots: Set<Int> = []

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
    /// One-shot launch reconciliation guard — see `reconcileFanMatches`. Reset
    /// with the baseline when the match cache is cleared.
    private var didReconcileThisLaunch = false
    /// App Nap opt-out, held ONLY while ≥1 fan match is in its live window (see
    /// `updateAppNapActivity`). nil = no live window / not asserting.
    private var liveActivity: NSObjectProtocol?

    private var session: AppSession { AppSession.shared }
    private var scores: ScoresProviding { Services.scores }

    /// Start the loop if it isn't already running. Idempotent. Never while
    /// the demo is on: DemoEngine is the only thing that moves its scores.
    func start() {
        guard loopTask == nil, !DemoMode.isActive else { return }
        AppLog.info(.fixtures, "live_loop_start")
        loopTask = Task { @MainActor in
            await self.run()
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        updateAppNapActivity(active: false)
        AppLog.info(.fixtures, "live_loop_stop")
    }

    /// While a fan match is live (or about to be — see `appNapLead`), hold an
    /// activity assertion so macOS App Nap doesn't throttle/suspend the poll
    /// loop's `Task.sleep` ticks — the app is an `LSUIElement` accessory app and
    /// would otherwise nap while idle in the menu bar, freezing live scores
    /// until the menu is clicked. `.background` doesn't opt out of App Nap;
    /// `.userInitiatedAllowingIdleSystemSleep` does, while still letting the
    /// Mac sleep normally — wake/foreground reconciliation (AppDelegate)
    /// recovers after sleep.
    private func updateAppNapActivity(active: Bool) {
        if active, liveActivity == nil {
            liveActivity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep, reason: "Polling live fan matches",
            )
            AppLog.info(.fixtures, "app_nap_activity_begin")
        } else if !active, let token = liveActivity {
            ProcessInfo.processInfo.endActivity(token)
            liveActivity = nil
            AppLog.info(.fixtures, "app_nap_activity_end")
        }
    }

    /// Drop the diff baseline (when the match cache is cleared) so the next
    /// observation seeds fresh and never replays old events.
    func resetBaseline() {
        baseline = [:]
        baselineObservedAt = [:]
        rejectedSnapshots = []
        clockAnchor = [:]
        finished = []
        didReconcileThisLaunch = false
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
    /// new goal's events.
    func refreshNow() async {
        guard !DemoMode.isActive else { return }
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
        guard !DemoMode.isActive else { return }
        let teams = teamIds ?? session.fanTeamIds
        guard !teams.isEmpty else { return }
        let now = Date()
        // Back to the start of the menu's yesterday, so its scores are final.
        let since = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: now)) ?? now
        let targets = session.fanWorkingSet.filter { fixture in
            fixture.involves(teams)
                && fixture.status != "FINISHED" && !fixture.isCalledOff // schedule already terminal — trust it
                && (fixture.kickoff.map { $0 <= now && $0 >= since } ?? false) // kicked off since yesterday
                && !isInLiveWindow(fixture, at: now) // pollCycle owns in-window matches
        }
        guard !targets.isEmpty else { return }
        AppLog.info(.fixtures, "reconcile_start targets=\(targets.map(\.fixtureId).sorted())")

        var merged = false
        for previous in targets {
                let current: Fixture
            do {
                current = try await scores.fetchFixture(fixtureId: previous.fixtureId)
            } catch ScoresError.notModified {
                guard !rejectedSnapshots.contains(previous.fixtureId) else { continue }
                session.confirmLiveScore(previous.fixtureId)
                continue
            } catch {
                session.markLiveScoreUnavailable(previous.fixtureId)
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
            // ±~15% jitter so a fleet of clients doesn't hit the same 5s boundary.
            let base = Self.pollSeconds
            let jitter = base * Double.random(in: -0.15 ... 0.15)
            let interval = max(1, base + jitter)
            try? await Task.sleep(for: .seconds(interval))
        }
    }

    /// One poll pass at a time. The loop, wake/foreground recovery and the
    /// menu's ↻ can all ask for one, and MainActor doesn't serialize across the
    /// fetch awaits — two interleaved passes could ingest an OLDER snapshot
    /// after a newer one, rolling the score back into a fake GOAL_CANCELLED. A
    /// caller arriving mid-pass just waits for that pass instead.
    private func pollCycle() async {
        if let inFlight = pollInFlight {
            await inFlight.value
            return
        }
        let pass = Task { @MainActor in await self.runPollCycle() }
        pollInFlight = pass
        await pass.value
        pollInFlight = nil
    }

    /// One poll pass: read each fan match in its live window, diff, fire events,
    /// and publish to the session.
    private func runPollCycle() async {
        let now = Date()
        session.reprojectIfDayChanged()
        // The whole working set, not the local-day `fixtures`: a match just past
        // local midnight must be polled even before anything re-projects.
        let fanFixtures = session.fanWorkingSet
        let targets = fanFixtures.filter { isInLiveWindow($0, at: now) }
        // Defeat App Nap while a fan match is live or about to be; release it
        // when none are.
        let soon = now.addingTimeInterval(Self.appNapLead)
        updateAppNapActivity(active: !targets.isEmpty || fanFixtures.contains { isInLiveWindow($0, at: soon) })
        guard !targets.isEmpty else { return }
        AppLog.debug(.fixtures, "poll_cycle targets=\(targets.map(\.fixtureId).sorted())")

        for previous in targets {
                let current: Fixture
            do {
                current = try await scores.fetchFixture(fixtureId: previous.fixtureId)
            } catch ScoresError.notModified {
                guard !rejectedSnapshots.contains(previous.fixtureId) else { continue }
                // Byte-identical to last read — nothing to diff, but the read
                // itself confirms the baseline is still current, so it keeps the
                // observation gap closed through a quiet stretch.
                baselineObservedAt[previous.fixtureId] = Date()
                session.confirmLiveScore(previous.fixtureId)
                continue
            } catch {
                session.markLiveScoreUnavailable(previous.fixtureId)
                AppLog.error(.fixtures, "poll_fetch_failed fixture_id=\(previous.fixtureId)", error: error)
                AppAnalytics.pollFailed(stage: "poll", fixtureId: previous.fixtureId, error: error)
                continue
            }
    
            ingest(current)
        }
        session.publishFixtures()
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
            // Mid-match join: seed once from the snapshot's minute. The backend
            // clamps `minute` at the half's cap (45/90/105/120) and carries
            // stoppage in `extra`, so joining at 90+5 must seed 95′, not 90′ —
            // the same wire reading the Debug demo uses (`noteClockObservation`).
            // `extra` is clamped to a sane range so a feed glitch can't fling it.
            let stoppage = min(max(current.extra ?? 0, 0), 30)
            let seedSeconds = current.minute.map { Double($0 + stoppage) * 60 } ?? Fixture.fixedBaseSeconds(for: period)
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
        guard current.hasValidBounds, current.running == true, let period = current.period,
              [.first, .second, .extraFirst, .extraSecond].contains(period)
        else { return }
        let baseSeconds = current.minute.map { Double($0 + (current.extra ?? 0)) * 60 }
            ?? Fixture.fixedBaseSeconds(for: period)
        clockAnchor[current.fixtureId] = ClockAnchor(
            baseSeconds: baseSeconds, anchorDate: Date(), period: period, frozen: true
        )
    }

    /// Merge one freshly-read fixture into state, diffing against the baseline,
    /// and route new events to the local overlays.
    /// BASELINE GUARD: the first observation seeds the baseline and emits NO
    /// events (don't replay pre-launch goals); only later deltas fire overlays.
    /// A baseline gone stale (see `baselineIsStale`) re-seeds the same way.
    private func ingest(_ snapshot: Fixture) {
        guard snapshot.hasValidBounds else {
            rejectedSnapshots.insert(snapshot.fixtureId)
            session.markLiveScoreUnavailable(snapshot.fixtureId)
            AppLog.info(.fixtures, "snapshot_rejected reason=invalid_bounds fixture_id=\(snapshot.fixtureId)")
            return
        }
        let now = Date()
        let prev = baseline[snapshot.fixtureId]
        // The feed can drop timeline entries it already sent. Keep what we've
        // seen for the rest of this run (the cache is wiped on quit), so the
        // timeline doesn't lose them — and since the baseline is this merged
        // state too, the entries coming back later don't refire as new.
        // On a first read, the archive stands in for the baseline: a finished
        // match's file may have lost events the app saw live.
        let current = (prev ?? session.archivedFixture(snapshot.fixtureId))
            .map { snapshot.keepingEvents(from: $0) } ?? snapshot
        // OBSERVATION-GAP GUARD: `prev` is only "the state one poll ago" while
        // we've been watching continuously. After a gap — the lid was shut, the
        // Mac slept, the network went away — it's an old snapshot, and diffing
        // against it replays every goal, card and sub we missed as one burst of
        // live overlays the moment the laptop opens. Re-seed instead: the score,
        // clock and timeline still merge (the pinned capsule shows what
        // happened), but nothing animates. Old news doesn't get a celebration.
        let resync = prev != nil && baselineIsStale(current.fixtureId, at: now)

        // Cheap stale-snapshot guard: a CDN edge can momentarily serve a
        // SCHEDULED snapshot for a match we've already seen LIVE/HALF_TIME —
        // ignore it (don't wipe the live baseline or replay a kickoff later).
        // Minute regressions are NOT guarded: the feed legitimately recalibrates
        // the clock backward (e.g. ET snapping 114→109).
        if let prev, prev.isLive, current.status == "SCHEDULED" {
            rejectedSnapshots.insert(current.fixtureId)
            session.markLiveScoreUnavailable(current.fixtureId)
            AppLog.info(.fixtures, "stale_snapshot_ignored fixture_id=\(current.fixtureId) prev=\(prev.status) next=\(current.status)")
            AppAnalytics.snapshotRejected(reason: "stale_snapshot")
            return
        }

        // Our free-running clock drifted through the same gap (and rebases to a
        // half's base minute on the first post-gap read, reading 45′ for an 80′
        // match). Drop the anchor so the re-seed below reseeds it from this
        // snapshot's minute, exactly as a mid-match join does. A demo-pinned
        // (frozen) anchor owns itself and is left alone.
        if resync, clockAnchor[current.fixtureId]?.frozen != true {
            clockAnchor[current.fixtureId] = nil
        }
        establishClockAnchor(isFirstObservation: prev == nil || resync, current: current)

        rejectedSnapshots.remove(current.fixtureId)
        session.applyLiveFixture(current)

        if prev == nil || resync {
            AppLog.info(.fixtures, "baseline_seeded fixture_id=\(current.fixtureId) reason=\(resync ? "observation_gap" : "first") status=\(current.status) score=\(current.home.goals)-\(current.away.goals)")
            if resync {
                // How often do we drop a whole delta on the floor? Only this says so.
                AppAnalytics.snapshotRejected(reason: "observation_gap")
            }
        } else {
            let events = MatchDiff.diff(prev: prev, next: current)
            for event in events {
                EventRouter.shared.route(event)
            }
            if !events.isEmpty {
                AppLog.info(.fixtures, "diff_fired fixture_id=\(current.fixtureId) events=\(events.count)")
                // Once per state change — this branch is what keeps the live
                // loop's thousand quiet reads per match silent in analytics.
                AppAnalytics.matchEventsEmitted(events)
            }
        }

        baseline[current.fixtureId] = current
        baselineObservedAt[current.fixtureId] = now
        if current.isCalledOff, finished.insert(current.fixtureId).inserted {
            AppLog.info(.fixtures, "fixture_called_off fixture_id=\(current.fixtureId) raw_status=\(current.rawStatus ?? "")")
        }
        if current.status == "FINISHED", finished.insert(current.fixtureId).inserted {
            // First time we see this match end — its events will never recur, so
            // drop them from the dedupe store instead of letting it grow forever.
            EventRouter.shared.purgeEvents(forFixture: current.fixtureId)
        }
    }

    /// True when too long has passed since we last confirmed this fixture's
    /// baseline against the CDN — i.e. we stopped watching rather than saw
    /// nothing happen. A fixture with no stamp yet (first observation) is not
    /// stale; `ingest` already seeds that case silently.
    private func baselineIsStale(_ fixtureId: Int, at now: Date) -> Bool {
        guard let observedAt = baselineObservedAt[fixtureId] else { return false }
        return now.timeIntervalSince(observedAt) > Self.maxObservationGap
    }

    /// True from ~5 min before kickoff until the match file reports FINISHED,
    /// capped at kickoff+3.5h — driven by the SCHEDULE's kickoff time, never the
    /// fixtures file's possibly-stale cached status (§3 coupling).
    private func isInLiveWindow(_ fixture: Fixture, at now: Date) -> Bool {
        if finished.contains(fixture.fixtureId) || fixture.isCalledOff { return false }
        guard let kickoff = fixture.kickoff else {
            // No kickoff to key off: fall back to the file's own status.
            return fixture.isLive
        }
        let start = kickoff.addingTimeInterval(-Self.preKickoffLead)
        let end = kickoff.addingTimeInterval(Self.maxLiveWindow)
        return now >= start && now <= end
    }
}
