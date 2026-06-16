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
      home: { id: 10, name: "Brazil", goals: 2, yellowCards: 0, redCards: 1 },
      away: { id: 20, name: "USA", goals: 1, yellowCards: 1, redCards: 0 },
      lastGoal: { teamId: 10, player: "Vinícius Jr", minute: 73 },
    });
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

  it("holds a live goal back until its scorer event lands (counter races events)", async () => {
    // API bumped the aggregate to 1-0 but the goal isn't in events[] yet.
    const racing = {
      ...liveFixture,
      goals: { home: 1, away: 0 },
      events: [{ time: { elapsed: 22 }, team: { id: 20, name: "USA" }, player: { name: "Adams" }, type: "Card", detail: "Yellow Card" }],
    };
    const { provider } = providerReturning({ response: [racing] });
    const [match] = await provider.fixturesForRange("2026-06-10", "2026-06-12");
    // Goal count stays at 0 (no scorer yet) and carries no goalEvents — so the
    // diff won't emit a nameless GOAL this poll.
    expect(match!.home.goals).toBe(0);
    expect(match!.home.goalEvents).toEqual([]);
  });

  it("exposes goalEvents in scoring order and keeps the count once scorers land", async () => {
    const { provider } = providerReturning({ response: [liveFixture] });
    const [match] = await provider.fixturesForRange("2026-06-10", "2026-06-12");
    expect(match!.home.goals).toBe(2);
    expect(match!.home.goalEvents).toEqual([
      { player: "Rodrygo", minute: 30 },
      { player: "Vinícius Jr", minute: 73 },
    ]);
    expect(match!.away.goalEvents).toEqual([{ player: "Pulisic", minute: 12 }]);
  });
});
