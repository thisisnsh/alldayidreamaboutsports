import { GetObjectCommand, PutObjectCommand } from "@aws-sdk/client-s3";
import { describe, expect, it, vi } from "vitest";
import { R2ConflictError, R2MatchStateStore } from "../src/r2.js";
import type { MatchState } from "../src/types.js";

const match: MatchState = {
  fixtureId: 7, leagueId: 1, season: 2026, kickoffISO: "2026-06-14T12:00:00Z",
  status: "LIVE", rawStatus: "1H", minute: 1,
  home: { id: 1, name: "A", goals: 0, yellowCards: 0, redCards: 0 },
  away: { id: 2, name: "B", goals: 0, yellowCards: 0, redCards: 0 },
};

describe("R2MatchStateStore", () => {
  it("loads an etag and uses it for a conditional update", async () => {
    const send = vi.fn(async (command: unknown) => {
      if (command instanceof GetObjectCommand) {
        return { ETag: "\"v1\"", Body: { transformToString: async () => JSON.stringify(match) } };
      }
      return {};
    });
    const store = new R2MatchStateStore({ send } as never, "private-state");

    const loaded = await store.load(7);
    await store.save(match, loaded.etag);

    expect(loaded).toEqual({ state: match, etag: "\"v1\"" });
    const put = send.mock.calls[1]![0] as PutObjectCommand;
    expect(put.input).toMatchObject({ Bucket: "private-state", Key: "matches/7.json", IfMatch: "\"v1\"" });
  });

  it("surfaces conditional write conflicts", async () => {
    const send = vi.fn().mockRejectedValue(Object.assign(new Error("conflict"), { name: "PreconditionFailed" }));
    const store = new R2MatchStateStore({ send } as never, "private-state");
    await expect(store.save(match, null)).rejects.toBeInstanceOf(R2ConflictError);
  });
});
