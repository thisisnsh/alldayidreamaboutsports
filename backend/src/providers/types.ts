import type { MatchState } from "../types.js";

/** A league's display info + which season (if any) is currently in play. */
export interface LeagueInfo {
  id: number;
  name: string;
  logo: string;
  type: string; // "Cup" | "League"
  /** Where it's played — "World" for international cups. */
  country: string | null;
  /** Current season (or the next scheduled one); null when nothing is on. */
  season: number | null;
  /** True when `season` is set — there's an ongoing or upcoming season. */
  scheduled: boolean;
  /** True when `season`'s end date has passed — the competition is over. */
  ended: boolean;
}

/** One team in the catalog, sourced from API-Football (logo is a CDN URL). */
export interface CatalogTeam {
  id: number; // stable global team id — the canonical identity
  code: string | null; // API 3-letter code (not always a FIFA trigram; null for some clubs)
  name: string;
  country: string | null;
  logo: string;
  leagueId: number;
}

/** Swappable data source (API-Football primary; football-data.org fallback later). */
export interface ScoreProvider {
  fixturesForRange(fromISO: string, toISO: string): Promise<MatchState[]>;
  /** League info + current/upcoming season, for the daily catalog. */
  leagueInfo(leagueId: number): Promise<LeagueInfo>;
  /** All teams in a league's season, with logos. */
  teamsForLeague(leagueId: number, season: number): Promise<CatalogTeam[]>;
}
