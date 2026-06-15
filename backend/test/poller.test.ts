import { describe, expect, it, vi } from "vitest";
import {
  isLive, isRecentlyFinished, isRegressiveSnapshot, isStartingSoon, partitionFixtures, Poller, utcPollRange,
} from "../src/poller.js";
import type { MatchState } from "../src/types.js";

function state(
  fixtureId: number,
  kickoffISO: string,
  status: MatchState["status"] = "SCHEDULED",
  extra: Partial<MatchState> = {},
): MatchState {
  return {
    fixtureId, leagueId: 1, season: 2026, kickoffISO, status,
    rawStatus: status === "LIVE" ? "1H" : status === "FINISHED" ? "FT" : "NS", minute: null,
    home: { id: 1, name: "A", goals: 0, yellowCards: 0, redCards: 0, yellowCardEvents: [], redCardEvents: [] },
    away: { id: 2, name: "B", goals: 0, yellowCards: 0, redCards: 0, yellowCardEvents: [], redCardEvents: [] },
    ...extra,
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
    const r2 = { putJsonIfChanged: vi.fn().mockResolvedValue(undefined) };
    const poller = new Poller(provider as never, stateStore as never, fcm as never, r2 as never);

    const result = await poller.fetchOnce();

    expect(result).toEqual({ events: 1, live: 1 });
    expect(r2.putJsonIfChanged).toHaveBeenCalledWith("fixtures-2026-06-14.json", expect.anything(), 10);
    expect(calls).toEqual(["fcm", "save"]);
  });

  it("fires FULL_TIME and saves when a live match flips to FINISHED", async () => {
    const prev = state(1, "2026-06-14T01:00:00Z", "LIVE");
    const now = new Date();
    const finished = state(1, now.toISOString(), "FINISHED", {
      secondHalfStartISO: new Date(now.getTime() - 60 * 60 * 1000).toISOString(), // 1h ago
    });
    const provider = { fixturesForRange: vi.fn().mockResolvedValue([finished]) };
    const stateStore = {
      load: vi.fn().mockResolvedValue({ state: prev, etag: "e1" }),
      save: vi.fn().mockResolvedValue(undefined),
    };
    const fcm = { publishEvent: vi.fn().mockResolvedValue(undefined) };
    const r2 = { putJsonIfChanged: vi.fn().mockResolvedValue(undefined) };
    const poller = new Poller(provider as never, stateStore as never, fcm as never, r2 as never);

    const result = await poller.fetchOnce();

    expect(result.events).toBe(1);
    expect(fcm.publishEvent).toHaveBeenCalledWith(expect.objectContaining({ type: "FULL_TIME" }));
    expect(stateStore.save).toHaveBeenCalledTimes(1);
  });

  it("skips SCHEDULED and long-finished fixtures: no R2 read, no save", async () => {
    const scheduled = state(1, "2026-06-14T20:00:00Z", "SCHEDULED");
    const oldFinished = state(2, "2020-01-01T00:00:00Z", "FINISHED", {
      secondHalfStartISO: "2020-01-01T01:00:00Z",
    });
    const provider = { fixturesForRange: vi.fn().mockResolvedValue([scheduled, oldFinished]) };
    const stateStore = { load: vi.fn(), save: vi.fn() };
    const fcm = { publishEvent: vi.fn() };
    const r2 = { putJsonIfChanged: vi.fn().mockResolvedValue(undefined) };
    const poller = new Poller(provider as never, stateStore as never, fcm as never, r2 as never);

    const result = await poller.fetchOnce();

    expect(result.events).toBe(0);
    expect(stateStore.load).not.toHaveBeenCalled();
    expect(stateStore.save).not.toHaveBeenCalled();
  });

  it("publishes individual state for a fixture starting within one minute", async () => {
    const scheduled = state(1, new Date(Date.now() + 45_000).toISOString(), "SCHEDULED");
    const provider = { fixturesForRange: vi.fn().mockResolvedValue([scheduled]) };
    const stateStore = {
      load: vi.fn().mockResolvedValue({ state: null, etag: null }),
      save: vi.fn().mockResolvedValue(undefined),
    };
    const fcm = { publishEvent: vi.fn() };
    const r2 = { putJsonIfChanged: vi.fn().mockResolvedValue(undefined) };
    const poller = new Poller(provider as never, stateStore as never, fcm as never, r2 as never);

    await poller.fetchOnce();

    expect(stateStore.load).toHaveBeenCalledWith(1);
    expect(stateStore.save).toHaveBeenCalledWith(scheduled, null);
    expect(fcm.publishEvent).not.toHaveBeenCalled();
  });

  it("skips the save when the loaded state is unchanged", async () => {
    const now = new Date();
    const finished = state(1, now.toISOString(), "FINISHED", {
      secondHalfStartISO: new Date(now.getTime() - 60 * 60 * 1000).toISOString(),
    });
    const provider = { fixturesForRange: vi.fn().mockResolvedValue([finished]) };
    const stateStore = {
      load: vi.fn().mockResolvedValue({ state: finished, etag: "e1" }),
      save: vi.fn(),
    };
    const fcm = { publishEvent: vi.fn() };
    const r2 = { putJsonIfChanged: vi.fn().mockResolvedValue(undefined) };
    const poller = new Poller(provider as never, stateStore as never, fcm as never, r2 as never);

    const result = await poller.fetchOnce();

    expect(result.events).toBe(0);
    expect(stateStore.save).not.toHaveBeenCalled();
  });

  it("ignores a stale scheduled snapshot after a match is live", async () => {
    const previous = state(1, new Date(Date.now() - 5 * 60_000).toISOString(), "LIVE");
    const stale = state(1, previous.kickoffISO, "SCHEDULED");
    const provider = { fixturesForRange: vi.fn().mockResolvedValue([stale]) };
    const stateStore = {
      load: vi.fn().mockResolvedValue({ state: previous, etag: "e1" }),
      save: vi.fn(),
    };
    const fcm = { publishEvent: vi.fn() };
    const r2 = { putJsonIfChanged: vi.fn().mockResolvedValue(undefined) };
    const poller = new Poller(provider as never, stateStore as never, fcm as never, r2 as never);

    const result = await poller.fetchOnce();

    expect(result.events).toBe(0);
    expect(fcm.publishEvent).not.toHaveBeenCalled();
    expect(stateStore.save).not.toHaveBeenCalled();
  });
});

