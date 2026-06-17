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
    /// Last-seen state per fixture — the diff baseline. A fixture not in here is
    /// being observed for the first time: it seeds the baseline and emits nothing.
    private var baseline: [Int: Fixture] = [:]
    /// Fixtures whose match file has reported FINISHED (stop polling them).
    private var finished: Set<Int> = []

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
        AppLog.info(.fixtures, "live_loop_stop")
    }

    /// Drop the diff baseline (e.g. on sign-out) so the next observation seeds
    /// fresh and never replays events across an account switch.
    func resetBaseline() {
        baseline = [:]
        finished = []
        cancelCelebrationRefresh()
    }

    /// Manual refresh (the menu's ↻ button): run one poll pass right now — fetch
    /// each live fan match's `matches/{id}.json`, diff/merge the score, fire any
    /// new goal's events, and kick off the celebration refresh on a score move.
    func refreshNow() async {
        guard session.isSignedIn, ControlPlane.shared.isOperational else { return }
        await pollCycle()
    }

    private func run() async {
        while !Task.isCancelled {
            if session.isSignedIn, ControlPlane.shared.isOperational {
                await session.bootstrapFixturesIfNeeded()
                await pollCycle()
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
                continue
            }
            guard session.isSignedIn, ControlPlane.shared.isOperational else { return }

            ingest(current)

            // A score move (goal / VAR correction) is the only thing that grows
            // the celebration total — taps then trickle in for a while, so we
            // re-read for a minute rather than once.
            if previous.score != current.score {
                refreshCelebrations(fixtureId: current.fixtureId)
            }
        }
        session.publishFixtures()
    }

    /// A goal just fired: re-read `celebrate/{id}.json` every
    /// `celebrationRefreshInterval`s for `celebrationRefreshWindow` so the count
    /// climbs as everyone's taps land in the CDN file — a single snapshot misses
    /// the late tappers. Restarts the window if another goal lands mid-loop.
    private func refreshCelebrations(fixtureId: Int) {
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
                }
                try? await Task.sleep(for: .seconds(Self.celebrationRefreshInterval))
            }
            celebrationRefresh[fixtureId] = nil
        }
    }

    private func cancelCelebrationRefresh() {
        for task in celebrationRefresh.values { task.cancel() }
        celebrationRefresh.removeAll()
    }

    /// Merge one freshly-read fixture into state, diffing against the baseline.
    /// BASELINE GUARD: the first observation seeds the baseline and emits NO
    /// events (don't replay pre-launch goals); only later deltas fire overlays.
    private func ingest(_ current: Fixture) {
        let prev = baseline[current.fixtureId]
        session.applyLiveFixture(current)

        if prev == nil {
            AppLog.info(.fixtures, "baseline_seeded fixture_id=\(current.fixtureId) status=\(current.status) score=\(current.home.goals)-\(current.away.goals)")
        } else {
            let events = MatchDiff.diff(prev: prev, next: current)
            for event in events {
                EventRouter.shared.route(event)
            }
            if !events.isEmpty {
                AppLog.info(.fixtures, "diff_fired fixture_id=\(current.fixtureId) events=\(events.count)")
            }
        }

        baseline[current.fixtureId] = current
        if current.status == "FINISHED" {
            finished.insert(current.fixtureId)
        }
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
