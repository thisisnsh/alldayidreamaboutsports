import { describe, expect, it } from "vitest";
import { diffMatch } from "../src/diff.js";
import type { MatchState } from "../src/types.js";

function team(id: number, name: string, overrides: Partial<MatchState["home"]> = {}): MatchState["home"] {
  return { id, name, goals: 0, yellowCards: 0, redCards: 0, yellowCardEvents: [], redCardEvents: [], goalEvents: [], ...overrides };
}

function state(overrides: Partial<MatchState> = {}): MatchState {
  return {
    fixtureId: 100,
    leagueId: 1,
    season: 2026,
    kickoffISO: "2026-06-11T20:00:00+00:00",
    status: "LIVE",
    rawStatus: "1H",
    minute: 10,
    home: team(6, "Brazil"),
    away: team(16, "United States"),
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

  it("emits one GOAL per increment with the scorer from goalEvents", () => {
    const prev = state();
    const next = state({
      home: { ...prev.home, goals: 1, goalEvents: [{ player: "Vinícius Jr", minute: 23 }] },
      minute: 23,
    });
    const events = diffMatch(prev, next);
    expect(events).toHaveLength(1);
    expect(events[0]).toMatchObject({
      type: "GOAL",
      teamId: 6,
      player: "Vinícius Jr",
      minute: 23,
      eventId: "100:GOAL:6:1",
    });
  });

  it("never emits a nameless GOAL — falls back to the scoring team's name", () => {
    // An unenriched finished snapshot can surface a goal with no goalEvents row.
    const prev = state();
    const next = state({ home: { ...prev.home, goals: 1 } });
    const events = diffMatch(prev, next);
    expect(events).toHaveLength(1);
    expect(events[0]).toMatchObject({ type: "GOAL", teamId: 6, player: "Brazil" });
  });

  it("emits multiple GOALs if two goals land between polls", () => {
    const prev = state();
    const next = state({ away: { ...prev.away, goals: 2 } });
    const events = diffMatch(prev, next);
    expect(events.map((e) => e.eventId)).toEqual(["100:GOAL:16:1", "100:GOAL:16:2"]);
  });

  it("emits GOAL_CANCELLED when VAR takes a goal away", () => {
    const prev = state({ home: team(6, "Brazil", { goals: 1 }) });
    const next = state();
    const events = diffMatch(prev, next);
    expect(events).toHaveLength(1);
    expect(events[0]).toMatchObject({ type: "GOAL_CANCELLED", teamId: 6 });
  });

  it("emits cards per increment with player and minute attribution", () => {
    const prev = state();
    const next = state({
      home: team(6, "Brazil", {
        yellowCards: 2,
        redCards: 1,
        yellowCardEvents: [
          { player: "Rodrygo", minute: 32 },
          { player: "Casemiro", minute: 55 },
        ],
        redCardEvents: [{ player: "Militão", minute: 78 }],
      }),
      minute: 80,
    });
    const events = diffMatch(prev, next);
    expect(events.map((e) => e.type).sort()).toEqual(["RED_CARD", "YELLOW_CARD", "YELLOW_CARD"]);
    expect(events.find((e) => e.type === "RED_CARD")).toMatchObject({
      teamId: 6, player: "Militão", minute: 78, eventId: "100:RED_CARD:6:1",
    });
    const yellows = events.filter((e) => e.type === "YELLOW_CARD");
    expect(yellows[0]).toMatchObject({ teamId: 6, player: "Rodrygo", minute: 32 });
    expect(yellows[1]).toMatchObject({ teamId: 6, player: "Casemiro", minute: 55 });
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

  it("emits EXTRA_TIME once entering ET, but not again after the BT break", () => {
    const secondHalf = state({ rawStatus: "2H", minute: 90 });
    const et = state({ rawStatus: "ET", minute: 91 });
    expect(types(secondHalf, et)).toEqual(["EXTRA_TIME"]);
    // ET → BT (break between ET halves) → ET must not re-fire.
    const bt = state({ rawStatus: "BT", minute: 105 });
    expect(types(et, bt)).toEqual([]);
    expect(types(bt, state({ rawStatus: "ET", minute: 106 }))).toEqual([]);
  });

  it("emits PENALTY_SHOOTOUT once when penalties begin", () => {
    const et = state({ rawStatus: "ET", minute: 120 });
    const penalties = state({
      rawStatus: "P",
      minute: 120,
      shootout: { home: 0, away: 0, kicks: [] },
    });
    expect(types(et, penalties)).toEqual(["PENALTY_SHOOTOUT"]);
    expect(types(penalties, penalties)).toEqual([]);
  });

  it("emits one PENALTY_KICK per new kick with scored flag and running tally", () => {
    const kick = (teamId: number, scored: boolean) => ({ teamId, player: null, scored });
    const prev = state({
      rawStatus: "P",
      shootout: { home: 1, away: 0, kicks: [kick(6, true), kick(16, false)] },
    });
    const next = state({
      rawStatus: "P",
      shootout: {
        home: 1,
        away: 1,
        kicks: [kick(6, true), kick(16, false), kick(6, false), kick(16, true)],
      },
    });
    const events = diffMatch(prev, next).filter((e) => e.type === "PENALTY_KICK");
    expect(events).toHaveLength(2); // only the two new kicks
    expect(events[0]).toMatchObject({
      teamId: 6, scored: false, penHome: 1, penAway: 0, eventId: "100:PENALTY_KICK:3",
    });
    expect(events[1]).toMatchObject({
      teamId: 16, scored: true, penHome: 1, penAway: 1, eventId: "100:PENALTY_KICK:4",
    });
  });

  it("carries the pen tally onto FULL_TIME after a shootout", () => {
    const shootout = { home: 4, away: 2, kicks: [] };
    const pen = state({ status: "LIVE", rawStatus: "P", shootout });
    const ft = state({ status: "FINISHED", rawStatus: "PEN", shootout });
    const fullTime = diffMatch(pen, ft).find((e) => e.type === "FULL_TIME");
    expect(fullTime).toMatchObject({ penHome: 4, penAway: 2 });
  });

  it("handles goal + card + half-time arriving in one poll", () => {
    const prev = state({ minute: 44 });
    const next = state({
      status: "HALF_TIME",
      rawStatus: "HT",
      minute: 45,
      home: team(6, "Brazil", { goals: 1, yellowCards: 1, yellowCardEvents: [{ player: "Rodrygo", minute: 45 }] }),
    });
    expect(types(prev, next).sort()).toEqual(["GOAL", "HALF_TIME", "YELLOW_CARD"]);
  });
});
