import { describe, expect, it, vi } from "vitest";
import {
  isLive, isRecentlyFinished, isRegressiveSnapshot, isStartingSoon, partitionFixtures, Poller, toScheduleRow, utcPollRange,
} from "../src/poller.js";
import { CACHE_CONTROL_LONG } from "../src/r2.js";
import type { MatchState } from "../src/types.js";

function state(
  fixtureId: number,
  kickoffISO: string,
  status: MatchState["status"] = "SCHEDULED",
  extra: Partial<MatchState> = {},
): MatchState {
  return {
    fixtureId, leagueId: 1, season: 2026, kickoffISO, status,
    rawStatus: status === "LIVE" ? "1H" : status === "FINISHED" ? "FT" : "NS",
    minute: null, extra: null, period: "PRE", running: status === "LIVE",
    home: { id: 1, name: "A", goals: 0, yellowCards: 0, redCards: 0, yellowCardEvents: [], redCardEvents: [], goalEvents: [] },
    away: { id: 2, name: "B", goals: 0, yellowCards: 0, redCards: 0, yellowCardEvents: [], redCardEvents: [], goalEvents: [] },
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

  it("toScheduleRow drops all live fields, keeps schedule data", () => {
    const live = state(7, "2026-06-14T20:00:00Z", "LIVE", {
      round: "Group A - 1", minute: 86, extra: 2, period: "SECOND", running: true,
      secondHalfStartISO: "2026-06-14T21:00:00Z",
      lastGoal: { teamId: 1, player: "X", minute: 20, extra: null },
      home: { id: 1, name: "A", goals: 2, yellowCards: 1, redCards: 0, yellowCardEvents: [], redCardEvents: [], goalEvents: [{ player: "X", minute: 20, extra: null }] },
    });
    const row = toScheduleRow(live);
    expect(row).toMatchObject({
      fixtureId: 7, round: "Group A - 1", kickoffISO: "2026-06-14T20:00:00Z",
      status: "SCHEDULED", rawStatus: "NS", minute: null, extra: null, period: "PRE", running: false,
      secondHalfStartISO: null,
    });
    expect(row.home).toMatchObject({ id: 1, name: "A", goals: 0, yellowCards: 0, goalEvents: [] });
    expect(row.lastGoal).toBeUndefined();
  });
});

