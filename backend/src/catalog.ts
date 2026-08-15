import type { CatalogTeam, ScoreProvider } from "./providers/types.js";
import { CACHE_CONTROL_LONG, type R2 } from "./r2.js";
import { log } from "./log.js";

/**
 * Which leagues the app knows about. `active` = users can follow it now;
 * everything else renders in the picker as "Coming soon" (or "Ended", when the
 * league's season is over — see `CatalogLeague.ended`). Adding a league here
 * (and flipping `active`) is the only change needed to support it — teams,
 * logos and current-season detection all come from the API.
 *
 * The World Cup stays listed but inactive: archived rather than deleted, so a
 * saved national team still resolves to a name and crest.
 */
export interface SupportedLeague {
  id: number;
  active: boolean;
}

export const SUPPORTED_LEAGUES: SupportedLeague[] = [
  { id: 1, active: false }, // FIFA World Cup — archived
  { id: 39, active: true }, // Premier League
  { id: 140, active: true }, // La Liga
  { id: 135, active: true }, // Serie A
  { id: 78, active: true }, // Bundesliga
  { id: 61, active: true }, // Ligue 1
];

export interface CatalogLeague {
  id: number;
  name: string;
  logo: string;
  type: string;
  /** Country the league is played in ("World" for international cups). */
  country: string | null;
  active: boolean;
  scheduled: boolean;
  /** True when the league's season is over — archived, never polled. */
  ended: boolean;
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
    const started = Date.now();
    log.info("catalog_build_start", { supportedLeagues: SUPPORTED_LEAGUES.map((league) => league.id) });
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
      log.info("catalog_league_complete", {
        leagueId: id, active, scheduled: info.scheduled, ended: info.ended,
        season: info.season, teams: teams[String(id)]!.length,
      });
    }
    log.info("catalog_build_complete", { leagues: leagues.length, durationMs: Date.now() - started });
    return { generatedAt: new Date().toISOString(), leagues, teams };
  }

  async sync(): Promise<{ leagues: number; teams: number }> {
    const payload = await this.build();
    await this.r2.putJson("catalog.json", payload, CACHE_CONTROL_LONG);
    const teamCount = Object.values(payload.teams).reduce((n, t) => n + t.length, 0);
    log.info("catalog_sync_complete", { leagues: payload.leagues.length, teams: teamCount });
    return { leagues: payload.leagues.length, teams: teamCount };
  }
}
