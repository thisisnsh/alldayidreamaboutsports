import { env } from "./env.js";
import type { Store } from "./store.js";
import { CACHE_CONTROL_LIVE, type R2 } from "./r2.js";
import { log } from "./log.js";

/**
 * In-memory tap aggregator. Each instance buffers incoming batched celebrate
 * requests and flushes ONE sharded-counter increment per fixture every
 * `flushMs` — Firestore write volume is O(instances), not O(users). The read
 * half of a flush is sampled (`publishRate`) so the READ volume is sub-linear
 * in instances too.
 */
export class CelebrationAggregator {
  private buffer = new Map<number, Record<string, number>>();
  /** Fixtures whose shards moved since their totals file was last written. */
  private unpublished = new Set<number>();
  /** Resolvers for the `add()` calls whose taps are still in `buffer`. */
  private waiting = new Map<number, Array<() => void>>();
  private timer: NodeJS.Timeout | null = null;
  private flushing: Promise<void> = Promise.resolve();
  private flushesQueued = 0;

  constructor(
    private readonly store: Store,
    private readonly r2: R2,
    private readonly flushMs = 1500,
    // Only a `sampleRate` fraction of clients report taps; the published total is
    // scaled back up by 1/sampleRate to estimate the global count. 1.0 = exact.
    private readonly sampleRate = env.celebrationSampleRate,
    // Probability that a flush also reads the shards and republishes. See below.
    private readonly publishRate = env.celebrationPublishRate,
    private readonly random: () => number = Math.random,
  ) {}

  /** Buffer taps. Resolves once the flush carrying them has incremented the
   * shards — `/celebrate` holds its response on this, because with Cloud
   * Run's request-based CPU allocation an instance only gets CPU while a
   * request is open, so an idle flush timer is not guaranteed to run. */
  add(fixtureId: number, teamId: string, taps: number): Promise<void> {
    // Null prototype: a team id can never resolve to an inherited property.
    const counts = this.buffer.get(fixtureId) ?? Object.create(null) as Record<string, number>;
    counts[teamId] = (counts[teamId] ?? 0) + taps;
    this.buffer.set(fixtureId, counts);
    log.info("celebration_buffered", { fixtureId, teamId, taps, pendingFixtures: this.buffer.size });
    return new Promise((resolve) => {
      this.waiting.set(fixtureId, [...(this.waiting.get(fixtureId) ?? []), resolve]);
    });
  }

  /** Visible for tests. */
  pending(): ReadonlyMap<number, Record<string, number>> {
    return this.buffer;
  }

  /** Flushes run one at a time, so `stop()` can drain whatever is in flight
   * (its batch has already left the buffer) before the process exits. */
  flush(): Promise<void> {
    // Take the batch now: taps that arrive while it waits go to the next one.
    const batch = this.buffer;
    const waiters = this.waiting;
    this.buffer = new Map();
    this.waiting = new Map();
    const run = this.flushing.then(() => this.flushBatch(batch, waiters));
    this.flushing = run.catch(() => undefined);
    return run;
  }

  private async flushBatch(
    batch: Map<number, Record<string, number>>,
    waiters: Map<number, Array<() => void>>,
  ): Promise<void> {
    if (batch.size === 0 && this.unpublished.size === 0) return;
    log.info("celebration_flush_start", { fixtures: batch.size, unpublished: this.unpublished.size });
    // ALWAYS increment: this is the half that must not lose a tap. Only a
    // failed increment goes back in the buffer — a later publish failure must
    // never re-add counts the shards already hold.
    const incremented = new Set<number>();
    await Promise.all([...batch].map(async ([fixtureId, counts]) => {
      try {
        await this.store.addCelebrations(fixtureId, counts);
        incremented.add(fixtureId);
        this.unpublished.add(fixtureId);
        for (const resolve of waiters.get(fixtureId) ?? []) resolve();
      } catch (error) {
        log.error("celebration_increment_failed", error, { fixtureId, counts });
        const pending = this.buffer.get(fixtureId) ?? Object.create(null) as Record<string, number>;
        for (const [teamId, taps] of Object.entries(counts)) {
          pending[teamId] = (pending[teamId] ?? 0) + taps;
        }
        this.buffer.set(fixtureId, pending);
        // The requests wait on the retry, not on this failed attempt.
        this.waiting.set(fixtureId, [...(this.waiting.get(fixtureId) ?? []), ...(waiters.get(fixtureId) ?? [])]);
      }
    }));
    await Promise.all([...this.unpublished].map((fixtureId) =>
      this.publish(fixtureId, incremented.has(fixtureId))));
  }

  /** Read the shards and republish `celebrate/{id}.json`. A failure leaves the
   * fixture in `unpublished`, so a later flush retries the publish alone. */
  private async publish(fixtureId: number, sampled: boolean): Promise<void> {
    // Only sometimes read-and-publish. `celebrationTotals` reads all shards,
    // and at ~30 instances × a flush every 1.5s that is ~19k Firestore reads
    // per goal. Cloud Run instances are stateless and disposable, so there
    // is nowhere to cache the result — thinning it by probability needs no
    // coordination between instances and still republishes ~2×/second,
    // which is already faster than the 5s edge TTL can serve. Only a flush
    // that brought new taps is sampled: a sampled-out fixture stays in
    // `unpublished`, so the first quiet flush after its taps stop always
    // publishes the final total.
    if (sampled && this.random() >= this.publishRate) {
      log.info("celebration_publish_sampled_out", { fixtureId, publishRate: this.publishRate });
      return;
    }
    try {
      const reported = await this.store.celebrationTotals(fixtureId);
      // Scale the sampled (reported) totals up to an estimated global total.
      const scale = this.sampleRate > 0 ? 1 / this.sampleRate : 1;
      const totals: Record<string, number> = {};
      for (const [team, n] of Object.entries(reported)) {
        totals[team] = Math.round(n * scale);
      }
      await this.r2.putJson(`celebrate/${fixtureId}.json`, { totals }, CACHE_CONTROL_LIVE);
      this.unpublished.delete(fixtureId);
      log.info("celebration_publish_complete", { fixtureId, reported, totals });
    } catch (error) {
      log.error("celebration_publish_failed", error, { fixtureId });
    }
  }

  start(): void {
    if (this.timer) return;
    this.timer = setInterval(() => {
      // A slow Firestore must not pile a queue of ticks up behind it.
      if (this.flushesQueued > 0) return;
      this.flushesQueued++;
      void this.flush().finally(() => this.flushesQueued--);
    }, this.flushMs);
    this.timer.unref();
  }

  async stop(): Promise<void> {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
    // Queued behind any in-flight flush, so that batch commits first.
    await this.flush();
  }
}
