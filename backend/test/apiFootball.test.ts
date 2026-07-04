import { describe, expect, it, vi } from "vitest";
import { ApiFootballProvider } from "../src/providers/apiFootball.js";

const liveFixture = {
  fixture: { id: 555, date: "2026-06-11T20:00:00+00:00", status: { short: "2H", elapsed: 73 } },
  league: { id: 1, season: 2026, round: "Group A - 1" },
  teams: { home: { id: 10, name: "Brazil" }, away: { id: 20, name: "USA" } },
  goals: { home: 2, away: 1 },
  events: [
    { time: { elapsed: 12 }, team: { id: 20, name: "USA" }, player: { name: "Pulisic" }, type: "Goal", detail: "Normal Goal" },
    { time: { elapsed: 30 }, team: { id: 10, name: "Brazil" }, player: { name: "Rodrygo" }, type: "Goal", detail: "Normal Goal" },
    { time: { elapsed: 38 }, team: { id: 20, name: "USA" }, player: { name: "Adams" }, type: "Card", detail: "Yellow Card" },
    { time: { elapsed: 73 }, team: { id: 10, name: "Brazil" }, player: { name: "Vinícius Jr" }, type: "Goal", detail: "Normal Goal" },
    { time: { elapsed: 80 }, team: { id: 10, name: "Brazil" }, player: { name: "Casemiro" }, type: "Card", detail: "Red Card" },
  ],
};

function providerReturning(payload: unknown, status = 200) {
  const fetchMock = vi.fn().mockResolvedValue({
    ok: status < 400,
    status,
    json: () => Promise.resolve(payload),
  });
  return { provider: new ApiFootballProvider("key", 1, 2026, fetchMock as never), fetchMock };
}

