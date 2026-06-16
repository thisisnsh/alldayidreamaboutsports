import type { MatchState, MatchStatus, PenaltyKick } from "../types.js";
import type { CatalogTeam, LeagueInfo, ScoreProvider } from "./types.js";
import { log } from "../log.js";

const BASE = "https://v3.football.api-sports.io";

const STATUS_MAP: Record<string, MatchStatus> = {
  TBD: "SCHEDULED",
  NS: "SCHEDULED",
  "1H": "LIVE",
  HT: "HALF_TIME",
  "2H": "LIVE",
  ET: "LIVE",
  BT: "LIVE",
  P: "LIVE",
  INT: "LIVE",
  LIVE: "LIVE",
  FT: "FINISHED",
  AET: "FINISHED",
  PEN: "FINISHED",
};

interface ApiLeague {
  league: { id: number; name: string; type: string; logo: string };
  seasons: Array<{ year: number; current: boolean; end: string }>;
}

interface ApiTeamRow {
  team: { id: number; name: string; code: string | null; country: string | null; logo: string };
}

interface ApiFixture {
  fixture: {
    id: number;
    date: string;
    periods?: { first: number | null; second: number | null };
    status: { short: string; elapsed: number | null };
  };
  league: { id: number; season: number; round: string };
  teams: { home: { id: number; name: string }; away: { id: number; name: string } };
  goals: { home: number | null; away: number | null };
  score?: { penalty?: { home: number | null; away: number | null } };
  events?: Array<{
    time: { elapsed: number | null };
    team: { id: number; name: string };
    player: { name: string | null };
    type: string;
    detail: string;
    comments?: string | null;
  }>;
}

export class ApiFootballProvider implements ScoreProvider {
  constructor(
    private readonly apiKey: string,
    private readonly leagueId: number,
    private readonly season: number,
    private readonly fetchImpl: typeof fetch = fetch,
  ) {}

  private async get<T>(path: string): Promise<T[]> {
    const started = Date.now();
    log.debug("provider_request_start", { provider: "api-football", path });
    try {
      const res = await this.fetchImpl(`${BASE}${path}`, {
        headers: { "x-apisports-key": this.apiKey },
      });
      if (!res.ok) throw new Error(`API-Football ${path} -> HTTP ${res.status}`);
      const body = (await res.json()) as { response?: T[]; errors?: unknown };
      if (!Array.isArray(body.response)) {
        throw new Error(`API-Football ${path} -> bad body: ${JSON.stringify(body.errors ?? body).slice(0, 300)}`);
      }
      log.info("provider_request_complete", {
        provider: "api-football", path, rows: body.response.length, durationMs: Date.now() - started,
      });
      return body.response;
    } catch (error) {
      log.error("provider_request_failed", error, {
        provider: "api-football", path, durationMs: Date.now() - started,
      });
      throw error;
    }
  }

  async fixturesForRange(fromISO: string, toISO: string): Promise<MatchState[]> {
    const fixtures = await this.get<ApiFixture>(
      `/fixtures?league=${this.leagueId}&season=${this.season}&from=${fromISO}&to=${toISO}&timezone=UTC`,
    );

    // The range endpoint omits events; enrich live fixtures via the ids endpoint (max 20/request).
    const liveStatuses = new Set(["1H", "HT", "2H", "ET", "BT", "P", "INT", "LIVE"]);
    const liveIds = fixtures
      .filter((f) => liveStatuses.has(f.fixture.status.short))
      .map((f) => f.fixture.id);
    log.info("provider_fixture_range", {
      fromISO, toISO, fixtures: fixtures.length, liveFixtureIds: liveIds,
    });

    if (liveIds.length > 0) {
      const enriched: ApiFixture[] = [];
      for (let i = 0; i < liveIds.length; i += 20) {
        const batch = liveIds.slice(i, i + 20);
        const rows = await this.get<ApiFixture>(`/fixtures?ids=${batch.join("-")}`);
        enriched.push(...rows);
      }
      const eventsById = new Map(enriched.map((f) => [f.fixture.id, f.events ?? []]));
      for (const f of fixtures) {
        const events = eventsById.get(f.fixture.id);
        if (events) f.events = events;
      }
    }

    return fixtures.map((f) => this.toState(f));
  }

  async leagueInfo(leagueId: number): Promise<LeagueInfo> {
    const [row] = await this.get<ApiLeague>(`/leagues?id=${leagueId}`);
    if (!row) throw new Error(`API-Football: no league ${leagueId}`);
    const current = row.seasons.find((s) => s.current);
    // No current season → the latest one whose end date is still in the future
    // counts as "to be scheduled" (e.g. a tournament drawn but not yet started).
    const today = new Date().toISOString().slice(0, 10);
    const upcoming = current ? undefined : [...row.seasons].reverse().find((s) => s.end >= today);
    const season = current?.year ?? upcoming?.year ?? null;
    return {
      id: row.league.id,
      name: row.league.name,
      type: row.league.type,
      logo: row.league.logo,
      season,
      scheduled: season != null,
    };
  }

