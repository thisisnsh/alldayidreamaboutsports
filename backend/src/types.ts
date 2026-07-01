/**
 * Stable global team identity = API-Football's numeric team id (never null,
 * unique across leagues). Used as the celebration counter key.
 */
export type TeamId = number;

export type MatchStatus =
  | "SCHEDULED" // NS, TBD
  | "LIVE" // 1H, 2H, ET, BT, P, LIVE
  | "HALF_TIME" // HT
  | "FINISHED" // FT, AET, PEN
  | "OTHER"; // postponed, cancelled, ...

/**
 * Fine-grained match phase, derived from the API-Football short code (+ elapsed
 * for the two extra-time halves). The app renders the clock straight from this:
 * `running` decides whether to show a minute at all; the EXTRA_* phases keep
 * `45+2′`/`90+3′`/`105+1′`/`120+2′` correct.
 */
export type Period =
  | "PRE" // NS, TBD
  | "FIRST" // 1H
  | "HALF" // HT
  | "SECOND" // 2H
  | "EXTRA_FIRST" // ET, elapsed <= 105
  | "EXTRA_SECOND" // ET, elapsed > 105
  | "EXTRA_BREAK" // BT (break between ET halves)
  | "PENALTIES" // P (shootout)
  | "FINISHED" // FT, AET, PEN
  | "OTHER"; // INT, postponed, cancelled, ...

export interface CardEvent {
  player: string | null;
  minute: number | null;
  /** Stoppage-time minutes on top of `minute` (e.g. 3 in `90+3`); null otherwise. */
  extra: number | null;
}

/** A scored goal. `kind` distinguishes an own goal / penalty from a normal one. */
export interface GoalEvent extends CardEvent {
  kind?: "own" | "penalty" | null;
}

/** One substitution: `playerOut` leaves, `playerIn` comes on. */
export interface SubEvent {
  playerOut: string | null;
  playerIn: string | null;
  minute: number | null;
  extra: number | null;
}

/** A VAR review outcome (e.g. "Penalty confirmed", "Penalty awarded"). Goal
 * cancellations are excluded here — they surface via the score-drop diff. */
export interface VarEvent {
  teamId: TeamId;
  detail: string;
  player: string | null;
  minute: number | null;
  extra: number | null;
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
  /** Ordered list of goals scored; index 0 = first goal. Used by the diff to attach the scorer. */
  goalEvents: GoalEvent[];
  /** Ordered list of substitutions made by this team; index 0 = first. */
  subs?: SubEvent[];
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
  /** 2nd-half kickoff (API `periods.second`); used by the poller's recently-finished gate. */
  secondHalfStartISO?: string | null;
  status: MatchStatus;
  rawStatus: string; // API-Football short code (1H, HT, FT, ...)
  /** Authoritative elapsed minute (caps during stoppage; `extra` holds the overflow). */
  minute: number | null;
  /** Stoppage-time minutes (`status.extra`); null when not in added time. */
  extra: number | null;
  /** Fine-grained phase, used by the app to render the clock label. */
  period: Period;
  /** Whether the clock is ticking (1H/2H/ET) — false at HT/BT/PENS/FT/PRE. */
  running: boolean;
  home: TeamScore;
  away: TeamScore;
  /** Last scorer per side, when the provider exposes it. */
  lastGoal?: { teamId: TeamId; player: string | null; minute: number | null; extra: number | null };
  /** VAR review outcomes in order (penalty confirmed/awarded, card upgrade, …). */
  varEvents?: VarEvent[];
  /** Penalty shootout, present once the match reaches one (P/PEN). */
  shootout?: { home: number; away: number; kicks: PenaltyKick[] };
}
