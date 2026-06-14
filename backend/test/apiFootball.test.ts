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
    const [match] = await provider.liveMatches();

    expect(fetchMock).toHaveBeenCalledWith(
      "https://v3.football.api-sports.io/fixtures?live=all&league=1&season=2026",
      { headers: { "x-apisports-key": "key" } },
    );
    expect(match).toMatchObject({
      fixtureId: 555,
      status: "LIVE",
      rawStatus: "2H",
      round: "Group A - 1",
      minute: 73,
      home: { code: "BRA", goals: 2, yellowCards: 0, redCards: 1 },
      away: { code: "USA", goals: 1, yellowCards: 1, redCards: 0 },
      lastGoal: { teamCode: "BRA", player: "Vinícius Jr", minute: 73 },
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
    const [match] = await provider.liveMatches();

    expect(match!.status).toBe("FINISHED");
    expect(match!.round).toBe("Round of 16");
    expect(match!.shootout).toEqual({
      home: 2,
      away: 1,
      kicks: [
        { teamCode: "BRA", player: "Casemiro", scored: true },
        { teamCode: "USA", player: "Pulisic", scored: false },
        { teamCode: "BRA", player: "Vinícius Jr", scored: true },
        { teamCode: "USA", player: "McKennie", scored: true },
      ],
    });
    // The in-play missed penalty was skipped; Rodrygo is the last real scorer.
    expect(match!.lastGoal).toMatchObject({ teamCode: "BRA", player: "Rodrygo" });
  });

  it("leaves shootout undefined for a normal in-play fixture", async () => {
    const { provider } = providerReturning({ response: [liveFixture] });
    const [match] = await provider.liveMatches();
    expect(match!.shootout).toBeUndefined();
  });

  it("maps unknown teams to a derived code instead of crashing", async () => {
    const fixture = structuredClone(liveFixture);
    fixture.teams.home.name = "New Caledonia";
    fixture.events = [];
    const { provider } = providerReturning({ response: [fixture] });
    const [match] = await provider.liveMatches();
    expect(match!.home.code).toBe("NEW");
  });

  it("throws a useful error on API failure", async () => {
    const { provider } = providerReturning({ errors: { token: "bad key" } });
    await expect(provider.liveMatches()).rejects.toThrow(/bad key|bad body/);
  });

  it("throws on HTTP errors", async () => {
    const { provider } = providerReturning({}, 429);
    await expect(provider.liveMatches()).rejects.toThrow("HTTP 429");
  });
});