  async teamsForLeague(leagueId: number, season: number): Promise<CatalogTeam[]> {
    const rows = await this.get<ApiTeamRow>(`/teams?league=${leagueId}&season=${season}`);
    return rows.map((r) => ({
      id: r.team.id,
      code: r.team.code,
      name: r.team.name,
      country: r.team.country,
      logo: r.team.logo,
      leagueId,
    }));
  }

  private toState(f: ApiFixture): MatchState {
    const homeId = f.teams.home.id;
    const awayId = f.teams.away.id;
    const cards = {
      home: { yellow: 0, red: 0, yellowEvents: [] as { player: string | null; minute: number | null }[], redEvents: [] as { player: string | null; minute: number | null }[] },
      away: { yellow: 0, red: 0, yellowEvents: [] as { player: string | null; minute: number | null }[], redEvents: [] as { player: string | null; minute: number | null }[] },
    };
    const goals = {
      home: [] as { player: string | null; minute: number | null }[],
      away: [] as { player: string | null; minute: number | null }[],
    };
    let lastGoal: MatchState["lastGoal"];
    const kicks: PenaltyKick[] = [];

    for (const ev of f.events ?? []) {
      const side = ev.team.id === f.teams.home.id ? "home" : "away";
      const teamId = side === "home" ? homeId : awayId;
      const isShootoutKick =
        ev.type === "Goal" && /penalt/i.test(ev.detail) && /shootout/i.test(ev.comments ?? "");
      if (ev.type === "Card") {
        const cardEv = { player: ev.player?.name ?? null, minute: ev.time.elapsed };
        if (ev.detail.startsWith("Yellow")) { cards[side].yellow++; cards[side].yellowEvents.push(cardEv); }
        else if (ev.detail.startsWith("Red")) { cards[side].red++; cards[side].redEvents.push(cardEv); }
      } else if (isShootoutKick) {
        // Shootout kicks live in score.penalty (counts) + here (player/result).
        kicks.push({ teamId, player: ev.player?.name ?? null, scored: !/missed/i.test(ev.detail) });
      } else if (ev.type === "Goal" && !/cancell/i.test(ev.detail) && !/missed/i.test(ev.detail)) {
        // Skip "Missed Penalty" — it never increments the score and must not
        // steal scorer attribution from a later real goal.
        const goalEv = { player: ev.player?.name ?? null, minute: ev.time.elapsed };
        goals[side].push(goalEv);
        lastGoal = { teamId, ...goalEv };
      }
    }

    const penHome = f.score?.penalty?.home;
    const penAway = f.score?.penalty?.away;
    const inShootout = f.fixture.status.short === "P" || f.fixture.status.short === "PEN";
    const shootout =
      inShootout || penHome != null || penAway != null || kicks.length > 0
        ? { home: penHome ?? 0, away: penAway ?? 0, kicks }
        : undefined;

    const status = STATUS_MAP[f.fixture.status.short] ?? "OTHER";
    // While a match is in play, API-Football bumps the aggregate `goals`
    // counter a poll or two BEFORE the matching event (with the scorer) lands
    // in `events[]`. Counting from the events list instead means a GOAL is only
    // emitted once its scorer is known — never with an empty/guessed name.
    // Finished matches aren't enriched with events, so fall back to the
    // authoritative aggregate (the scorers were already attributed while live).
    const live = status === "LIVE" || status === "HALF_TIME";
    const goalCount = (side: "home" | "away") =>
      live ? Math.min(f.goals[side] ?? 0, goals[side].length) : (f.goals[side] ?? 0);

    return {
      fixtureId: f.fixture.id,
      leagueId: f.league.id,
      season: f.league.season,
      round: f.league.round,
      kickoffISO: f.fixture.date,
      secondHalfStartISO: f.fixture.periods?.second
        ? new Date(f.fixture.periods.second * 1000).toISOString()
        : null,
      status,
      rawStatus: f.fixture.status.short,
      minute: f.fixture.status.elapsed,
      home: {
        id: homeId,
        name: f.teams.home.name,
        goals: goalCount("home"),
        yellowCards: cards.home.yellow,
        redCards: cards.home.red,
        yellowCardEvents: cards.home.yellowEvents,
        redCardEvents: cards.home.redEvents,
        goalEvents: goals.home,
      },
      away: {
        id: awayId,
        name: f.teams.away.name,
        goals: goalCount("away"),
        yellowCards: cards.away.yellow,
        redCards: cards.away.red,
        yellowCardEvents: cards.away.yellowEvents,
        redCardEvents: cards.away.redEvents,
        goalEvents: goals.away,
      },
      lastGoal,
      shootout,
    };
  }
}
