/**
 * Stable global team identity = API-Football's numeric team id (never null,
 * unique across leagues). Used in FCM topics as `l1_6`, as the celebration
 * counter key, and as the `fanOf` value.
 */
export type TeamId = number;

export type MatchStatus =
  | "SCHEDULED" // NS, TBD
  | "LIVE" // 1H, 2H, ET, BT, P, LIVE
  | "HALF_TIME" // HT
  | "FINISHED" // FT, AET, PEN
  | "OTHER"; // postponed, cancelled, ...

export interface CardEvent {
  player: string | null;
  minute: number | null;
}

export interface TeamScore {
  id: TeamId;
  name: string; // display name from the fixture (logo is resolved app-side via the catalog)
  goals: number;
  yellowCards: number;
  redCards: number;
  /** Ordered list of cards issued; index 0 = first card. Used by the diff to attach player + minute. */
  yellowCardEvents: CardEvent[];
  redCardEvents: CardEvent[];
}

/** One penalty-shootout kick, in the order it was taken. */
export interface PenaltyKick {
  teamId: TeamId;
  player: string | null;
  scored: boolean;
}

export interface MatchState {
  fixtureId: number;
  leagueId: number;
  season: number;
  /** Competition stage from API-Football's `league.round` (e.g. "Group A - 1", "Round of 16"). */
  round?: string;
  kickoffISO: string;
  status: MatchStatus;
  rawStatus: string; // API-Football short code (1H, HT, FT, ...)
  minute: number | null;
  home: TeamScore;
  away: TeamScore;
  /** Last scorer per side, when the provider exposes it. */
  lastGoal?: { teamId: TeamId; player: string | null; minute: number | null };
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
  teamId?: TeamId;
  player?: string | null;
  minute?: number | null;
  /** Penalty-shootout tally, carried on shootout/full-time events. */
  penHome?: number;
  penAway?: number;
  /** Whether a PENALTY_KICK was converted. */
  scored?: boolean;
  homeTeamId: TeamId;
  awayTeamId: TeamId;
  homeName: string;
  awayName: string;
  homeGoals: number;
  awayGoals: number;
}

export interface UserPrefs {
  fanOf: Record<string, Record<string, string[]>>; // game -> leagueId -> team ids (as strings)
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
