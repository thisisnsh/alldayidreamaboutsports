import { describe, expect, it, vi } from "vitest";
import { CelebrationAggregator } from "../src/celebrations.js";
import type { Store } from "../src/store.js";

function fakeStore() {
  return { addCelebrations: vi.fn().mockResolvedValue(undefined) } as unknown as Store;
}

describe("CelebrationAggregator", () => {
  it("merges taps per fixture/team and flushes once", async () => {
    const store = fakeStore();
    const agg = new CelebrationAggregator(store);
    agg.add(1, "6", 7);
    agg.add(1, "6", 5);
    agg.add(1, "16", 2);
    agg.add(2, "10", 1);

    await agg.flush();

    expect(store.addCelebrations).toHaveBeenCalledTimes(2);
    expect(store.addCelebrations).toHaveBeenCalledWith(1, { "6": 12, "16": 2 });
    expect(store.addCelebrations).toHaveBeenCalledWith(2, { "10": 1 });
  });

  it("clears the buffer after flush and skips empty flushes", async () => {
    const store = fakeStore();
    const agg = new CelebrationAggregator(store);
    agg.add(1, "6", 3);
    await agg.flush();
    await agg.flush();
    expect(store.addCelebrations).toHaveBeenCalledTimes(1);
    expect(agg.pending().size).toBe(0);
  });

  it("keeps accepting taps while a flush is in flight", async () => {
    const store = fakeStore();
    const agg = new CelebrationAggregator(store);
    agg.add(1, "6", 1);
    const flushing = agg.flush();
    agg.add(1, "6", 4); // lands in the next batch, not the in-flight one
    await flushing;
    expect(agg.pending().get(1)).toEqual({ "6": 4 });
  });
});
