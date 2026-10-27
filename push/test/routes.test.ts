import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { Server } from "node:http";
import { createApp, type Dependencies } from "../src/routes.js";
import type { Config } from "../src/config.js";
import { hash } from "../src/model.js";

let server: Server, origin: string, deps: Dependencies;
const config = { INVOKER_EMAIL: "invoker@example.com", FIREBASE_APP_IDS: "allowed", DRY_RUN: "true" } as Config;
beforeEach(async () => {
  deps = {
    store: { register: vi.fn(async () => {}), registrationBudget: vi.fn(async () => {}) },
    worker: { dispatch: vi.fn(async () => ({ enqueued: 0 })), tick: vi.fn(async () => ({ sent: 0, dryRun: true })) },
    verifyOidc: vi.fn(async token => ({ email: token, email_verified: true })),
    verifyAppCheck: vi.fn(async token => ({ appId: token })),
  };
  server = createApp(config, deps).listen(0, "127.0.0.1");
  await new Promise<void>(resolve => server.once("listening", resolve));
  origin = `http://127.0.0.1:${(server.address() as { port: number }).port}`;
});
afterEach(async () => { server.closeAllConnections(); await new Promise<void>(resolve => server.close(() => resolve())); });
const registration = { deviceToken: null, teamIds: [1], eventTypes: ["GOAL"], alertsEnabled: false, activities: [] };
const headers = { "Content-Type": "application/json", "Authorization": `Bearer ${"a".repeat(64)}`, "X-Firebase-AppCheck": "allowed" };
function register(extra: RequestInit = {}) {
  return fetch(`${origin}/v1/installation`, { method: "PUT", headers, body: JSON.stringify(registration), ...extra });
}
describe("public/internal isolation", () => {
  it("rejects unauthenticated internal dispatch without doing work", async () => {
    expect((await fetch(`${origin}/internal/dispatch`, { method: "POST" })).status).toBe(401);
    expect(deps.worker.dispatch).not.toHaveBeenCalled();
  });
  it("rejects a valid OIDC token for the wrong identity", async () => {
    expect((await fetch(`${origin}/internal/dispatch`, { method: "POST", headers: { Authorization: "Bearer stranger@example.com" } })).status).toBe(403);
    expect(deps.worker.dispatch).not.toHaveBeenCalled();
  });
  it("allows only the verified invoker", async () => {
    expect((await fetch(`${origin}/internal/dispatch`, { method: "POST", headers: { Authorization: "Bearer invoker@example.com" } })).status).toBe(200);
    expect(deps.worker.dispatch).toHaveBeenCalledOnce();
  });
  it("requires both attestation and a strong installation secret", async () => {
    expect((await register({ headers: { "Content-Type": "application/json" } })).status).toBe(401);
    expect((await register({ headers: { ...headers, Authorization: "Bearer weak" } })).status).toBe(401);
    expect(deps.store.register).not.toHaveBeenCalled();
  });
  it("rejects another Firebase app even with valid attestation", async () => {
    expect((await register({ headers: { ...headers, "X-Firebase-AppCheck": "other-app" } })).status).toBe(403);
  });
  it("stores only a hash of the bearer secret and reports dry-run honestly", async () => {
    const result = await register();
    expect(result.status).toBe(200);
    expect(await result.json()).toEqual({ registered: true, remoteDeliveryEnabled: false });
    expect(deps.store.register).toHaveBeenCalledWith(hash("a".repeat(64)), registration, expect.any(Number));
  });
  it("rejects malformed subscriptions before persistence", async () => {
    expect((await register({ body: JSON.stringify({ ...registration, teamIds: [-1] }) })).status).toBe(400);
    expect(deps.store.register).not.toHaveBeenCalled();
  });
  it("bounds request size", async () => {
    expect((await register({ body: JSON.stringify({ data: "x".repeat(40_000) }) })).status).toBe(413);
  });
  it("rate-limits authenticated writes", async () => {
    vi.mocked(deps.store.registrationBudget).mockRejectedValueOnce(new Error("registration-rate-limit"));
    expect((await register()).status).toBe(429);
    expect(deps.store.register).not.toHaveBeenCalled();
  });
});
