import { describe, expect, it, vi } from "vitest";
import { isLive, partitionFixtures, Poller, utcPollRange } from "../src/poller.js";
import type { MatchState } from "../src/types.js";

function state(fixtureId: number, kickoffISO: string, status: MatchState["status"] = "SCHEDULED"): MatchState {
  return {
    fixtureId, leagueId: 1, season: 2026, kickoffISO, status,
    rawStatus: status === "LIVE" ? "1H" : "NS", minute: null,
    home: { id: 1, name: "A", goals: 0, yellowCards: 0, redCards: 0 },
    away: { id: 2, name: "B", goals: 0, yellowCards: 0, redCards: 0 },
  };
}

describe("polling helpers", () => {
  it("uses yesterday through tomorrow in UTC", () => {
    expect(utcPollRange(new Date("2026-06-14T00:01:00Z"))).toEqual({
      from: "2026-06-13", to: "2026-06-15",
    });
  });

  it("partitions fixtures by UTC kickoff date and derives live status", () => {
    const a = state(1, "2026-06-13T23:30:00Z", "LIVE");
    const b = state(2, "2026-06-14T01:00:00Z", "HALF_TIME");
    const partitions = partitionFixtures([a, b]);
    expect([...partitions.keys()]).toEqual(["2026-06-13", "2026-06-14"]);
    expect(isLive(a)).toBe(true);
    expect(isLive(b)).toBe(true);
  });
});

describe("Poller", () => {
  it("publishes dated fixtures and sends detected events before saving state", async () => {
    const match = state(1, "2026-06-14T01:00:00Z", "LIVE");
    const calls: string[] = [];
    const provider = { fixturesForRange: vi.fn().mockResolvedValue([match]) };
    const stateStore = {
      load: vi.fn().mockResolvedValue({ state: null, etag: null }),
      save: vi.fn(async () => { calls.push("save"); }),
    };
    const fcm = { publishEvent: vi.fn(async () => { calls.push("fcm"); }) };
    const r2 = { putJson: vi.fn().mockResolvedValue(undefined) };
    const poller = new Poller(provider as never, stateStore as never, fcm as never, r2 as never);

    const result = await poller.tick(1, 0);

    expect(result).toEqual({ events: 1, live: 1 });
    expect(r2.putJson).toHaveBeenCalledWith("fixtures-2026-06-14.json", expect.anything(), 10);
    expect(calls).toEqual(["fcm", "save"]);
  });
});
