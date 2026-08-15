import { describe, expect, it, vi } from "vitest";
import type { LeagueSeasons } from "../src/catalog.js";
import { utcPollRange } from "../src/poller.js";
import { CACHE_CONTROL_LONG } from "../src/r2.js";
import { ScheduleService } from "../src/schedule.js";
import type { MatchState } from "../src/types.js";

const TOP_FIVE = [39, 140, 135, 78, 61];

function seasons(): LeagueSeasons {
  return {
    resolve: async (ids: number[]) => ids.map((leagueId) => ({ leagueId, season: 2026 })),
  } as unknown as LeagueSeasons;
}

function state(fixtureId: number, kickoffISO: string, leagueId = 39): MatchState {
  return {
    fixtureId, leagueId, season: 2026, kickoffISO, status: "SCHEDULED", rawStatus: "NS",
    minute: null, extra: null, period: "PRE", running: false,
    home: { id: 1, name: "A", goals: 0, yellowCards: 0, redCards: 0, yellowCardEvents: [], redCardEvents: [], goalEvents: [] },
    away: { id: 2, name: "B", goals: 0, yellowCards: 0, redCards: 0, yellowCardEvents: [], redCardEvents: [], goalEvents: [] },
  };
}

describe("ScheduleService", () => {
  it("fetches all five leagues and writes the three today±1 fixture files", async () => {
    const range = utcPollRange();
    const today = new Date().toISOString().slice(0, 10);
    const provider = {
      fixturesForRange: vi.fn(async (leagueId: number) => [
        state(leagueId, `${today}T18:00:00Z`, leagueId),
      ]),
    };
    const r2 = { putJsonIfChanged: vi.fn().mockResolvedValue(undefined) };
    const svc = new ScheduleService(provider as never, r2 as never, seasons(), TOP_FIVE);

    const result = await svc.sync();

    expect(provider.fixturesForRange).toHaveBeenCalledTimes(5);
    for (const leagueId of TOP_FIVE) {
      expect(provider.fixturesForRange).toHaveBeenCalledWith(leagueId, 2026, range.from, range.to);
    }
    expect(result.fixtures).toBe(5);
    // Yesterday, today and tomorrow — all three, on the long schedule TTL.
    expect(new Set(result.dates)).toEqual(new Set([range.from, today, range.to]));
    for (const date of [range.from, today, range.to]) {
      expect(r2.putJsonIfChanged).toHaveBeenCalledWith(
        `fixtures-${date}.json`, expect.anything(), CACHE_CONTROL_LONG,
      );
    }
  });

  it("writes an EMPTY file for a date with no football, so the gate can read it", async () => {
    // The dispatcher opens its window off these files. A day the poller slept
    // through must still produce a file, or the gate has nothing to read.
    const range = utcPollRange();
    const today = new Date().toISOString().slice(0, 10);
    const provider = { fixturesForRange: vi.fn().mockResolvedValue([]) };
    const r2 = { putJsonIfChanged: vi.fn().mockResolvedValue(undefined) };
    const svc = new ScheduleService(provider as never, r2 as never, seasons(), TOP_FIVE);

    const result = await svc.sync();

    expect(result.fixtures).toBe(0);
    for (const date of [range.from, today, range.to]) {
      expect(r2.putJsonIfChanged).toHaveBeenCalledWith(
        `fixtures-${date}.json`, { matches: [] }, CACHE_CONTROL_LONG,
      );
    }
  });

  it("writes schedule-only rows — never live status, minute or score", async () => {
    const today = new Date().toISOString().slice(0, 10);
    const live: MatchState = {
      ...state(7, `${today}T18:00:00Z`),
      status: "LIVE", rawStatus: "2H", minute: 73, period: "SECOND", running: true,
      home: { id: 1, name: "A", goals: 2, yellowCards: 1, redCards: 0, yellowCardEvents: [], redCardEvents: [], goalEvents: [{ player: "X", minute: 20, extra: null }] },
    };
    const provider = { fixturesForRange: vi.fn().mockResolvedValue([live]) };
    const r2 = { putJsonIfChanged: vi.fn().mockResolvedValue(undefined) };
    const svc = new ScheduleService(provider as never, r2 as never, seasons(), [39]);

    await svc.sync();

    const call = r2.putJsonIfChanged.mock.calls.find(([key]) => key === `fixtures-${today}.json`);
    const row = (call![1] as { matches: MatchState[] }).matches[0]!;
    expect(row).toMatchObject({ status: "SCHEDULED", rawStatus: "NS", minute: null, running: false });
    expect(row.home.goals).toBe(0);
  });

  it("skips a league with no season in the catalog", async () => {
    const { LeagueSeasons } = await import("../src/catalog.js");
    const r2 = {
      putJsonIfChanged: vi.fn().mockResolvedValue(undefined),
      getJson: vi.fn().mockResolvedValue({ leagues: [{ id: 39, season: 2026 }] }),
    };
    const provider = { fixturesForRange: vi.fn().mockResolvedValue([]) };
    const svc = new ScheduleService(
      provider as never, r2 as never, new LeagueSeasons(r2 as never), [39, 140],
    );

    await svc.sync();

    expect(provider.fixturesForRange).toHaveBeenCalledTimes(1);
    expect(provider.fixturesForRange).toHaveBeenCalledWith(39, 2026, expect.any(String), expect.any(String));
  });
});
