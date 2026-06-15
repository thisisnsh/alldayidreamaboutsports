import type { Store } from "./store.js";
import type { R2 } from "./r2.js";
import { log } from "./log.js";

/**
 * In-memory tap aggregator. Each instance buffers incoming batched celebrate
 * requests and flushes ONE sharded-counter increment per fixture every
 * `flushMs` — Firestore write volume is O(instances), not O(users).
 */
export class CelebrationAggregator {
  private buffer = new Map<number, Record<string, number>>();
  private timer: NodeJS.Timeout | null = null;

  constructor(
    private readonly store: Store,
    private readonly r2: R2,
    private readonly flushMs = 1500,
  ) {}

  add(fixtureId: number, teamId: string, taps: number): void {
    const counts = this.buffer.get(fixtureId) ?? {};
    counts[teamId] = (counts[teamId] ?? 0) + taps;
    this.buffer.set(fixtureId, counts);
    log.info("celebration_buffered", { fixtureId, teamId, taps, pendingFixtures: this.buffer.size });
  }

  /** Visible for tests. */
  pending(): ReadonlyMap<number, Record<string, number>> {
    return this.buffer;
  }

  async flush(): Promise<void> {
    if (this.buffer.size === 0) return;
    const batch = this.buffer;
    this.buffer = new Map();
    log.info("celebration_flush_start", { fixtures: batch.size });
    await Promise.all([...batch].map(async ([fixtureId, counts]) => {
      try {
        await this.store.addCelebrations(fixtureId, counts);
        const totals = await this.store.celebrationTotals(fixtureId);
        await this.r2.putJson(`celebrate/${fixtureId}.json`, { totals }, 2);
        log.info("celebration_flush_complete", { fixtureId, counts, totals });
      } catch (error) {
        log.error("celebration_flush_failed", error, { fixtureId, counts });
        const pending = this.buffer.get(fixtureId) ?? {};
        for (const [teamId, taps] of Object.entries(counts)) {
          pending[teamId] = (pending[teamId] ?? 0) + taps;
        }
        this.buffer.set(fixtureId, pending);
      }
    }));
  }

  start(): void {
    if (this.timer) return;
    this.timer = setInterval(() => void this.flush(), this.flushMs);
    this.timer.unref();
  }

  async stop(): Promise<void> {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
    await this.flush();
  }
}