describe("ApiFootballProvider", () => {
  it("maps a live fixture to MatchState with cards and last scorer", async () => {
    const { provider, fetchMock } = providerReturning({ response: [liveFixture] });
    const [match] = await provider.fixturesForRange("2026-06-10", "2026-06-12");

    expect(fetchMock).toHaveBeenCalledWith(
      "https://v3.football.api-sports.io/fixtures?league=1&season=2026&from=2026-06-10&to=2026-06-12&timezone=UTC",
      { headers: { "x-apisports-key": "key" } },
    );
    expect(match).toMatchObject({
      fixtureId: 555,
      status: "LIVE",
      rawStatus: "2H",
      round: "Group A - 1",
      minute: 73,
      extra: null,
      period: "SECOND",
      running: true,
      home: { id: 10, name: "Brazil", goals: 2, yellowCards: 0, redCards: 1 },
      away: { id: 20, name: "USA", goals: 1, yellowCards: 1, redCards: 0 },
      lastGoal: { teamId: 10, player: "Vinícius Jr", minute: 73, extra: null },
    });
  });

  it("parses status.extra and time.extra so the clock can show stoppage (90+3)", async () => {
    const stoppageFixture = {
      fixture: { id: 556, date: "2026-06-11T20:00:00+00:00", status: { short: "2H", elapsed: 90, extra: 3 } },
      league: { id: 1, season: 2026, round: "Group A - 2" },
      teams: { home: { id: 10, name: "Brazil" }, away: { id: 20, name: "USA" } },
      goals: { home: 1, away: 0 },
      events: [
        // A 90+3 goal: elapsed pins at 90, extra holds the added minute.
        { time: { elapsed: 90, extra: 3 }, team: { id: 10, name: "Brazil" }, player: { name: "Rodrygo" }, type: "Goal", detail: "Normal Goal" },
        { time: { elapsed: 45, extra: 2 }, team: { id: 20, name: "USA" }, player: { name: "Adams" }, type: "Card", detail: "Yellow Card" },
      ],
    };
    const { provider } = providerReturning({ response: [stoppageFixture] });
    const [match] = await provider.fixturesForRange("2026-06-10", "2026-06-12");

    expect(match).toMatchObject({ minute: 90, extra: 3, period: "SECOND", running: true });
    // The goal record carries `extra` so a pill can render `90+3′`.
    expect(match!.home.goalEvents).toEqual([{ player: "Rodrygo", minute: 90, extra: 3 }]);
    expect(match!.away.yellowCardEvents).toEqual([{ player: "Adams", minute: 45, extra: 2 }]);
    expect(match!.lastGoal).toMatchObject({ teamId: 10, player: "Rodrygo", minute: 90, extra: 3 });
  });

  it("derives running=false and the right period for non-playing phases", async () => {
    const phases: Array<[string, number | null, string, boolean, string]> = [
      ["HT", 45, "HALF", false, "HALF_TIME"],
      ["BT", null, "BREAK", false, "LIVE"], // pre-ET break, API sends elapsed=null → "BT", NOT "ET HT"
      ["BT", 90, "BREAK", false, "LIVE"], // ET setup break at 90' → "BT"
      ["BT", 105, "EXTRA_BREAK", false, "LIVE"], // break between the two ET halves → "ET HT"
      ["BT", 120, "PENALTIES", false, "LIVE"], // break after ET, shootout imminent → "PENS", not "ET HT"
      ["P", 120, "PENALTIES", false, "LIVE"],
      ["FT", 90, "FINISHED", false, "FINISHED"],
      ["NS", null, "PRE", false, "SCHEDULED"],
    ];
    for (const [short, elapsed, period, running, status] of phases) {
      const fixture = {
        fixture: { id: 700, date: "2026-06-11T20:00:00+00:00", status: { short, elapsed, extra: null } },
        league: { id: 1, season: 2026, round: "R16" },
        teams: { home: { id: 10, name: "Brazil" }, away: { id: 20, name: "USA" } },
        goals: { home: 0, away: 0 },
        events: [],
      };
      const { provider } = providerReturning({ response: [fixture] });
      const [match] = await provider.fixturesForRange("2026-06-10", "2026-06-12");
      expect(match, short).toMatchObject({ period, running, status });
    }
  });

  it("splits the two extra-time halves by elapsed (<=105 first, >105 second)", async () => {
    const make = (elapsed: number) => ({
      fixture: { id: 701, date: "2026-06-11T20:00:00+00:00", status: { short: "ET", elapsed, extra: null } },
      league: { id: 1, season: 2026, round: "R16" },
      teams: { home: { id: 10, name: "Brazil" }, away: { id: 20, name: "USA" } },
      goals: { home: 0, away: 0 },
      events: [],
    });

    const first = providerReturning({ response: [make(100)] });
    const [etFirst] = await first.provider.fixturesForRange("2026-06-10", "2026-06-12");
    expect(etFirst).toMatchObject({ period: "EXTRA_FIRST", running: true, status: "LIVE" });

    const boundary = providerReturning({ response: [make(105)] });
    const [etBoundary] = await boundary.provider.fixturesForRange("2026-06-10", "2026-06-12");
    expect(etBoundary!.period).toBe("EXTRA_FIRST"); // 105 is still the first half

    const second = providerReturning({ response: [make(106)] });
    const [etSecond] = await second.provider.fixturesForRange("2026-06-10", "2026-06-12");
    expect(etSecond).toMatchObject({ period: "EXTRA_SECOND", running: true });
  });

  it("parses a penalty shootout into shootout counts + ordered kicks", async () => {
    const penFixture = {
      fixture: { id: 777, date: "2026-06-11T20:00:00+00:00", status: { short: "PEN", elapsed: 120 } },
      league: { id: 1, season: 2026, round: "Round of 16" },
      teams: { home: { id: 10, name: "Brazil" }, away: { id: 20, name: "USA" } },
      goals: { home: 3, away: 3 },
      score: { penalty: { home: 2, away: 1 } },
      events: [
        // A missed in-play penalty must NOT become lastGoal.
        { time: { elapsed: 60 }, team: { id: 10, name: "Brazil" }, player: { name: "Neymar" }, type: "Goal", detail: "Missed Penalty", comments: null },
        { time: { elapsed: 70 }, team: { id: 10, name: "Brazil" }, player: { name: "Rodrygo" }, type: "Goal", detail: "Normal Goal", comments: null },
        // Shootout kicks (comments mark them as such).
        { time: { elapsed: 120 }, team: { id: 10, name: "Brazil" }, player: { name: "Casemiro" }, type: "Goal", detail: "Penalty", comments: "Penalty Shootout" },
        { time: { elapsed: 120 }, team: { id: 20, name: "USA" }, player: { name: "Pulisic" }, type: "Goal", detail: "Missed Penalty", comments: "Penalty Shootout" },
        { time: { elapsed: 120 }, team: { id: 10, name: "Brazil" }, player: { name: "Vinícius Jr" }, type: "Goal", detail: "Penalty", comments: "Penalty Shootout" },
        { time: { elapsed: 120 }, team: { id: 20, name: "USA" }, player: { name: "McKennie" }, type: "Goal", detail: "Penalty", comments: "Penalty Shootout" },
      ],
    };
    const { provider } = providerReturning({ response: [penFixture] });
    const [match] = await provider.fixturesForRange("2026-06-10", "2026-06-12");

    expect(match!.status).toBe("FINISHED");
    expect(match!.round).toBe("Round of 16");
    expect(match!.shootout).toEqual({
      home: 2,
      away: 1,
      kicks: [
        { teamId: 10, player: "Casemiro", scored: true },
        { teamId: 20, player: "Pulisic", scored: false },
        { teamId: 10, player: "Vinícius Jr", scored: true },
        { teamId: 20, player: "McKennie", scored: true },
      ],
    });
    // The in-play missed penalty was skipped; Rodrygo is the last real scorer.
    expect(match!.lastGoal).toMatchObject({ teamId: 10, player: "Rodrygo" });
  });

  it("parses substitutions with player out (`player`) and in (`assist`)", async () => {
    const fixture = {
      fixture: { id: 800, date: "2026-06-11T20:00:00+00:00", status: { short: "2H", elapsed: 64 } },
      league: { id: 1, season: 2026, round: "R16" },
      teams: { home: { id: 10, name: "Brazil" }, away: { id: 20, name: "USA" } },
      goals: { home: 0, away: 0 },
      events: [
        { time: { elapsed: 46 }, team: { id: 10, name: "Brazil" }, player: { name: "Fred" }, assist: { name: "Paquetá" }, type: "subst", detail: "Substitution 1" },
        { time: { elapsed: 64 }, team: { id: 20, name: "USA" }, player: { name: "Reyna" }, assist: { name: "Aaronson" }, type: "subst", detail: "Substitution 2" },
      ],
    };
    const { provider } = providerReturning({ response: [fixture] });
    const [match] = await provider.fixturesForRange("2026-06-10", "2026-06-12");
    expect(match!.home.subs).toEqual([{ playerOut: "Fred", playerIn: "Paquetá", minute: 46, extra: null }]);
    expect(match!.away.subs).toEqual([{ playerOut: "Reyna", playerIn: "Aaronson", minute: 64, extra: null }]);
  });

  it("credits an own goal to the benefiting team (API's convention) and tags its kind", async () => {
    const fixture = {
      fixture: { id: 801, date: "2026-06-11T20:00:00+00:00", status: { short: "2H", elapsed: 55 } },
      league: { id: 1, season: 2026, round: "R16" },
      teams: { home: { id: 10, name: "Brazil" }, away: { id: 20, name: "USA" } },
      goals: { home: 1, away: 0 }, // aggregate credits the benefiting side (home)
      events: [
        // API-Football attributes the own goal to the BENEFITING team (Brazil,
        // home) and names the OPPONENT player (a USA defender) who put it in.
        // We credit `ev.team` directly — no flip — so it stays in sync with the
        // aggregate above.
        { time: { elapsed: 50 }, team: { id: 10, name: "Brazil" }, player: { name: "Robinson" }, type: "Goal", detail: "Own Goal" },
      ],
    };
    const { provider } = providerReturning({ response: [fixture] });
    const [match] = await provider.fixturesForRange("2026-06-10", "2026-06-12");
    expect(match!.home.goals).toBe(1);
    expect(match!.home.goalEvents).toEqual([{ player: "Robinson", minute: 50, extra: null, kind: "own" }]);
    expect(match!.away.goalEvents).toEqual([]);
    expect(match!.lastGoal).toMatchObject({ teamId: 10, player: "Robinson" });
  });

  it("tags an in-play penalty goal with kind 'penalty'", async () => {
    const fixture = {
      fixture: { id: 802, date: "2026-06-11T20:00:00+00:00", status: { short: "2H", elapsed: 73 } },
      league: { id: 1, season: 2026, round: "R16" },
      teams: { home: { id: 10, name: "Brazil" }, away: { id: 20, name: "USA" } },
      goals: { home: 1, away: 0 },
      events: [
        { time: { elapsed: 73 }, team: { id: 10, name: "Brazil" }, player: { name: "Neymar" }, type: "Goal", detail: "Penalty", comments: null },
      ],
    };
    const { provider } = providerReturning({ response: [fixture] });
    const [match] = await provider.fixturesForRange("2026-06-10", "2026-06-12");
    expect(match!.home.goalEvents).toEqual([{ player: "Neymar", minute: 73, extra: null, kind: "penalty" }]);
  });

  it("keeps non-goal VAR outcomes but excludes goal cancellations (score-drop covers those)", async () => {
    const fixture = {
      fixture: { id: 803, date: "2026-06-11T20:00:00+00:00", status: { short: "2H", elapsed: 68 } },
      league: { id: 1, season: 2026, round: "R16" },
      teams: { home: { id: 10, name: "Brazil" }, away: { id: 20, name: "USA" } },
      goals: { home: 0, away: 0 },
      events: [
        { time: { elapsed: 67 }, team: { id: 10, name: "Brazil" }, player: { name: "Neymar" }, type: "Var", detail: "Penalty confirmed" },
        { time: { elapsed: 68 }, team: { id: 20, name: "USA" }, player: { name: null }, type: "Var", detail: "Goal cancelled" },
      ],
    };
    const { provider } = providerReturning({ response: [fixture] });
    const [match] = await provider.fixturesForRange("2026-06-10", "2026-06-12");
    expect(match!.varEvents).toEqual([
      { teamId: 10, detail: "Penalty confirmed", player: "Neymar", minute: 67, extra: null },
    ]);
  });

  it("leaves shootout undefined for a normal in-play fixture", async () => {
    const { provider } = providerReturning({ response: [liveFixture] });
    const [match] = await provider.fixturesForRange("2026-06-10", "2026-06-12");
    expect(match!.shootout).toBeUndefined();
  });

  it("takes team identity straight from the fixture id (no name mapping)", async () => {
    const fixture = structuredClone(liveFixture);
    fixture.teams.home = { id: 99999, name: "New Caledonia" };
    fixture.events = [];
    const { provider } = providerReturning({ response: [fixture] });
    const [match] = await provider.fixturesForRange("2026-06-10", "2026-06-12");
    expect(match!.home).toMatchObject({ id: 99999, name: "New Caledonia" });
  });

  it("throws a useful error on API failure", async () => {
    const { provider } = providerReturning({ errors: { token: "bad key" } });
    await expect(provider.fixturesForRange("2026-06-10", "2026-06-12")).rejects.toThrow(/bad key|bad body/);
  });

  it("throws on HTTP errors", async () => {
    const { provider } = providerReturning({}, 429);
    await expect(provider.fixturesForRange("2026-06-10", "2026-06-12")).rejects.toThrow("HTTP 429");
  });

  it("fetches events via ids endpoint for live fixtures (range endpoint omits them)", async () => {
    // Range call returns the fixture WITHOUT events (as the real API does).
    const rangeFixture = { ...liveFixture, events: undefined };
    const fetchMock = vi.fn()
      .mockResolvedValueOnce({ ok: true, status: 200, json: () => Promise.resolve({ response: [rangeFixture] }) })
      .mockResolvedValueOnce({ ok: true, status: 200, json: () => Promise.resolve({ response: [liveFixture] }) });
    const provider = new ApiFootballProvider("key", 1, 2026, fetchMock as never);

    const [match] = await provider.fixturesForRange("2026-06-10", "2026-06-12");

    expect(fetchMock).toHaveBeenCalledTimes(2);
    expect(fetchMock).toHaveBeenNthCalledWith(2,
      "https://v3.football.api-sports.io/fixtures?ids=555",
      { headers: { "x-apisports-key": "key" } },
    );
    expect(match).toMatchObject({
      away: { yellowCards: 1 },
      home: { redCards: 1 },
    });
  });

  it("publishes the aggregate score immediately, before the scorer event lands", async () => {
    // API bumped the aggregate to 1-0 but the goal isn't in events[] yet.
    const racing = {
      ...liveFixture,
      goals: { home: 1, away: 0 },
      events: [{ time: { elapsed: 22 }, team: { id: 20, name: "USA" }, player: { name: "Adams" }, type: "Card", detail: "Yellow Card" }],
    };
    const { provider } = providerReturning({ response: [racing] });
    const [match] = await provider.fixturesForRange("2026-06-10", "2026-06-12");
    // Score follows the authoritative aggregate the instant it moves — the diff
    // emits GOAL now; the scorer name fills in on a later poll via goalEvents.
    expect(match!.home.goals).toBe(1);
    expect(match!.home.goalEvents).toEqual([]);
  });

  it("clamps an overrunning ET clock (elapsed 124) to minute:120, extra:4", async () => {
    const fixture = {
      fixture: { id: 810, date: "2026-06-11T20:00:00+00:00", status: { short: "ET", elapsed: 124, extra: null } },
      league: { id: 1, season: 2026, round: "R16" },
      teams: { home: { id: 10, name: "Brazil" }, away: { id: 20, name: "USA" } },
      goals: { home: 0, away: 0 },
      events: [],
    };
    const { provider } = providerReturning({ response: [fixture] });
    const [match] = await provider.fixturesForRange("2026-06-10", "2026-06-12");
    expect(match).toMatchObject({ minute: 120, extra: 4, period: "EXTRA_SECOND", running: true });
  });

  it("folds 2H stoppage overrun (elapsed 93) into 90+3", async () => {
    const fixture = {
      fixture: { id: 811, date: "2026-06-11T20:00:00+00:00", status: { short: "2H", elapsed: 93, extra: null } },
      league: { id: 1, season: 2026, round: "R16" },
      teams: { home: { id: 10, name: "Brazil" }, away: { id: 20, name: "USA" } },
      goals: { home: 0, away: 0 },
      events: [],
    };
    const { provider } = providerReturning({ response: [fixture] });
    const [match] = await provider.fixturesForRange("2026-06-10", "2026-06-12");
    expect(match).toMatchObject({ minute: 90, extra: 3, period: "SECOND" });
  });

  it("normalizes empty/whitespace player names to null", async () => {
    const fixture = {
      fixture: { id: 812, date: "2026-06-11T20:00:00+00:00", status: { short: "2H", elapsed: 66 } },
      league: { id: 1, season: 2026, round: "R16" },
      teams: { home: { id: 10, name: "Brazil" }, away: { id: 20, name: "USA" } },
      goals: { home: 1, away: 0 },
      events: [
        { time: { elapsed: 66 }, team: { id: 10, name: "Brazil" }, player: { name: "   " }, type: "Goal", detail: "Normal Goal" },
        { time: { elapsed: 60 }, team: { id: 20, name: "USA" }, player: { name: "" }, type: "Card", detail: "Yellow Card" },
      ],
    };
    const { provider } = providerReturning({ response: [fixture] });
    const [match] = await provider.fixturesForRange("2026-06-10", "2026-06-12");
    expect(match!.home.goalEvents).toEqual([{ player: null, minute: 66, extra: null }]);
    expect(match!.away.yellowCardEvents).toEqual([{ player: null, minute: 60, extra: null }]);
    expect(match!.lastGoal).toMatchObject({ teamId: 10, player: null });
  });

  it("exposes goalEvents in scoring order and keeps the count once scorers land", async () => {
    const { provider } = providerReturning({ response: [liveFixture] });
    const [match] = await provider.fixturesForRange("2026-06-10", "2026-06-12");
    expect(match!.home.goals).toBe(2);
    expect(match!.home.goalEvents).toEqual([
      { player: "Rodrygo", minute: 30, extra: null },
      { player: "Vinícius Jr", minute: 73, extra: null },
    ]);
    expect(match!.away.goalEvents).toEqual([{ player: "Pulisic", minute: 12, extra: null }]);
  });
});
