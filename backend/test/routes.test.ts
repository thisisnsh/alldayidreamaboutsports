import { once } from "node:events";
import type { AddressInfo } from "node:net";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { buildApp, type Deps } from "../src/routes.js";

describe("HTTP surface", () => {
  beforeEach(() => {
    vi.stubEnv("SERVICE_URL", "https://backend.example.invalid");
    vi.stubEnv("GCP_PROJECT_ID", "test-project");
  });
  afterEach(() => vi.unstubAllEnvs());
  it.each([
    ["GET", "/internal/healthz"],
    ["POST", "/internal/dispatch"],
    ["POST", "/internal/fetch"],
    ["POST", "/internal/sync-schedule"],
    ["POST", "/internal/sync-catalog"],
    ["POST", "/internal/test-event"],
    ["POST", "/internal/cache-health"],
  ])("requires service authentication for %s %s", async (method, path) => {
    const server = buildApp({} as Deps).listen(0, "127.0.0.1");
    await once(server, "listening");
    try {
      const response = await fetch(`http://127.0.0.1:${(server.address() as AddressInfo).port}${path}`, { method });
      expect(response.status).toBe(401);
      await response.arrayBuffer();
    } finally {
      server.closeAllConnections();
      await new Promise<void>((resolve) => server.close(() => resolve()));
    }
  });

  it("does not expose public health", async () => {
    const server = buildApp({} as Deps).listen(0, "127.0.0.1");
    await once(server, "listening");
    try {
      const response = await fetch(`http://127.0.0.1:${(server.address() as AddressInfo).port}/healthz/`);
      expect(response.status).toBe(404);
      await response.arrayBuffer();
    } finally {
      server.closeAllConnections();
      await new Promise<void>((resolve) => server.close(() => resolve()));
    }
  });

  it("does not expose the removed shared celebration endpoint", async () => {
    const server = buildApp({} as Deps).listen(0, "127.0.0.1");
    await once(server, "listening");
    try {
      const url = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
      const response = await fetch(`${url}/celebrate`, {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ fixtureId: 1, teamId: "2", taps: 200 }),
      });
      expect(response.status).toBe(404);
      await response.arrayBuffer();
    } finally {
      server.closeAllConnections();
      await new Promise<void>((resolve) => server.close(() => resolve()));
    }
  });
});
