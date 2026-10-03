import { LeagueSeasons } from "./catalog.js";
import { env } from "./env.js";
import type { ScoreProvider } from "./providers/types.js";
import { CACHE_CONTROL_LONG, R2, R2ConflictError, R2MatchStateStore } from "./r2.js";
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

// 5 minutes, matching when the app starts polling `matches/{id}.json`. At the
// old 60s the object did not exist yet for the app's first four minutes of
// polling, so every client 404'd its way to kickoff.
const STARTING_SOON_MS = 5 * 60_000;

export function isStartingSoon(match: MatchState, now = Date.now()): boolean {
  if (match.status !== "SCHEDULED") return false;
  const untilKickoff = Date.parse(match.kickoffISO) - now;
  return untilKickoff <= STARTING_SOON_MS && untilKickoff > -15 * 60_000;
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

/** Provider codes for a match that will not be (or stopped being) played:
 * postponed, cancelled, abandoned, technical loss, walkover. */
export const CALLED_OFF_RAW_STATUSES = new Set(["PST", "CANC", "ABD", "AWD", "WO"]);

/**
 * A match the provider moved to a non-playing status (OTHER: postponed,
 * cancelled, abandoned, suspended, ...) around its kickoff. Its state file
 * must still be published, or clients keep the last LIVE snapshot and free-run
 * the clock until their time cap.
 */
export function isRecentlyInterrupted(match: MatchState, now = Date.now()): boolean {
  if (match.status !== "OTHER") return false;
  const sinceKickoff = now - Date.parse(match.kickoffISO);
  return sinceKickoff >= -STARTING_SOON_MS && sinceKickoff < FINISHED_AFTER_KO_MS;
}

// `fixtures-{date}.json` is served with a 12h edge TTL, so it must carry ONLY
// schedule/bootstrap data — kickoff time, teams, stage. Baking live status/
// minute/score into it lets Cloudflare freeze a mid-match snapshot at the edge
// for up to 12h (the app then shows e.g. a stuck "86′"), and rewrites the
// long-TTL object on every live tick. Live data flows solely via matches/*.json.
// The one status it does carry is "called off" (postponed/cancelled/...): that
// is schedule data, stable for hours, and must not read as an ordinary kickoff.
export function toScheduleRow(m: MatchState): MatchState {
  const calledOff = m.status === "OTHER" && CALLED_OFF_RAW_STATUSES.has(m.rawStatus);
  const schedTeam = (t: MatchState["home"]): MatchState["home"] => ({
    id: t.id,
    name: t.name,
    goals: 0,
    yellowCards: 0,
    redCards: 0,
    yellowCardEvents: [],
    redCardEvents: [],
    goalEvents: [],
    subs: [],
  });
  return {
    fixtureId: m.fixtureId,
    leagueId: m.leagueId,
    season: m.season,
    round: m.round,
    kickoffISO: m.kickoffISO,
    secondHalfStartISO: null,
    status: calledOff ? "OTHER" : "SCHEDULED",
    rawStatus: calledOff ? m.rawStatus : "NS",
    minute: null,
    extra: null,
    period: calledOff ? "OTHER" : "PRE",
    running: false,
    home: schedTeam(m.home),
    away: schedTeam(m.away),
    varEvents: [],
    // lastGoal / shootout intentionally dropped — schedule data only.
  };
}

/** Compact one-line-ish summary of a published state for `match_state_published`. */
function summarizeState(s: MatchState) {
  return {
    score: `${s.home.goals}-${s.away.goals}`,
    minute: s.minute, extra: s.extra, rawStatus: s.rawStatus, period: s.period,
    eventCounts: {
      homeGoals: s.home.goalEvents.length, awayGoals: s.away.goalEvents.length,
      homeSubs: s.home.subs?.length ?? 0, awaySubs: s.away.subs?.length ?? 0,
    },
    lastGoal: s.lastGoal ? { teamId: s.lastGoal.teamId, player: s.lastGoal.player } : null,
  };
}

/** API-Football's `ids` parameter accepts at most 20 fixture ids per request. */
const ENRICH_BATCH_SIZE = 20;

function idBatches(ids: number[]): number[][] {
  const batches: number[][] = [];
  for (let i = 0; i < ids.length; i += ENRICH_BATCH_SIZE) {
    batches.push(ids.slice(i, i + ENRICH_BATCH_SIZE));
  }
  return batches;
}

/**
 * A FINISHED row from the range endpoint carries no events, so publishing it
 * as-is would wipe the scorers, cards and subs the live ticks already
 * published. Keep the event metadata from the previous state; the score and
 * status still come from the new row.
 */
export function withEventsFrom(previous: MatchState, next: MatchState): MatchState {
  const team = (prev: MatchState["home"], cur: MatchState["home"]): MatchState["home"] => ({
    ...cur,
    yellowCards: prev.yellowCards,
    redCards: prev.redCards,
    yellowCardEvents: prev.yellowCardEvents,
    redCardEvents: prev.redCardEvents,
    goalEvents: prev.goalEvents,
    subs: prev.subs,
  });
  const merged: MatchState = {
    ...next,
    home: team(previous.home, next.home),
    away: team(previous.away, next.away),
    varEvents: previous.varEvents ?? next.varEvents,
  };
  if (previous.lastGoal) merged.lastGoal = previous.lastGoal;
  if (next.shootout && next.shootout.kicks.length === 0 && previous.shootout) {
    merged.shootout = { ...next.shootout, kicks: previous.shootout.kicks };
  }
  return merged;
}

/**
 * One range call per league, run concurrently, concatenated. API-Football's
 * `league` parameter takes a single integer, so this is N calls however it is
 * dressed up; the tick's wall time is still one call.
 *
 * The range endpoint omits events, so live fixtures are re-read through the
 * `ids` endpoint — but ACROSS leagues, once the five ranges are back. Live
 * fixtures rarely exceed 20 in total, so a normal night spends one enrichment
 * call instead of one per league with a live match.
 */
export async function fetchLeagueFixtures(
  provider: ScoreProvider,
  leagues: Array<{ leagueId: number; season: number }>,
  range: { from: string; to: string },
): Promise<{ fixtures: MatchState[]; byLeague: Array<{ leagueId: number; fixtures: number }> }> {
  const perLeague = await Promise.all(
    leagues.map(({ leagueId, season }) =>
      provider.fixturesForRange(leagueId, season, range.from, range.to)),
  );
  const fixtures = perLeague.flat();

  const liveIds = [...new Set(fixtures.filter(isLive).map((m) => m.fixtureId))];
  if (liveIds.length > 0) {
    const batches = idBatches(liveIds);
    log.info("poll_enrich_live", { liveFixtureIds: liveIds, batches: batches.length });
    const enriched = (await Promise.all(batches.map((ids) => provider.fixturesByIds(ids)))).flat();
    const byId = new Map(enriched.map((m) => [m.fixtureId, m]));
    for (const [i, fixture] of fixtures.entries()) {
      // A requested id the API omits keeps its base fixture — worse (no events)
      // beats dropping a live match out of the pass entirely.
      const replacement = byId.get(fixture.fixtureId);
      if (replacement) fixtures[i] = replacement;
    }
  }

  return {
    fixtures,
    byLeague: leagues.map(({ leagueId }, i) => ({ leagueId, fixtures: perLeague[i]!.length })),
  };
}

/**
 * The `fixtures-{date}.json` writes for today±1 — schedule/bootstrap data on the
 * long edge TTL, live state never. Written by BOTH the live tick and the
 * schedule sync, from the same source through the same projection, so the
 * overlap is a harmless identical rewrite. A date with no fixtures is still
 * written (empty), because the app and the dispatcher gate both read the file
 * and must not confuse "no football today" with "the file is missing".
 */
export async function publishScheduleFiles(
  r2: R2,
  fixtures: MatchState[],
  range: { from: string; to: string },
  today = new Date().toISOString().slice(0, 10),
): Promise<string[]> {
  const partitions = partitionFixtures(fixtures);
  for (const date of [range.from, today, range.to]) {
    if (!partitions.has(date)) partitions.set(date, []);
  }
  await Promise.all([...partitions].map(([date, matches]) =>
    r2.putJsonIfChanged(
      `fixtures-${date}.json`,
      { matches: matches.map(toScheduleRow) },
      CACHE_CONTROL_LONG,
    ),
  ));
  return [...partitions.keys()];
}

export class Poller {
  constructor(
    private readonly provider: ScoreProvider,
    private readonly state: R2MatchStateStore,
    private readonly r2: R2,
    private readonly seasons: LeagueSeasons = new LeagueSeasons(r2),
    private readonly leagueIds: number[] = env.leagueIds,
  ) {}

  // A single fetch: one provider read PER LEAGUE (API-Football's `league`
  // parameter takes one integer, so five leagues is five range calls), publish
  // dated fixtures + per-match state files (the live source). Freshness is the
  // short cache TTL on those files; no push, no diff, no purge. Cadence (e.g.
  // every 5s) is driven externally by staggered Cloud Tasks (see tasks.ts) so
  // the request returns immediately instead of sleeping/hogging CPU — and the
  // dispatcher only enqueues those tasks inside a match window.
  async fetchOnce(): Promise<{ live: number }> {
    const started = Date.now();

    const range = utcPollRange();
    const leagues = await this.seasons.resolve(this.leagueIds);
    log.info("poll_start", { ...range, leagues });
    const { fixtures, byLeague } = await fetchLeagueFixtures(this.provider, leagues, range);
    const liveCount = fixtures.filter(isLive).length;
    log.info("poll_provider_complete", { fixtures: fixtures.length, live: liveCount, byLeague });

    const eligible = fixtures.filter((m) =>
      isStartingSoon(m) || isLive(m) || isRecentlyFinished(m) || isRecentlyInterrupted(m));
    // Fixture date files are schedule/bootstrap data. Live changes are served
    // from matches/*.json, so fixtures always use the long edge TTL.
    await publishScheduleFiles(this.r2, fixtures, range);

    log.info("poll_eligible_fixtures", {
      count: eligible.length,
      // Per-fixture snapshot rich enough to debug clock/score/event staggering
      // next time (extra, period, per-side goals, event & sub counts).
      fixtures: eligible.map((m) => ({
        fixtureId: m.fixtureId, status: m.status, rawStatus: m.rawStatus,
        minute: m.minute, extra: m.extra, period: m.period,
        homeGoals: m.home.goals, awayGoals: m.away.goals,
        homeGoalEvents: m.home.goalEvents.length, awayGoalEvents: m.away.goalEvents.length,
        homeSubs: m.home.subs?.length ?? 0, awaySubs: m.away.subs?.length ?? 0,
        homeCards: m.home.yellowCards + m.home.redCards,
        awayCards: m.away.yellowCards + m.away.redCards,
      })),
    });
    const previousById = new Map(await Promise.all(
      eligible.map(async (m) => [m.fixtureId, await this.state.load(m.fixtureId)] as const),
    ));
    const finals = await this.finalSnapshots(eligible, previousById);
    for (const fixture of eligible) {
      const previous = previousById.get(fixture.fixtureId)!;
      const match = finals.get(fixture.fixtureId) ?? fixture;
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
      // The state file is actually changing — record before→after so a bad
      // publish (wrong score, stuck clock, missing scorer) is auditable, and
      // flag any per-side goal DROP (real VAR disallow vs a transient glitch).
      log.info("match_state_published", {
        fixtureId: match.fixtureId,
        before: previous.state ? summarizeState(previous.state) : null,
        after: summarizeState(match),
      });
      for (const side of ["home", "away"] as const) {
        const before = previous.state?.[side].goals ?? 0;
        if (match[side].goals < before) {
          log.warning("score_decreased", {
            fixtureId: match.fixtureId, side, before, after: match[side].goals,
            rawStatus: match.rawStatus, minute: match.minute,
          });
        }
      }
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

  /**
   * The publishable FINISHED snapshots, keyed by fixture id. The range endpoint
   * has no events, so a match crossing into FINISHED is re-read once through
   * the ids endpoint for its final scorers/cards; every other FINISHED row (or
   * a failed detail read) keeps the events already published.
   */
  private async finalSnapshots(
    eligible: MatchState[],
    previousById: Map<number, { state: MatchState | null }>,
  ): Promise<Map<number, MatchState>> {
    const finals = new Map<number, MatchState>();
    const finished = eligible.filter((m) => m.status === "FINISHED");
    if (finished.length === 0) return finals;

    const crossing = finished
      .filter((m) => previousById.get(m.fixtureId)?.state?.status !== "FINISHED")
      .map((m) => m.fixtureId);
    if (crossing.length > 0) {
      try {
        const detailed = (await Promise.all(
          idBatches(crossing).map((ids) => this.provider.fixturesByIds(ids)),
        )).flat();
        for (const m of detailed) {
          if (m.status === "FINISHED") finals.set(m.fixtureId, m);
        }
        log.info("poll_enrich_finished", { fixtureIds: crossing, enriched: finals.size });
      } catch (error) {
        log.error("poll_enrich_finished_failed", error, { fixtureIds: crossing });
      }
    }
    for (const m of finished) {
      const previous = previousById.get(m.fixtureId)?.state;
      if (!finals.has(m.fixtureId) && previous) finals.set(m.fixtureId, withEventsFrom(previous, m));
    }
    return finals;
  }
}
