import { describe, expect, it, vi } from "vitest";
import { Worker } from "../src/worker.js";
import type { Store } from "../src/store.js";
import type { CDN } from "../src/cdn.js";
import type { Config } from "../src/config.js";
import type { Delivery } from "../src/model.js";
import type { Sender } from "../src/apns.js";

function fixture() {
  const store = {
    lease: vi.fn(async () => "lease"), release: vi.fn(async () => {}),
    fanoutPage: vi.fn(async () => false), pending: vi.fn(async () => [] as Delivery[]),
    stillSubscribed: vi.fn(async () => true), complete: vi.fn(async () => {}),
    removeToken: vi.fn(async () => {}), retry: vi.fn(async () => {}), observe: vi.fn(async () => {}),
  };
  const sender = { send: vi.fn<Sender["send"]>(async () => ({ status: 200 })) };
  const worker = new Worker({ DRY_RUN: "false" } as Config, { match: vi.fn(async () => null) } as unknown as CDN,
    store as unknown as Store, sender);
  const delivery: Delivery = { id: "id", version: "v1", installationId: "installation", token: "a".repeat(64), kind: "alert", fixtureId: 1,
    payload: {}, priority: 10, collapseId: "id", expiresAt: Date.now() + 120_000, nextAttempt: 0, attempts: 0 };
  return { store, sender, worker, delivery };
}
describe("durable delivery processing", () => {
  it("never replays stale queued polling tasks", async () => {
    const { store, worker } = fixture();
    expect(await worker.tick([], Date.now() - 70_000)).toEqual({ skipped: "old-task" });
    expect(store.lease).not.toHaveBeenCalled();
  });
  it("does not run overlapping poll loops", async () => {
    const { store, worker } = fixture(); store.lease.mockResolvedValueOnce(null as unknown as string);
    expect(await worker.tick([], Date.now())).toEqual({ skipped: "overlap" });
  });
  it("acknowledges only successful deliveries", async () => {
    const { store, worker, sender, delivery } = fixture(); store.pending.mockResolvedValueOnce([delivery]);
    expect(await worker.tick([], Date.now())).toEqual({ sent: 1, dryRun: false });
    expect(sender.send).toHaveBeenCalledWith(delivery);
    expect(store.complete).toHaveBeenCalledWith(delivery, "done");
    expect(store.release).toHaveBeenCalledWith("lease");
  });
  it("retains transient APNs failures for later retries", async () => {
    const { store, worker, sender, delivery } = fixture(); store.pending.mockResolvedValueOnce([delivery]);
    sender.send.mockResolvedValueOnce({ status: 503, retryAfter: 30 });
    await worker.tick([], Date.now());
    expect(store.retry).toHaveBeenCalledWith(delivery, 30);
    expect(store.complete).not.toHaveBeenCalled();
  });
  it("removes only the invalid token and retires its pending delivery", async () => {
    const { store, worker, sender, delivery } = fixture(); store.pending.mockResolvedValueOnce([delivery]);
    sender.send.mockResolvedValueOnce({ status: 410, reason: "Unregistered" });
    await worker.tick([], Date.now());
    expect(store.removeToken).toHaveBeenCalledWith(delivery);
    expect(store.complete).toHaveBeenCalledWith(delivery, "done", "invalid-token");
  });
  it("discards expired and unsubscribed notifications without contacting Apple", async () => {
    const { store, worker, sender, delivery } = fixture();
    store.pending.mockResolvedValueOnce([{ ...delivery, expiresAt: 1 }, delivery]);
    store.stillSubscribed.mockResolvedValueOnce(false);
    await worker.tick([], Date.now());
    expect(sender.send).not.toHaveBeenCalled();
    expect(store.complete).toHaveBeenCalledTimes(2);
  });
  it("releases the lease on persistence failure so work can resume", async () => {
    const { store, worker } = fixture(); store.pending.mockRejectedValueOnce(new Error("database unavailable"));
    await expect(worker.tick([], Date.now())).rejects.toThrow("database unavailable");
    expect(store.release).toHaveBeenCalledWith("lease");
  });
});
