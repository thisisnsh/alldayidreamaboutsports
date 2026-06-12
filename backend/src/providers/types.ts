import type { MatchState } from "../types.js";

/** Swappable data source (API-Football primary; football-data.org fallback later). */
export interface ScoreProvider {
  liveMatches(): Promise<MatchState[]>;
  fixturesForDate(dateISO: string): Promise<MatchState[]>;
}
