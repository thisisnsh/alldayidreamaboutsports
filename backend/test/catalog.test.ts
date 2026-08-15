import { describe, expect, it, vi } from "vitest";
import { CatalogService } from "../src/catalog.js";
import { ApiFootballProvider } from "../src/providers/apiFootball.js";
import type { CatalogTeam, LeagueInfo, ScoreProvider } from "../src/providers/types.js";

function providerReturning(payload: unknown, status = 200) {
  const fetchMock = vi.fn().mockResolvedValue({
    ok: status < 400,
    status,
    json: () => Promise.resolve(payload),
  });
  return { provider: new ApiFootballProvider("key", fetchMock as never), fetchMock };
}

const league = (seasons: Array<{ year: number; current: boolean; end: string }>) => ({
  league: { id: 39, name: "Premier League", type: "League", logo: "pl.png" },
  country: { name: "England" },
  seasons,
});

describe("ApiFootballProvider.leagueInfo", () => {
  it("picks the season flagged current", async () => {
    const { provider } = providerReturning({
      response: [league([
        { year: 2024, current: false, end: "2025-05-25" },
        { year: 2025, current: true, end: "2999-05-24" },
      ])],
    });
    expect(await provider.leagueInfo(39)).toMatchObject({ season: 2025, scheduled: true });
  });

  it("falls back to an upcoming season (no current, end still in the future)", async () => {
    const { provider } = providerReturning({
      response: [league([
        { year: 2024, current: false, end: "2025-05-25" },
        { year: 2026, current: false, end: "2999-12-31" },
      ])],
    });
    expect(await provider.leagueInfo(39)).toMatchObject({ season: 2026, scheduled: true });
  });

  it("reports not-scheduled when no season is current or upcoming", async () => {
    const { provider } = providerReturning({
      response: [league([{ year: 2000, current: false, end: "2000-05-25" }])],
    });
    expect(await provider.leagueInfo(39)).toMatchObject({ season: null, scheduled: false });
  });

  it("carries the league's country through", async () => {
    const { provider } = providerReturning({
      response: [league([{ year: 2025, current: true, end: "2999-05-24" }])],
    });
    expect(await provider.leagueInfo(39)).toMatchObject({ country: "England" });
  });
});

describe("ApiFootballProvider.leagueInfo ended", () => {
  it("derives ended from the season end date, NOT from `current`", async () => {
    // Exactly the World Cup 2026 shape: still flagged current a month after the
    // final, so `current` would say it is live and the end date says it is over.
    const { provider } = providerReturning({
      response: [{
        league: { id: 1, name: "World Cup", type: "Cup", logo: "wc.png" },
        country: { name: "World" },
        seasons: [{ year: 2026, current: true, end: "2026-07-19" }],
      }],
    });
    expect(await provider.leagueInfo(1)).toMatchObject({
      id: 1, season: 2026, scheduled: true, ended: true,
    });
  });

  it("is not ended while the current season still has time to run", async () => {
    const { provider } = providerReturning({
      response: [league([{ year: 2026, current: true, end: "2999-05-24" }])],
    });
    expect(await provider.leagueInfo(39)).toMatchObject({ ended: false });
  });

  it("is not ended when there is no season at all", async () => {
    const { provider } = providerReturning({
      response: [league([{ year: 2000, current: false, end: "2000-05-25" }])],
    });
    expect(await provider.leagueInfo(39)).toMatchObject({ season: null, ended: false });
  });
});

describe("ApiFootballProvider.teamsForLeague", () => {
  it("maps API team rows to catalog teams with logos", async () => {
    const { provider, fetchMock } = providerReturning({
      response: [
        { team: { id: 50, name: "Manchester City", code: "MCI", country: "England", logo: "50.png" } },
      ],
    });
    const teams = await provider.teamsForLeague(39, 2025);
    expect(fetchMock).toHaveBeenCalledWith(
      "https://v3.football.api-sports.io/teams?league=39&season=2025",
      { headers: { "x-apisports-key": "key" } },
    );
    expect(teams[0]).toEqual({
      id: 50, code: "MCI", name: "Manchester City", country: "England", logo: "50.png", leagueId: 39,
    });
  });
});

describe("CatalogService", () => {
  function fakeProvider(): ScoreProvider {
    return {
      fixturesForRange: vi.fn(),
      fixturesByIds: vi.fn(),
      leagueInfo: vi.fn(async (id: number): Promise<LeagueInfo> => ({
        id,
        name: `League ${id}`,
        logo: `${id}.png`,
        type: id === 1 ? "Cup" : "League",
        country: id === 1 ? "World" : "England",
        season: id === 61 ? null : 2026, // pretend Ligue 1 (61) has nothing scheduled
        scheduled: id !== 61,
        ended: id === 1, // the archived World Cup
      })),
      teamsForLeague: vi.fn(async (leagueId: number): Promise<CatalogTeam[]> => [
        { id: leagueId * 10, code: "X", name: "Team", country: "C", logo: "t.png", leagueId },
      ]),
    };
  }

  it("assembles leagues with active flags and only fetches teams for scheduled seasons", async () => {
    const provider = fakeProvider();
    const r2 = { putJson: vi.fn().mockResolvedValue(undefined) };
    const svc = new CatalogService(provider, r2 as never);

    const payload = await svc.build();

    // The World Cup is archived: listed, inactive, ended — but still scheduled,
    // so its teams stay resolvable for anyone still following a national side.
    expect(payload.leagues.find((l) => l.id === 1)).toMatchObject({
      active: false, ended: true, scheduled: true, season: 2026, country: "World",
    });
    expect(payload.leagues.find((l) => l.id === 39)).toMatchObject({
      active: true, ended: false, scheduled: true, country: "England",
    });
    expect(payload.leagues.find((l) => l.id === 61)).toMatchObject({ active: true, scheduled: false, season: null });

    // Scheduled leagues get teams; the not-scheduled one is empty and never fetched.
    expect(payload.teams["1"]).toHaveLength(1);
    expect(payload.teams["61"]).toEqual([]);
    expect(provider.teamsForLeague).not.toHaveBeenCalledWith(61, expect.anything());
  });

  it("publishes catalog.json and returns counts", async () => {
    const provider = fakeProvider();
    const r2 = { putJson: vi.fn().mockResolvedValue(undefined) };
    const svc = new CatalogService(provider, r2 as never);

    const result = await svc.sync();

    expect(r2.putJson).toHaveBeenCalledWith("catalog.json", expect.objectContaining({ leagues: expect.any(Array) }), "public, max-age=43200");
    expect(result).toEqual({ leagues: 6, teams: 5 }); // 5 scheduled leagues × 1 team each
  });
});
