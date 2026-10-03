import { describe, expect, it, vi } from "vitest";
import { CelebrationAggregator } from "../src/celebrations.js";
import { celebrateSchema } from "../src/routes.js";
import type { Store } from "../src/store.js";

function fakeStore() {
  return {
    addCelebrations: vi.fn().mockResolvedValue(undefined),
    celebrationTotals: vi.fn().mockResolvedValue({ "6": 12 }),
  } as unknown as Store;
}

function fakeR2() {
  return { putJson: vi.fn().mockResolvedValue(undefined) };
}

/** Publish rate 1.0 + a fixed roll: every flush publishes, deterministically. */
const ALWAYS_PUBLISH = [1500, 1.0, 1.0, () => 0] as const;

describe("CelebrationAggregator", () => {
  it("merges taps per fixture/team and flushes once", async () => {
    const store = fakeStore();
    const r2 = fakeR2();
    const agg = new CelebrationAggregator(store, r2 as never, ...ALWAYS_PUBLISH);
    agg.add(1, "6", 7);
    agg.add(1, "6", 5);
    agg.add(1, "16", 2);
    agg.add(2, "10", 1);

    await agg.flush();

    expect(store.addCelebrations).toHaveBeenCalledTimes(2);
    expect(store.addCelebrations).toHaveBeenCalledWith(1, { "6": 12, "16": 2 });
    expect(store.addCelebrations).toHaveBeenCalledWith(2, { "10": 1 });
    expect(r2.putJson).toHaveBeenCalledTimes(2);
  });

  it("clears the buffer after flush and skips empty flushes", async () => {
    const store = fakeStore();
    const agg = new CelebrationAggregator(store, fakeR2() as never);
    agg.add(1, "6", 3);
    await agg.flush();
    await agg.flush();
    expect(store.addCelebrations).toHaveBeenCalledTimes(1);
    expect(agg.pending().size).toBe(0);
  });

  it("keeps accepting taps while a flush is in flight", async () => {
    const store = fakeStore();
    const agg = new CelebrationAggregator(store, fakeR2() as never);
    agg.add(1, "6", 1);
    const flushing = agg.flush();
    agg.add(1, "6", 4); // lands in the next batch, not the in-flight one
    await flushing;
    expect(agg.pending().get(1)).toEqual({ "6": 4 });
  });

  it("publishes exact (un-scaled) totals at sampleRate 1.0 with the live cache header", async () => {
    const store = fakeStore(); // celebrationTotals -> { "6": 12 }
    const r2 = fakeR2();
    const agg = new CelebrationAggregator(store, r2 as never, 1500, 1.0, 1.0, () => 0);
    agg.add(1, "6", 12);
    await agg.flush();
    expect(r2.putJson).toHaveBeenCalledWith(
      "celebrate/1.json",
      { totals: { "6": 12 } },
      "public, max-age=5, stale-while-revalidate=25",
    );
  });

  it("multiplies the sampled total back up by 1/sampleRate", async () => {
    const store = fakeStore(); // sampled reported total -> { "6": 12 }
    const r2 = fakeR2();
    // 25% of clients reported → the estimated global total is 12 * 4 = 48.
    const agg = new CelebrationAggregator(store, r2 as never, 1500, 0.25, 1.0, () => 0);
    agg.add(1, "6", 12);
    await agg.flush();
    expect(r2.putJson).toHaveBeenCalledWith(
      "celebrate/1.json",
      { totals: { "6": 48 } },
      "public, max-age=5, stale-while-revalidate=25",
    );
  });
});

describe("celebrate input", () => {
  it("accepts only canonical numeric team ids", () => {
    const parse = (teamId: string) => celebrateSchema.safeParse({ fixtureId: 1, teamId, taps: 4 }).success;
    expect(parse("541")).toBe(true);
    for (const bad of ["constructor", "__proto__", "toString", "0", "06", "-1", "1e3", "", "1234567890123"]) {
      expect(parse(bad)).toBe(false);
    }
  });

  it("never resolves a team id to an inherited property", async () => {
    const store = fakeStore();
    const agg = new CelebrationAggregator(store, fakeR2() as never, ...ALWAYS_PUBLISH);
    agg.add(1, "constructor", 4);
    await agg.flush();
    expect(store.addCelebrations).toHaveBeenCalledWith(1, { constructor: 4 });
  });
});

describe("CelebrationAggregator sampled publish", () => {
  it("increments the shards even when the publish is sampled out", async () => {
    const store = fakeStore();
    const r2 = fakeR2();
    // roll 0.9 >= publishRate 0.1 → skip the read/publish half.
    const agg = new CelebrationAggregator(store, r2 as never, 1500, 1.0, 0.1, () => 0.9);
    agg.add(1, "6", 12);

    await agg.flush();

    // The half that must never lose a tap ran; the expensive half did not.
    expect(store.addCelebrations).toHaveBeenCalledWith(1, { "6": 12 });
    expect(store.celebrationTotals).not.toHaveBeenCalled();
    expect(r2.putJson).not.toHaveBeenCalled();
  });

  it("reads and publishes when the roll lands under the rate", async () => {
    const store = fakeStore();
    const r2 = fakeR2();
    const agg = new CelebrationAggregator(store, r2 as never, 1500, 1.0, 0.1, () => 0.05);
    agg.add(1, "6", 12);

    await agg.flush();

    expect(store.celebrationTotals).toHaveBeenCalledWith(1);
    expect(r2.putJson).toHaveBeenCalledTimes(1);
  });

  it("loses no taps at a publish rate of 0 — every flush still increments", async () => {
    const store = fakeStore();
    const r2 = fakeR2();
    const agg = new CelebrationAggregator(store, r2 as never, 1500, 1.0, 0, () => 0);
    agg.add(1, "6", 5);
    await agg.flush();
    agg.add(1, "6", 7);
    await agg.flush();

    expect(store.addCelebrations).toHaveBeenCalledTimes(2);
    expect(store.addCelebrations).toHaveBeenNthCalledWith(1, 1, { "6": 5 });
    expect(store.addCelebrations).toHaveBeenNthCalledWith(2, 1, { "6": 7 });
    // Nothing is ever republished, and nothing is left buffered either.
    expect(r2.putJson).not.toHaveBeenCalled();
    expect(agg.pending().size).toBe(0);
  });

  it("keeps roughly one flush in ten publishing at the default rate", async () => {
    const store = fakeStore();
    const r2 = fakeR2();
    // A deterministic sweep of rolls across [0,1) — 10 of 100 land under 0.1.
    let n = 0;
    const agg = new CelebrationAggregator(store, r2 as never, 1500, 1.0, 0.1, () => (n++ % 100) / 100);
    for (let i = 0; i < 100; i++) {
      agg.add(1, "6", 1);
      await agg.flush();
    }

    expect(store.addCelebrations).toHaveBeenCalledTimes(100);
    expect(r2.putJson).toHaveBeenCalledTimes(10);
  });
});
