import { LeagueSeasons } from "./catalog.js";
import { env } from "./env.js";
import { fetchLeagueFixtures, publishScheduleFiles, utcPollRange } from "./poller.js";
import type { ScoreProvider } from "./providers/types.js";
import type { R2 } from "./r2.js";
import { log } from "./log.js";

/**
 * Keeps `fixtures-{date}.json` alive while the poller is asleep.
 *
 * The live tick already writes these files, but it only runs inside a match
 * window — and the dispatcher decides whether to OPEN that window by reading
 * them. A gate that depends on a file only the gated job writes would never
 * open: on a Wednesday with no football, the file for that date is never
 * written at all.
 *
 * So this runs on its own schedule (every 6h), independent of the poller: five
 * range calls for today±1, projected through the same `toScheduleRow` and
 * written to the same three keys. While the poller IS running it writes
 * identical content from the same source, so the overlap is a no-op.
 *
 * 20 calls/day, against a 75,000/day quota.
 */
export class ScheduleService {
  constructor(
    private readonly provider: ScoreProvider,
    private readonly r2: R2,
    private readonly seasons: LeagueSeasons = new LeagueSeasons(r2),
    private readonly leagueIds: number[] = env.leagueIds,
  ) {}

  async sync(): Promise<{ dates: string[]; fixtures: number }> {
    const started = Date.now();
    const range = utcPollRange();
    const leagues = await this.seasons.resolve(this.leagueIds);
    log.info("schedule_sync_start", { ...range, leagues });

    const { fixtures, byLeague } = await fetchLeagueFixtures(this.provider, leagues, range);
    const dates = await publishScheduleFiles(this.r2, fixtures, range);

    log.info("schedule_sync_complete", {
      dates, fixtures: fixtures.length, byLeague, durationMs: Date.now() - started,
    });
    return { dates, fixtures: fixtures.length };
  }
}
