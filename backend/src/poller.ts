import type { ScoreProvider } from "./providers/types.js";
import { CACHE_CONTROL_LIVE, CACHE_CONTROL_LONG, R2, R2ConflictError, R2MatchStateStore } from "./r2.js";
import type { MatchState } from "./types.js";
import { log } from "./log.js";

export function utcPollRange(now = new Date()): { from: string; to: string } {
  const date = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()));
  const day = (offset: number) => new Date(date.getTime() + offset * 86_400_000).toISOString().slice(0, 10);
  return { from: day(-1), to: day(1) };
}

export function partitionFixtures(matches: MatchState[]): Map<string, MatchState[]> {
  const partitions = new Map<string, MatchState[]>();
  for (const match of matches) {
    const date = match.kickoffISO.slice(0, 10);
    partitions.set(date, [...(partitions.get(date) ?? []), match]);
  }
  return partitions;
}

export function isLive(match: MatchState): boolean {
  return match.status === "LIVE" || match.status === "HALF_TIME";
}

export function isStartingSoon(match: MatchState, now = Date.now()): boolean {
  if (match.status !== "SCHEDULED") return false;
  const untilKickoff = Date.parse(match.kickoffISO) - now;
  return untilKickoff <= 60_000 && untilKickoff > -15 * 60_000;
}

export function isRegressiveSnapshot(previous: MatchState, next: MatchState): boolean {
  if (previous.status === "FINISHED" && next.status !== "FINISHED") return true;
  if (
    (previous.status === "LIVE" || previous.status === "HALF_TIME")
    && next.status === "SCHEDULED"
  ) return true;
  return false;
}

const FINISHED_AFTER_2H_MS = 2.5 * 60 * 60 * 1000; // > ET(30) + breaks + pens(~15) after 2nd-half KO
const FINISHED_AFTER_KO_MS = 4 * 60 * 60 * 1000; // fallback when periods.second is absent

// API-Football gives no finish time, so a just-finished match (still worth
// diffing for FULL_TIME) is detected by 2nd-half-kickoff recency, falling back
// to scheduled kickoff. Old results drop out and stop costing a read.
export function isRecentlyFinished(match: MatchState, now = Date.now()): boolean {
  if (match.status !== "FINISHED") return false;
  if (match.secondHalfStartISO) {
    return now - Date.parse(match.secondHalfStartISO) < FINISHED_AFTER_2H_MS;
  }
  return now - Date.parse(match.kickoffISO) < FINISHED_AFTER_KO_MS;
}

export class Poller {
  constructor(
    private readonly provider: ScoreProvider,
    private readonly state: R2MatchStateStore,
    private readonly r2: R2,
  ) {}

  // A single fetch: one provider read, publish dated fixtures + per-match state
  // files (the live source). Freshness is the short cache TTL on those files; no
  // push, no diff, no purge. Cadence (e.g. every 5s) is driven externally by
  // staggered Cloud Tasks (see tasks.ts) so the request returns immediately
  // instead of sleeping/hogging CPU.
  async fetchOnce(): Promise<{ live: number }> {
    const started = Date.now();

    const range = utcPollRange();
    log.info("poll_start", range);
    const fixtures = await this.provider.fixturesForRange(range.from, range.to);
    const liveCount = fixtures.filter(isLive).length;
    log.info("poll_provider_complete", { fixtures: fixtures.length, live: liveCount });

    const eligible = fixtures.filter((m) => isStartingSoon(m) || isLive(m) || isRecentlyFinished(m));
    // A date file gets the live (5s+SWR) TTL when it's today or holds any
    // eligible match; otherwise the long (12h) schedule TTL.
    const today = new Date().toISOString().slice(0, 10);
    const liveDates = new Set<string>([today, ...eligible.map((m) => m.kickoffISO.slice(0, 10))]);

    const partitions = partitionFixtures(fixtures);
    for (const date of [range.from, today, range.to]) {
      if (!partitions.has(date)) partitions.set(date, []);
    }
    await Promise.all([...partitions].map(([date, matches]) =>
      this.r2.putJsonIfChanged(
        `fixtures-${date}.json`,
        { matches },
        liveDates.has(date) ? CACHE_CONTROL_LIVE : CACHE_CONTROL_LONG,
      ),
    ));

    log.info("poll_eligible_fixtures", {
      count: eligible.length,
      fixtures: eligible.map((m) => ({
        fixtureId: m.fixtureId, status: m.status, rawStatus: m.rawStatus, minute: m.minute,
      })),
    });
    for (const match of eligible) {
      const previous = await this.state.load(match.fixtureId);
      if (previous.state && isRegressiveSnapshot(previous.state, match)) {
        log.warning("match_snapshot_regression_ignored", {
          fixtureId: match.fixtureId,
          previousStatus: previous.state.status,
          previousRawStatus: previous.state.rawStatus,
          nextStatus: match.status,
          nextRawStatus: match.rawStatus,
        });
        continue;
      }
      // Unchanged vs the loaded R2 state — skip the write.
      if (JSON.stringify(previous.state) === JSON.stringify(match)) continue;
      try {
        await this.state.save(match, previous.etag);
      } catch (error) {
        if (error instanceof R2ConflictError) {
          log.warning("match_state_conflict", {
            fixtureId: match.fixtureId,
          });
        } else {
          throw error;
        }
      }
    }
    log.info("poll_complete", {
      live: liveCount, durationMs: Date.now() - started,
    });
    return { live: liveCount };
  }
}
