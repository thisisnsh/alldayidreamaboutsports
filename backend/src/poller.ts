import { diffMatch } from "./diff.js";
import { Fcm } from "./fcm.js";
import type { ScoreProvider } from "./providers/types.js";
import { R2, R2ConflictError, R2MatchStateStore } from "./r2.js";
import type { MatchState } from "./types.js";

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

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

export class Poller {
  constructor(
    private readonly provider: ScoreProvider,
    private readonly state: R2MatchStateStore,
    private readonly fcm: Fcm,
    private readonly r2: R2,
    private readonly sleeper: (ms: number) => Promise<unknown> = sleep,
  ) {}

  async tick(iterations = 12, intervalMs = 5_000): Promise<{ events: number; live: number }> {
    let totalEvents = 0;
    let liveCount = 0;

    for (let i = 0; i < iterations; i++) {
      if (i > 0) await this.sleeper(intervalMs);
      const range = utcPollRange();
      const fixtures = await this.provider.fixturesForRange(range.from, range.to);
      liveCount = fixtures.filter(isLive).length;

      const partitions = partitionFixtures(fixtures);
      for (const date of [range.from, new Date().toISOString().slice(0, 10), range.to]) {
        if (!partitions.has(date)) partitions.set(date, []);
      }
      await Promise.all([...partitions].map(([date, matches]) =>
        this.r2.putJson(`fixtures-${date}.json`, {
          generatedAt: new Date().toISOString(),
          matches,
        }, 10),
      ));

      for (const match of fixtures) {
        const previous = await this.state.load(match.fixtureId);
        const events = diffMatch(previous.state, match);
        for (const event of events) {
          console.log(JSON.stringify({ severity: "INFO", message: "match_event_detected", event }));
          await this.fcm.publishEvent(event);
          totalEvents++;
        }
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
    }
    return { events: totalEvents, live: liveCount };
  }
}
