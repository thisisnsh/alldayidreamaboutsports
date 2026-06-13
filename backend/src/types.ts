/** FIFA trigram, e.g. "BRA", "ENG". Used in FCM topics as `l1_BRA`. */
export type TeamCode = string;

export type MatchStatus =
  | "SCHEDULED" // NS, TBD
  | "LIVE" // 1H, 2H, ET, BT, P, LIVE
  | "HALF_TIME" // HT
  | "FINISHED" // FT, AET, PEN
  | "OTHER"; // postponed, cancelled, ...

export interface TeamScore {
  code: TeamCode;
  name: string;
  goals: number;
  yellowCards: number;
  redCards: number;
}

/** One penalty-shootout kick, in the order it was taken. */
export interface PenaltyKick {
  teamCode: TeamCode;
  player: string | null;
  scored: boolean;
}

export interface MatchState {
  fixtureId: number;
  leagueId: number;
  season: number;
  kickoffISO: string;
  status: MatchStatus;
  rawStatus: string; // API-Football short code (1H, HT, FT, ...)
  minute: number | null;
  home: TeamScore;
  away: TeamScore;
  /** Last scorer per side, when the provider exposes it. */
  lastGoal?: { teamCode: TeamCode; player: string | null; minute: number | null };
  /** Penalty shootout, present once the match reaches one (P/PEN). */
  shootout?: { home: number; away: number; kicks: PenaltyKick[] };
}

export type MatchEventType =
  | "KICKOFF"
  | "GOAL"
  | "GOAL_CANCELLED"
  | "YELLOW_CARD"
  | "RED_CARD"
  | "HALF_TIME"
  | "FULL_TIME"
  | "EXTRA_TIME"
  | "PENALTY_SHOOTOUT"
  | "PENALTY_KICK";

export interface MatchEvent {
  /** Deterministic — identical recomputation yields the same id (idempotency). */
  eventId: string;
  type: MatchEventType;
  fixtureId: number;
  leagueId: number;
  /** Team the event belongs to (scoring/carded team); undefined for whole-match events. */
  teamCode?: TeamCode;
  player?: string | null;
  minute?: number | null;
  /** Penalty-shootout tally, carried on shootout/full-time events. */
  penHome?: number;
  penAway?: number;
  /** Whether a PENALTY_KICK was converted. */
  scored?: boolean;
  homeTeam: TeamCode;
  awayTeam: TeamCode;
  homeName: string;
  awayName: string;
  homeGoals: number;
  awayGoals: number;
}

export interface UserPrefs {
  fanOf: Record<string, Record<string, TeamCode[]>>; // game -> leagueId -> teams
  settings: {
    launchAtLogin?: boolean;
    theme?: "system" | "light" | "dark";
    notifications?: Record<string, boolean>;
  };
}

export const DEFAULT_PREFS: UserPrefs = {
  fanOf: { football: { "1": [] } },
  settings: {},
};
