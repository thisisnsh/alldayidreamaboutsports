import { GetObjectCommand, PutObjectCommand } from "@aws-sdk/client-s3";
import { describe, expect, it, vi } from "vitest";
import {
  CACHE_CONTROL_LIVE, CACHE_CONTROL_LONG, R2, R2ConflictError, R2MatchStateStore,
} from "../src/r2.js";
import type { MatchState } from "../src/types.js";

const match: MatchState = {
  fixtureId: 7, leagueId: 1, season: 2026, kickoffISO: "2026-06-14T12:00:00Z",
  status: "LIVE", rawStatus: "1H", minute: 1, extra: null, period: "FIRST", running: true,
  home: { id: 1, name: "A", goals: 0, yellowCards: 0, redCards: 0, yellowCardEvents: [], redCardEvents: [], goalEvents: [] },
  away: { id: 2, name: "B", goals: 0, yellowCards: 0, redCards: 0, yellowCardEvents: [], redCardEvents: [], goalEvents: [] },
};

describe("R2MatchStateStore", () => {
  it("loads an etag and writes the 5s+SWR cache header on a conditional update", async () => {
    const send = vi.fn(async (command: unknown) => {
      if (command instanceof GetObjectCommand) {
        return { ETag: "\"v1\"", Body: { transformToString: async () => JSON.stringify(match) } };
      }
      return { ETag: "\"v2\"" };
    });
    const store = new R2MatchStateStore({ send } as never, "private-state");

    const loaded = await store.load(7);
    await store.save(match, loaded.etag);

    expect(loaded).toEqual({ state: match, etag: "\"v1\"" });
    const put = send.mock.calls[1]![0] as PutObjectCommand;
    expect(put.input).toMatchObject({
      Bucket: "private-state",
      Key: "matches/7.json",
      CacheControl: "public, max-age=5, stale-while-revalidate=25",
      IfMatch: "\"v1\"",
    });
    await expect(store.load(7)).resolves.toEqual({ state: match, etag: "\"v2\"" });
    expect(send).toHaveBeenCalledTimes(2);
  });

  it("caches loaded match state to avoid repeated R2 reads during polling", async () => {
    const send = vi.fn(async (command: unknown) => {
      if (command instanceof GetObjectCommand) {
        return { ETag: "\"v1\"", Body: { transformToString: async () => JSON.stringify(match) } };
      }
      return {};
    });
    const store = new R2MatchStateStore({ send } as never, "private-state");

    await expect(store.load(7)).resolves.toEqual({ state: match, etag: "\"v1\"" });
    await expect(store.load(7)).resolves.toEqual({ state: match, etag: "\"v1\"" });

    expect(send).toHaveBeenCalledTimes(1);
  });

  it("caches missing match state until the process saves it", async () => {
    const send = vi.fn(async (command: unknown) => {
      if (command instanceof GetObjectCommand) {
        throw Object.assign(new Error("missing"), { name: "NoSuchKey" });
      }
      return { ETag: "\"v1\"" };
    });
    const store = new R2MatchStateStore({ send } as never, "private-state");

    await expect(store.load(7)).resolves.toEqual({ state: null, etag: null });
    await expect(store.load(7)).resolves.toEqual({ state: null, etag: null });
    await store.save(match, null);
    await expect(store.load(7)).resolves.toEqual({ state: match, etag: "\"v1\"" });

    expect(send).toHaveBeenCalledTimes(2);
  });

  it("surfaces conditional write conflicts", async () => {
    const send = vi.fn().mockRejectedValue(Object.assign(new Error("conflict"), { name: "PreconditionFailed" }));
    const store = new R2MatchStateStore({ send } as never, "private-state");
    await expect(store.save(match, null)).rejects.toBeInstanceOf(R2ConflictError);
  });
});

describe("R2 cache-control invariant (§0: no write path omits it)", () => {
  it("the live header carries a short TTL + stale-while-revalidate", () => {
    expect(CACHE_CONTROL_LIVE).toBe("public, max-age=5, stale-while-revalidate=25");
  });

  it("the long header is the 12h schedule/catalog TTL", () => {
    expect(CACHE_CONTROL_LONG).toBe("public, max-age=43200");
  });

  it("putJson always sets Cache-Control, with the exact string the caller passes", async () => {
    for (const cc of [CACHE_CONTROL_LIVE, CACHE_CONTROL_LONG]) {
      const send = vi.fn().mockResolvedValue({});
      const r2 = new R2({ send } as never, "scores");
      await r2.putJson("celebrate/1.json", { totals: {} }, cc);
      const put = send.mock.calls[0]![0] as PutObjectCommand;
      expect(put.input.CacheControl).toBe(cc);
      expect(put.input.CacheControl).toBeTruthy();
    }
  });

  it("putJsonIfChanged also sets Cache-Control on the underlying write", async () => {
    const send = vi.fn().mockResolvedValue({});
    const r2 = new R2({ send } as never, "scores");
    await r2.putJsonIfChanged("fixtures-2026-06-14.json", { matches: [] }, CACHE_CONTROL_LONG);
    const put = send.mock.calls[0]![0] as PutObjectCommand;
    expect(put.input.CacheControl).toBe(CACHE_CONTROL_LONG);
  });
});