describe("Poller", () => {
  it("publishes per-match state for a live fixture (no FCM, no purge)", async () => {
    const today = new Date().toISOString().slice(0, 10);
    const match = state(1, `${today}T01:00:00Z`, "LIVE");
    const provider = { fixturesForRange: vi.fn().mockResolvedValue([match]) };
    const stateStore = {
      load: vi.fn().mockResolvedValue({ state: null, etag: null }),
      save: vi.fn().mockResolvedValue(undefined),
    };
    const r2 = { putJsonIfChanged: vi.fn().mockResolvedValue(undefined) };
    const poller = new Poller(provider as never, stateStore as never, r2 as never);

    const result = await poller.fetchOnce();

    expect(result).toEqual({ live: 1 });
    // Fixture date files are schedule/bootstrap data; live state is in matches/*.json.
    expect(r2.putJsonIfChanged).toHaveBeenCalledWith(
      `fixtures-${match.kickoffISO.slice(0, 10)}.json`, expect.anything(), CACHE_CONTROL_LONG,
    );
    expect(stateStore.save).toHaveBeenCalledWith(match, null);
    // No purge path of any kind.
    expect((r2 as Record<string, unknown>).purge).toBeUndefined();
  });

  it("writes schedule-only data into fixtures-{date}.json for a live match", async () => {
    const today = new Date().toISOString().slice(0, 10);
    const live = state(1, `${today}T01:00:00Z`, "LIVE", {
      minute: 86, period: "SECOND", running: true,
      home: { id: 1, name: "A", goals: 2, yellowCards: 0, redCards: 0, yellowCardEvents: [], redCardEvents: [], goalEvents: [{ player: "X", minute: 20, extra: null }] },
    });
    const provider = { fixturesForRange: vi.fn().mockResolvedValue([live]) };
    const stateStore = {
      load: vi.fn().mockResolvedValue({ state: null, etag: null }),
      save: vi.fn().mockResolvedValue(undefined),
    };
    const r2 = { putJsonIfChanged: vi.fn().mockResolvedValue(undefined) };
    const poller = new Poller(provider as never, stateStore as never, r2 as never);

    await poller.fetchOnce();

    const call = r2.putJsonIfChanged.mock.calls.find(([key]) => key === `fixtures-${today}.json`);
    expect(call).toBeDefined();
    const row = (call![1] as { matches: MatchState[] }).matches[0];
    expect(row.status).toBe("SCHEDULED");
    expect(row.minute).toBeNull();
    expect(row.running).toBe(false);
    expect(row.home.goals).toBe(0);
    expect(row.home.goalEvents).toEqual([]);
    // The live per-match file still gets the REAL state.
    expect(stateStore.save).toHaveBeenCalledWith(live, null);
  });

  it("writes the long schedule TTL for a date with no eligible match", async () => {
    // A scheduled-only fixture far in the future on a non-today date.
    const future = state(1, "2027-01-02T20:00:00Z", "SCHEDULED");
    const provider = { fixturesForRange: vi.fn().mockResolvedValue([future]) };
    const stateStore = { load: vi.fn(), save: vi.fn() };
    const r2 = { putJsonIfChanged: vi.fn().mockResolvedValue(undefined) };
    const poller = new Poller(provider as never, stateStore as never, r2 as never);

    await poller.fetchOnce();

    expect(r2.putJsonIfChanged).toHaveBeenCalledWith(
      "fixtures-2027-01-02.json", expect.anything(), CACHE_CONTROL_LONG,
    );
  });

  it("writes today's fixtures file with the long TTL when no match is eligible", async () => {
    const provider = { fixturesForRange: vi.fn().mockResolvedValue([]) };
    const stateStore = { load: vi.fn(), save: vi.fn() };
    const r2 = { putJsonIfChanged: vi.fn().mockResolvedValue(undefined) };
    const poller = new Poller(provider as never, stateStore as never, r2 as never);

    await poller.fetchOnce();

    const today = new Date().toISOString().slice(0, 10);
    expect(r2.putJsonIfChanged).toHaveBeenCalledWith(
      `fixtures-${today}.json`, expect.anything(), CACHE_CONTROL_LONG,
    );
  });

  it("saves when a live match flips to FINISHED (no events emitted)", async () => {
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
    const r2 = { putJsonIfChanged: vi.fn().mockResolvedValue(undefined) };
    const poller = new Poller(provider as never, stateStore as never, r2 as never);

    const result = await poller.fetchOnce();

    expect(result).toEqual({ live: 0 });
    expect(stateStore.save).toHaveBeenCalledTimes(1);
    expect(stateStore.save).toHaveBeenCalledWith(finished, "e1");
  });

  it("skips SCHEDULED and long-finished fixtures: no R2 read, no save", async () => {
    const scheduled = state(1, "2026-06-14T20:00:00Z", "SCHEDULED");
    const oldFinished = state(2, "2020-01-01T00:00:00Z", "FINISHED", {
      secondHalfStartISO: "2020-01-01T01:00:00Z",
    });
    const provider = { fixturesForRange: vi.fn().mockResolvedValue([scheduled, oldFinished]) };
    const stateStore = { load: vi.fn(), save: vi.fn() };
    const r2 = { putJsonIfChanged: vi.fn().mockResolvedValue(undefined) };
    const poller = new Poller(provider as never, stateStore as never, r2 as never);

    await poller.fetchOnce();

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
    const r2 = { putJsonIfChanged: vi.fn().mockResolvedValue(undefined) };
    const poller = new Poller(provider as never, stateStore as never, r2 as never);

    await poller.fetchOnce();

    expect(stateStore.load).toHaveBeenCalledWith(1);
    expect(stateStore.save).toHaveBeenCalledWith(scheduled, null);
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
    const r2 = { putJsonIfChanged: vi.fn().mockResolvedValue(undefined) };
    const poller = new Poller(provider as never, stateStore as never, r2 as never);

    await poller.fetchOnce();

    expect(stateStore.save).not.toHaveBeenCalled();
  });

  it("still publishes when a per-side goal count drops (real VAR disallow)", async () => {
    const now = new Date();
    const prev = state(1, now.toISOString(), "LIVE", {
      minute: 74, period: "SECOND", running: true,
      home: { id: 1, name: "A", goals: 1, yellowCards: 0, redCards: 0, yellowCardEvents: [], redCardEvents: [], goalEvents: [{ player: "X", minute: 40, extra: null }] },
    });
    const disallowed = state(1, now.toISOString(), "LIVE", {
      minute: 75, period: "SECOND", running: true,
      home: { id: 1, name: "A", goals: 0, yellowCards: 0, redCards: 0, yellowCardEvents: [], redCardEvents: [], goalEvents: [] },
    });
    const provider = { fixturesForRange: vi.fn().mockResolvedValue([disallowed]) };
    const stateStore = {
      load: vi.fn().mockResolvedValue({ state: prev, etag: "e1" }),
      save: vi.fn().mockResolvedValue(undefined),
    };
    const r2 = { putJsonIfChanged: vi.fn().mockResolvedValue(undefined) };
    const poller = new Poller(provider as never, stateStore as never, r2 as never);

    await poller.fetchOnce();

    // Aggregate-first: the drop publishes instantly (no hold).
    expect(stateStore.save).toHaveBeenCalledWith(disallowed, "e1");
  });

  it("ignores a stale scheduled snapshot after a match is live", async () => {
    const previous = state(1, new Date(Date.now() - 5 * 60_000).toISOString(), "LIVE");
    const stale = state(1, previous.kickoffISO, "SCHEDULED");
    const provider = { fixturesForRange: vi.fn().mockResolvedValue([stale]) };
    const stateStore = {
      load: vi.fn().mockResolvedValue({ state: previous, etag: "e1" }),
      save: vi.fn(),
    };
    const r2 = { putJsonIfChanged: vi.fn().mockResolvedValue(undefined) };
    const poller = new Poller(provider as never, stateStore as never, r2 as never);

    await poller.fetchOnce();

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