describe("isRecentlyFinished", () => {
  const now = Date.parse("2026-06-14T20:00:00Z");

  it("is false for non-finished", () => {
    expect(isRecentlyFinished(state(1, "2026-06-14T18:00:00Z", "LIVE"), now)).toBe(false);
  });

  it("is true within 2.5h of 2nd-half start", () => {
    const m = state(1, "2026-06-14T18:00:00Z", "FINISHED", { secondHalfStartISO: "2026-06-14T18:45:00Z" });
    expect(isRecentlyFinished(m, now)).toBe(true);
  });

  it("is false well past 2.5h of 2nd-half start", () => {
    const m = state(1, "2026-06-14T12:00:00Z", "FINISHED", { secondHalfStartISO: "2026-06-14T12:45:00Z" });
    expect(isRecentlyFinished(m, now)).toBe(false);
  });

  it("falls back to kickoff + 4h when 2nd-half start is absent", () => {
    const within = state(1, "2026-06-14T17:00:00Z", "FINISHED", { secondHalfStartISO: null });
    const past = state(2, "2026-06-14T10:00:00Z", "FINISHED", { secondHalfStartISO: null });
    expect(isRecentlyFinished(within, now)).toBe(true);
    expect(isRecentlyFinished(past, now)).toBe(false);
  });
});

describe("isStartingSoon", () => {
  const now = Date.parse("2026-06-14T20:00:00Z");

  it("includes scheduled fixtures starting within one minute", () => {
    expect(isStartingSoon(state(1, "2026-06-14T20:00:45Z"), now)).toBe(true);
  });

  it("keeps briefly overdue scheduled fixtures until the provider marks them live", () => {
    expect(isStartingSoon(state(1, "2026-06-14T19:55:00Z"), now)).toBe(true);
  });

  it("excludes distant, stale, live, and finished fixtures", () => {
    expect(isStartingSoon(state(1, "2026-06-14T20:02:00Z"), now)).toBe(false);
    expect(isStartingSoon(state(2, "2026-06-14T19:40:00Z"), now)).toBe(false);
    expect(isStartingSoon(state(3, "2026-06-14T20:00:45Z", "LIVE"), now)).toBe(false);
    expect(isStartingSoon(state(4, "2026-06-14T20:00:45Z", "FINISHED"), now)).toBe(false);
  });
});

describe("isRegressiveSnapshot", () => {
  it("rejects live or finished matches reverting to scheduled", () => {
    expect(isRegressiveSnapshot(
      state(1, "2026-06-14T20:00:00Z", "LIVE"),
      state(1, "2026-06-14T20:00:00Z", "SCHEDULED"),
    )).toBe(true);
    expect(isRegressiveSnapshot(
      state(1, "2026-06-14T20:00:00Z", "FINISHED"),
      state(1, "2026-06-14T20:00:00Z", "LIVE"),
    )).toBe(true);
  });

  it("allows normal scheduled, live, half-time, and finished progression", () => {
    expect(isRegressiveSnapshot(
      state(1, "2026-06-14T20:00:00Z", "SCHEDULED"),
      state(1, "2026-06-14T20:00:00Z", "LIVE"),
    )).toBe(false);
    expect(isRegressiveSnapshot(
      state(1, "2026-06-14T20:00:00Z", "HALF_TIME"),
      state(1, "2026-06-14T20:00:00Z", "LIVE"),
    )).toBe(false);
    expect(isRegressiveSnapshot(
      state(1, "2026-06-14T20:00:00Z", "LIVE"),
      state(1, "2026-06-14T20:00:00Z", "FINISHED"),
    )).toBe(false);
  });
});
