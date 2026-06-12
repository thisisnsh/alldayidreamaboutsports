import { Fcm } from "./fcm.js";
import type { ScoreProvider } from "./providers/types.js";
import { R2 } from "./r2.js";
import type { Store } from "./store.js";
import { TEAMS } from "./teams.js";
import type { MatchState } from "./types.js";

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

function liveJsonPayload(matches: MatchState[]) {
  return { generatedAt: new Date().toISOString(), matches };
}

/**
 * One scheduler tick = up to 4 polls 15s apart, finishing inside the 60s
 * schedule so ticks never overlap. Publish-once safety lives in
 * Store.applyMatchState, so even overlapping ticks cannot double-fire events.
 */
export class Poller {
  private lastPublishedCounts = new Map<number, string>();
  private staticsUploadedFor: string | null = null;

  constructor(
    private readonly provider: ScoreProvider,
    private readonly store: Store,
    private readonly fcm: Fcm,
    private readonly r2: R2,
    private readonly sleeper: (ms: number) => Promise<unknown> = sleep,
  ) {}

  async tick(iterations = 4, intervalMs = 15_000): Promise<{ events: number; live: number }> {
    let totalEvents = 0;
    let liveCount = 0;
    await this.ensureDailyStatics();

    for (let i = 0; i < iterations; i++) {
      if (i > 0) await this.sleeper(intervalMs);
      const live = await this.provider.liveMatches();
      liveCount = live.length;

      for (const match of live) {
        const events = await this.store.applyMatchState(match);
        totalEvents += events.length;
        for (const ev of events) {
          await this.fcm.publishEvent(ev);
        }
      }

      await this.r2.putJson("live.json", liveJsonPayload(live), 20);
      await this.publishCelebrationCounts(live);

      if (live.length === 0) break; // nothing in play — don't burn 3 more calls
    }
    return { events: totalEvents, live: liveCount };
  }

  private async publishCelebrationCounts(live: MatchState[]): Promise<void> {
    for (const match of live) {
      const totals = await this.store.celebrationTotals(match.fixtureId);
      const fingerprint = JSON.stringify(totals);
      if (fingerprint === this.lastPublishedCounts.get(match.fixtureId)) continue;
      this.lastPublishedCounts.set(match.fixtureId, fingerprint);
      await this.r2.putJson(`celebrate/${match.fixtureId}.json`, { totals }, 2);
      await this.fcm.publishCelebrationCount(
        match.leagueId,
        match.fixtureId,
        match.home.code,
        match.away.code,
        totals,
      );
    }
  }

  /** Once per process per UTC day: fixtures-{date}.json + teams.json. */
  private async ensureDailyStatics(): Promise<void> {
    const today = new Date().toISOString().slice(0, 10);
    if (this.staticsUploadedFor === today) return;
    const fixtures = await this.provider.fixturesForDate(today);
    await this.r2.putJson(`fixtures-${today}.json`, liveJsonPayload(fixtures), 3600);
    await this.r2.putJson("teams.json", { teams: TEAMS }, 3600);
    this.staticsUploadedFor = today;
  }
}
