import { describe, expect, it } from "vitest";
import type { Firestore } from "firebase-admin/firestore";
import { Store } from "../../src/push/store.js";
import type { Delivery, Registration } from "../../src/push/model.js";

// Minimal transactional double: commit is atomic; no emulator or external services.
class DB {
  rows = new Map<string, Record<string, any>>();
  failCommit = false;
  collection(path: string) { return { doc: (id: string) => this.ref(`${path}/${id}`) }; }
  ref(path: string) { return { path, get: async () => this.snapshot(this.rows, path) }; }
  snapshot(rows: Map<string, Record<string, any>>, path: string) {
    const data = rows.get(path);
    return { exists: !!data, data: () => data, get: (field: string) => field.split(".").reduce((v, key) => v?.[key], data as any) };
  }
  async runTransaction<T>(body: (tx: any) => Promise<T>): Promise<T> {
    const next = new Map(this.rows);
    const tx = {
      get: async (ref: { path: string }) => this.snapshot(next, ref.path),
      set: (ref: { path: string }, data: any) => next.set(ref.path, data),
      create: (ref: { path: string }, data: any) => { if (next.has(ref.path)) throw new Error("exists"); next.set(ref.path, data); },
      update: (ref: { path: string }, data: any) => next.set(ref.path, { ...next.get(ref.path), ...data }),
      delete: (ref: { path: string }) => next.delete(ref.path),
    };
    const result = await body(tx);
    if (this.failCommit) throw new Error("commit failed");
    this.rows = next; return result;
  }
}
const registration: Registration = { deviceToken: "a".repeat(64), teamIds: [1], eventTypes: ["GOAL"], alertsEnabled: true, activities: [] };
const baseDelivery = { id: "delivery", version: "v1", installationId: "installation", token: "a".repeat(64), kind: "alert" } as Delivery;
function setup() { const db = new DB(); return { db, store: new Store(db as unknown as Firestore) }; }

describe("persistent state safeguards", () => {
  it("keeps the subscription time on repeated sync and pin changes", async () => {
    const { db, store } = setup();
    await store.register("installation", registration, 10_000);
    await store.register("installation", registration, 20_000);
    expect(db.rows.get("installations/installation")!.updatedAt).toBe(10_000);
    await store.register("installation", { ...registration, activities: [{ fixtureId: 123, id: "activity", token: "b".repeat(64) }] }, 30_000);
    expect(db.rows.get("installations/installation")!.updatedAt).toBe(30_000);
    expect(db.rows.get("installations/installation")!.alertsSince).toBe(10_000);
  });
  it("deletes the subscription when all delivery is disabled", async () => {
    const { db, store } = setup();
    await store.register("installation", registration, 10_000);
    await store.register("installation", { ...registration, alertsEnabled: false }, 20_000);
    expect(db.rows.has("installations/installation")).toBe(false);
  });
  it("doesn't clear a rotated device token after an old token is rejected", async () => {
    const { db, store } = setup();
    await store.register("installation", { ...registration, deviceToken: "c".repeat(64) }, 10_000);
    await store.removeToken(baseDelivery);
    expect(db.rows.get("installations/installation")!.deviceToken).toBe("c".repeat(64));
  });
  it("acknowledges only the version actually sent", async () => {
    const { db, store } = setup();
    db.rows.set("deliveries/delivery", { version: "v2", status: "pending" });
    await store.complete(baseDelivery, "done");
    expect(db.rows.get("deliveries/delivery")!.status).toBe("pending");
    await store.complete({ ...baseDelivery, version: "v2" }, "done");
    expect(db.rows.get("deliveries/delivery")!.status).toBe("done");
  });
  it("leases exclusive polling and cannot release a successor's lease", async () => {
    const { db, store } = setup();
    const owner = await store.lease(1000);
    expect(await store.lease(2000)).toBeNull();
    const next = await store.lease(112_000);
    await store.release(owner!);
    expect(db.rows.get("control/tick")!.owner).toBe(next);
  });
  it("limits writes per verified App Check token", async () => {
    const { store } = setup();
    for (let i = 0; i < 30; i++) await store.registrationBudget("proof", 1000);
    await expect(store.registrationBudget("proof", 1000)).rejects.toThrow("registration-rate-limit");
    await expect(store.registrationBudget("proof", 61_000)).resolves.toBeUndefined();
  });
});
