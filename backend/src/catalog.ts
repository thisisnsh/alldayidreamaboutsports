import type { CatalogTeam, ScoreProvider } from "./providers/types.js";
import type { R2 } from "./r2.js";

/**
 * Which leagues the app knows about. `active` = users can follow it now;
 * everything else renders in the picker as "Coming soon". Adding a league here
 * (and flipping `active`) is the only change needed to support it — teams,
 * logos and current-season detection all come from the API.
 */
export interface SupportedLeague {
  id: number;
  active: boolean;
}

export const SUPPORTED_LEAGUES: SupportedLeague[] = [
  { id: 1, active: true }, // FIFA World Cup
  { id: 39, active: false }, // Premier League
  { id: 78, active: false }, // Bundesliga
  { id: 140, active: false }, // La Liga
  { id: 135, active: false }, // Serie A
  { id: 61, active: false }, // Ligue 1
];

export interface CatalogLeague {
  id: number;
  name: string;
  logo: string;
  type: string;
  active: boolean;
  scheduled: boolean;
  season: number | null;
}

export interface CatalogPayload {
  generatedAt: string;
  leagues: CatalogLeague[];
  teams: Record<string, CatalogTeam[]>; // leagueId -> teams
}

/**
 * Builds the leagues+teams catalog from the API and publishes it to the CDN.
 * Run daily by Cloud Scheduler (independent of the live-score poller, which
 * only runs during the active tournament window).
 */
export class CatalogService {
  constructor(
    private readonly provider: ScoreProvider,
    private readonly r2: R2,
  ) {}

  async build(): Promise<CatalogPayload> {
    const leagues: CatalogLeague[] = [];
    const teams: Record<string, CatalogTeam[]> = {};
    for (const { id, active } of SUPPORTED_LEAGUES) {
      const info = await this.provider.leagueInfo(id);
      leagues.push({ ...info, active });
      // Only the current/upcoming season's teams; nothing scheduled → no teams.
      teams[String(id)] =
        info.scheduled && info.season != null
          ? await this.provider.teamsForLeague(id, info.season)
          : [];
    }
    return { generatedAt: new Date().toISOString(), leagues, teams };
  }

  async sync(): Promise<{ leagues: number; teams: number }> {
    const payload = await this.build();
    await this.r2.putJson("catalog.json", payload, 86400);
    const teamCount = Object.values(payload.teams).reduce((n, t) => n + t.length, 0);
    return { leagues: payload.leagues.length, teams: teamCount };
  }
}
