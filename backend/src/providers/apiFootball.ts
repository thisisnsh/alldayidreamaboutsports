import { teamCodeForName } from "../teams.js";
import type { MatchState, MatchStatus } from "../types.js";
import type { ScoreProvider } from "./types.js";

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

interface ApiFixture {
  fixture: { id: number; date: string; status: { short: string; elapsed: number | null } };
  league: { id: number; season: number };
  teams: { home: { id: number; name: string }; away: { id: number; name: string } };
  goals: { home: number | null; away: number | null };
  events?: Array<{
    time: { elapsed: number | null };
    team: { id: number; name: string };
    player: { name: string | null };
    type: string;
    detail: string;
  }>;
}

export class ApiFootballProvider implements ScoreProvider {
  constructor(
    private readonly apiKey: string,
    private readonly leagueId: number,
    private readonly season: number,
    private readonly fetchImpl: typeof fetch = fetch,
  ) {}

  private async get(path: string): Promise<ApiFixture[]> {
    const res = await this.fetchImpl(`${BASE}${path}`, {
      headers: { "x-apisports-key": this.apiKey },
    });
    if (!res.ok) throw new Error(`API-Football ${path} -> HTTP ${res.status}`);
    const body = (await res.json()) as { response?: ApiFixture[]; errors?: unknown };
    if (!Array.isArray(body.response)) {
      throw new Error(`API-Football ${path} -> bad body: ${JSON.stringify(body.errors ?? body).slice(0, 300)}`);
    }
    return body.response;
  }

  async liveMatches(): Promise<MatchState[]> {
    const fixtures = await this.get(`/fixtures?live=all&league=${this.leagueId}&season=${this.season}`);
    return fixtures.map((f) => this.toState(f));
  }

  async fixturesForDate(dateISO: string): Promise<MatchState[]> {
    const fixtures = await this.get(
      `/fixtures?league=${this.leagueId}&season=${this.season}&date=${dateISO}`,
    );
    return fixtures.map((f) => this.toState(f));
  }

  private toState(f: ApiFixture): MatchState {
    const homeCode = teamCodeForName(f.teams.home.name);
    const awayCode = teamCodeForName(f.teams.away.name);
    const cards = { home: { yellow: 0, red: 0 }, away: { yellow: 0, red: 0 } };
    let lastGoal: MatchState["lastGoal"];

    for (const ev of f.events ?? []) {
      const side = ev.team.id === f.teams.home.id ? "home" : "away";
      if (ev.type === "Card") {
        if (ev.detail.startsWith("Yellow")) cards[side].yellow++;
        else if (ev.detail.startsWith("Red")) cards[side].red++;
      } else if (ev.type === "Goal" && !/cancell/i.test(ev.detail)) {
        lastGoal = {
          teamCode: side === "home" ? homeCode : awayCode,
          player: ev.player?.name ?? null,
          minute: ev.time.elapsed,
        };
      }
    }

    return {
      fixtureId: f.fixture.id,
      leagueId: f.league.id,
      season: f.league.season,
      kickoffISO: f.fixture.date,
      status: STATUS_MAP[f.fixture.status.short] ?? "OTHER",
      rawStatus: f.fixture.status.short,
      minute: f.fixture.status.elapsed,
      home: {
        code: homeCode,
        name: f.teams.home.name,
        goals: f.goals.home ?? 0,
        yellowCards: cards.home.yellow,
        redCards: cards.home.red,
      },
      away: {
        code: awayCode,
        name: f.teams.away.name,
        goals: f.goals.away ?? 0,
        yellowCards: cards.away.yellow,
        redCards: cards.away.red,
      },
      lastGoal,
    };
  }
}
