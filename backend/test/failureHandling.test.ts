import { once } from "node:events";
import type { AddressInfo } from "node:net";
import { OAuth2Client } from "google-auth-library";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { buildApp, type Deps } from "../src/routes.js";
import { validateEnvironment } from "../src/env.js";

beforeEach(() => {
  for (const [key, value] of Object.entries({
    SERVICE_URL: "https://backend.example.invalid", GCP_PROJECT_ID: "test",
    SCORES_DOMAIN: "https://scores.example.invalid", API_FOOTBALL_KEY: "test",
    R2_ENDPOINT: "https://storage.example.invalid", R2_ACCESS_KEY_ID: "test",
    R2_SECRET_ACCESS_KEY: "test", R2_BUCKET_SCORES: "test-staging-scores",
  })) vi.stubEnv(key, value);
  vi.spyOn(OAuth2Client.prototype, "verifyIdToken").mockResolvedValue({
    getPayload: () => ({ email: "sports-scheduler@test.iam.gserviceaccount.com", email_verified: true }),
  } as never);
});
afterEach(() => { vi.restoreAllMocks(); vi.unstubAllEnvs(); });

describe("operational failure handling", () => {
  it.each(["test-event", "cache-health"])("returns a safe 500 and keeps serving after %s fails", async (route) => {
    const fail = async () => { throw new Error("sensitive upstream details"); };
    const server = buildApp({ r2: { putJson: fail }, window: { isOpen: fail } } as unknown as Deps)
      .listen(0, "127.0.0.1");
    await once(server, "listening");
    const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
    const headers = { Authorization: "Bearer a.b.c" };
    try {
      const result = await fetch(`${base}/internal/${route}`, { method: "POST", headers });
      expect(result.status).toBe(500);
      expect(await result.json()).toEqual({ error: "internal server error" });
      const health = await fetch(`${base}/internal/healthz`, { headers });
      expect(health.status).toBe(200);
      await health.arrayBuffer();
    } finally {
      server.closeAllConnections();
      await new Promise<void>((resolve) => server.close(() => resolve()));
    }
  });

  it.each(["", "http://scores.example.invalid", "https://scores.example.invalid/path"])(
    "rejects missing or invalid health-probe configuration at startup: %s", (value) => {
      vi.stubEnv("SCORES_DOMAIN", value);
      expect(() => validateEnvironment()).toThrow();
    },
  );
  it("accepts a complete HTTPS configuration", () => expect(() => validateEnvironment()).not.toThrow());
});
