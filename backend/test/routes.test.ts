import { once } from "node:events";
import type { AddressInfo } from "node:net";
import { describe, expect, it } from "vitest";
import { buildApp, type Deps } from "../src/routes.js";

describe("HTTP surface", () => {
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
