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

// `fixtures-{date}.json` is served with a 12h edge TTL, so it must carry ONLY
// schedule/bootstrap data — kickoff time, teams, stage. Baking live status/
// minute/score into it lets Cloudflare freeze a mid-match snapshot at the edge
// for up to 12h (the app then shows e.g. a stuck "86′"), and rewrites the
// long-TTL object on every live tick. Live data flows solely via matches/*.json.
export function toScheduleRow(m: MatchState): MatchState {
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
    status: "SCHEDULED",
    rawStatus: "NS",
    minute: null,
    extra: null,
    period: "PRE",
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
    // Concurrent: the tick's wall time is one range call, not five.
    const perLeague = await Promise.all(
      leagues.map(({ leagueId, season }) =>
        this.provider.fixturesForRange(leagueId, season, range.from, range.to)),
    );
    const fixtures = perLeague.flat();
    const liveCount = fixtures.filter(isLive).length;
    log.info("poll_provider_complete", {
      fixtures: fixtures.length,
      live: liveCount,
      byLeague: leagues.map(({ leagueId }, i) => ({ leagueId, fixtures: perLeague[i]!.length })),
    });

    const eligible = fixtures.filter((m) => isStartingSoon(m) || isLive(m) || isRecentlyFinished(m));
    // Fixture date files are schedule/bootstrap data. Live changes are served
    // from matches/*.json, so fixtures always use the long edge TTL.
    const today = new Date().toISOString().slice(0, 10);

    const partitions = partitionFixtures(fixtures);
    for (const date of [range.from, today, range.to]) {
      if (!partitions.has(date)) partitions.set(date, []);
    }
    await Promise.all([...partitions].map(([date, matches]) =>
      this.r2.putJsonIfChanged(
        `fixtures-${date}.json`,
        { matches: matches.map(toScheduleRow) },
        CACHE_CONTROL_LONG,
      ),
    ));

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
}
