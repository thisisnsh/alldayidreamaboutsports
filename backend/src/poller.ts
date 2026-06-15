import { diffMatch } from "./diff.js";
import { Fcm } from "./fcm.js";
import type { ScoreProvider } from "./providers/types.js";
import { R2, R2ConflictError, R2MatchStateStore } from "./r2.js";
import type { MatchState } from "./types.js";

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
    private readonly fcm: Fcm,
    private readonly r2: R2,
  ) {}

  // A single fetch: one provider read, publish dated fixtures, diff and notify.
  // Cadence (e.g. every 5s) is driven externally by staggered Cloud Tasks (see
  // tasks.ts) so the request returns immediately instead of sleeping/hogging CPU.
  async fetchOnce(): Promise<{ events: number; live: number }> {
    let totalEvents = 0;

    const range = utcPollRange();
    const fixtures = await this.provider.fixturesForRange(range.from, range.to);
    const liveCount = fixtures.filter(isLive).length;

    const partitions = partitionFixtures(fixtures);
    for (const date of [range.from, new Date().toISOString().slice(0, 10), range.to]) {
      if (!partitions.has(date)) partitions.set(date, []);
    }
    await Promise.all([...partitions].map(([date, matches]) =>
      this.r2.putJsonIfChanged(`fixtures-${date}.json`, { matches }, 10),
    ));

    for (const match of fixtures.filter((m) => isLive(m) || isRecentlyFinished(m))) {
      const previous = await this.state.load(match.fixtureId);
      const events = diffMatch(previous.state, match);
      for (const event of events) {
        console.log(JSON.stringify({ severity: "INFO", message: "match_event_detected", event }));
        await this.fcm.publishEvent(event);
        totalEvents++;
      }
      // Unchanged vs the loaded R2 state — skip the write.
      if (JSON.stringify(previous.state) === JSON.stringify(match)) continue;
      try {
        await this.state.save(match, previous.etag);
      } catch (error) {
        if (error instanceof R2ConflictError) {
          console.warn(JSON.stringify({
            severity: "WARNING",
            message: "match_state_conflict",
            fixtureId: match.fixtureId,
          }));
        } else {
          throw error;
        }
      }
    }
    return { events: totalEvents, live: liveCount };
  }
}
