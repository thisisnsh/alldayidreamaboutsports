import { CloudTasksClient } from "@google-cloud/tasks";
import { env } from "./env.js";
import { R2 } from "./r2.js";
import type { MatchState } from "./types.js";
import { log } from "./log.js";

const GRPC_ALREADY_EXISTS = 6;

// Minimal surface we use, so tests can inject a fake without the full client.
export interface TasksClient {
  queuePath(project: string, location: string, queue: string): string;
  createTask(request: unknown): Promise<unknown>;
}

/** A match is worth polling from 30min before kickoff until 4h after it. */
const WINDOW_LEAD_MS = 30 * 60_000;
const WINDOW_TAIL_MS = 4 * 60 * 60_000;

const dayISO = (ms: number) => new Date(ms).toISOString().slice(0, 10);

/**
 * Is any match in play (or about to be)? This is the single change that keeps
 * five leagues inside the API-Football quota: the top five are live for roughly
 * 38 hours a week, not 168, and outside that the whole pipeline costs nothing.
 *
 * The window is the union of each fixture's own [kickoff−30min, kickoff+4h].
 * On a Saturday those overlap into one ~12h span; on a quiet Wednesday there is
 * no span at all. Taking a single min→max envelope instead would hold the gate
 * open all night between a late Saturday kickoff and an early Sunday one.
 *
 * Yesterday's file is read alongside today's because a 21:00 UTC kickoff runs
 * past midnight into the next UTC day.
 *
 * Cost of the gate: one R2 GET per date per instance per day.
 */
export class MatchWindow {
  private kickoffCache = new Map<string, number[]>();

  constructor(private readonly r2: R2 = new R2()) {}

  async isOpen(now = Date.now()): Promise<boolean> {
    const dates = [dayISO(now), dayISO(now - 86_400_000)];
    // Only today and yesterday are ever asked for, so the cache stays at two
    // entries — drop whatever the date roll left behind.
    for (const date of this.kickoffCache.keys()) {
      if (!dates.includes(date)) this.kickoffCache.delete(date);
    }
    const kickoffs = (await Promise.all(dates.map((date) => this.kickoffs(date)))).flat();
    return kickoffs.some((k) => now >= k - WINDOW_LEAD_MS && now <= k + WINDOW_TAIL_MS);
  }

  private async kickoffs(date: string): Promise<number[]> {
    const cached = this.kickoffCache.get(date);
    if (cached) return cached;
    let kickoffs: number[] = [];
    try {
      const file = await this.r2.getJson<{ matches: MatchState[] }>(`fixtures-${date}.json`);
      // A missing file is a closed window, not an error: it just means nothing
      // has published a schedule for that date yet.
      kickoffs = (file?.matches ?? [])
        .map((m) => Date.parse(m.kickoffISO))
        .filter((ms) => Number.isFinite(ms));
    } catch (error) {
      // Fail CLOSED. If R2 reads are failing we cannot publish match state
      // either, so polling through it would burn quota for nothing — and a
      // sustained failure that polled 24/7 would blow the daily budget.
      log.error("match_window_read_failed", error, { date });
      return [];
    }
    this.kickoffCache.set(date, kickoffs);
    log.info("match_window_loaded", { date, kickoffs: kickoffs.length });
    return kickoffs;
  }
}

/**
 * Fans a minute out into N short fetches. Cloud Scheduler is minute-granular, so
 * once a minute it hits /internal/dispatch, which enqueues N Cloud Tasks spaced
 * `stepSeconds` apart via each task's precise scheduleTime. Each task then hits
 * /internal/fetch (a single, fast read) — so we get sub-minute cadence without
 * any request sleeping and pinning the CPU.
 */
export class Dispatcher {
  constructor(
    private readonly client: TasksClient = new CloudTasksClient(),
    private readonly window: MatchWindow = new MatchWindow(),
    private readonly count = 12,
    private readonly stepSeconds = 5,
  ) {}

  async dispatch(now = Date.now()): Promise<{ enqueued: number }> {
    // Outside a match window, enqueue nothing at all — not no-op tasks, so the
    // Cloud Tasks operations drop with the API calls. The scheduler keeps
    // firing every minute; this handler is what makes it free.
    if (!await this.window.isOpen(now)) {
      log.info("dispatch_skipped_no_match_window", { minuteBucket: Math.floor(now / 60_000) });
      return { enqueued: 0 };
    }

    const parent = this.client.queuePath(env.projectId, env.tasksLocation, env.tasksQueue);
    const url = `${env.serviceUrl}/internal/fetch`;
    const startSeconds = Math.floor(now / 1000);
    const minuteBucket = Math.floor(now / 60_000);
    log.info("dispatch_start", {
      count: this.count, stepSeconds: this.stepSeconds, minuteBucket, url,
    });

    await Promise.all(
      Array.from({ length: this.count }, (_, i) =>
        Promise.resolve(
          this.client.createTask({
            parent,
            task: {
              // Deterministic name → Cloud Tasks dedups for ~1h, so a double
              // dispatch in the same minute is a no-op.
              name: `${parent}/tasks/fetch-${minuteBucket}-${i}`,
              scheduleTime: { seconds: startSeconds + i * this.stepSeconds },
              httpRequest: {
                httpMethod: "POST",
                url,
                oidcToken: {
                  serviceAccountEmail: env.schedulerServiceAccount,
                  audience: env.serviceUrl,
                },
              },
            },
          }),
        ).catch((err: { code?: number }) => {
          if (err?.code !== GRPC_ALREADY_EXISTS) throw err;
        }),
      ),
    );

    log.info("dispatch_complete", { enqueued: this.count, minuteBucket });
    return { enqueued: this.count };
  }
}
