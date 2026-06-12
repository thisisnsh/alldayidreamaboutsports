import { describe, expect, it } from "vitest";
import { diffMatch } from "../src/diff.js";
import type { MatchState } from "../src/types.js";

function state(overrides: Partial<MatchState> = {}): MatchState {
  return {
    fixtureId: 100,
    leagueId: 1,
    season: 2026,
    kickoffISO: "2026-06-11T20:00:00+00:00",
    status: "LIVE",
    rawStatus: "1H",
    minute: 10,
    home: { code: "BRA", name: "Brazil", goals: 0, yellowCards: 0, redCards: 0 },
    away: { code: "USA", name: "United States", goals: 0, yellowCards: 0, redCards: 0 },
    ...overrides,
  };
}

const types = (prev: MatchState | null, next: MatchState) =>
  diffMatch(prev, next).map((e) => e.type);

describe("diffMatch", () => {
  it("emits KICKOFF when a scheduled match goes live", () => {
    const prev = state({ status: "SCHEDULED", rawStatus: "NS", minute: null });
    expect(types(prev, state())).toEqual(["KICKOFF"]);
  });

  it("emits KICKOFF for a match first seen live (no previous state)", () => {
    expect(types(null, state())).toEqual(["KICKOFF"]);
  });

  it("emits one GOAL per increment with scorer attribution", () => {
    const prev = state();
    const next = state({
      home: { ...prev.home, goals: 1 },
      lastGoal: { teamCode: "BRA", player: "Vinícius Jr", minute: 23 },
      minute: 23,
    });
    const events = diffMatch(prev, next);
    expect(events).toHaveLength(1);
    expect(events[0]).toMatchObject({
      type: "GOAL",
      teamCode: "BRA",
      player: "Vinícius Jr",
      minute: 23,
      eventId: "100:GOAL:BRA:1",
    });
  });

  it("emits multiple GOALs if two goals land between polls", () => {
    const prev = state();
    const next = state({ away: { ...prev.away, goals: 2 } });
    const events = diffMatch(prev, next);
    expect(events.map((e) => e.eventId)).toEqual(["100:GOAL:USA:1", "100:GOAL:USA:2"]);
  });

  it("emits GOAL_CANCELLED when VAR takes a goal away", () => {
    const prev = state({ home: { code: "BRA", name: "Brazil", goals: 1, yellowCards: 0, redCards: 0 } });
    const next = state();
    const events = diffMatch(prev, next);
    expect(events).toHaveLength(1);
    expect(events[0]).toMatchObject({ type: "GOAL_CANCELLED", teamCode: "BRA" });
  });

  it("emits cards per increment", () => {
    const prev = state();
    const next = state({
      home: { ...prev.home, yellowCards: 2, redCards: 1 },
    });
    expect(types(prev, next).sort()).toEqual(["RED_CARD", "YELLOW_CARD", "YELLOW_CARD"]);
  });

  it("emits HALF_TIME and FULL_TIME transitions exactly once", () => {
    const live = state({ rawStatus: "2H", minute: 46 });
    const ht = state({ status: "HALF_TIME", rawStatus: "HT", minute: 45 });
    expect(types(live, ht)).toEqual(["HALF_TIME"]);
    expect(types(ht, ht)).toEqual([]); // repeated HT poll → nothing

    const ft = state({ status: "FINISHED", rawStatus: "FT", minute: 90 });
    expect(types(live, ft)).toEqual(["FULL_TIME"]);
    expect(types(ft, ft)).toEqual([]);
  });

  it("is deterministic: same transition always produces the same event ids", () => {
    const prev = state();
    const next = state({ home: { ...prev.home, goals: 1 } });
    const a = diffMatch(prev, next).map((e) => e.eventId);
    const b = diffMatch(prev, next).map((e) => e.eventId);
    expect(a).toEqual(b);
  });

  it("produces no events when nothing changed", () => {
    const s = state({ minute: 30 });
    expect(types(state({ minute: 29 }), s)).toEqual([]);
  });

  it("handles goal + card + half-time arriving in one poll", () => {
    const prev = state({ minute: 44 });
    const next = state({
      status: "HALF_TIME",
      rawStatus: "HT",
      minute: 45,
      home: { code: "BRA", name: "Brazil", goals: 1, yellowCards: 1, redCards: 0 },
    });
    expect(types(prev, next).sort()).toEqual(["GOAL", "HALF_TIME", "YELLOW_CARD"]);
  });
});
