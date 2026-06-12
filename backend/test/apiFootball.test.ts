import { describe, expect, it, vi } from "vitest";
import { ApiFootballProvider } from "../src/providers/apiFootball.js";

const liveFixture = {
  fixture: { id: 555, date: "2026-06-11T20:00:00+00:00", status: { short: "2H", elapsed: 73 } },
  league: { id: 1, season: 2026 },
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
      minute: 73,
      home: { code: "BRA", goals: 2, yellowCards: 0, redCards: 1 },
      away: { code: "USA", goals: 1, yellowCards: 1, redCards: 0 },
      lastGoal: { teamCode: "BRA", player: "Vinícius Jr", minute: 73 },
    });
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
