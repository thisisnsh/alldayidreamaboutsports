import type { GoalEvent, MatchState, MatchStatus, PenaltyKick, Period, SubEvent, VarEvent } from "../types.js";
import type { CatalogTeam, LeagueInfo, ScoreProvider } from "./types.js";
import { log } from "../log.js";
import { readRemoteJson } from "../remoteJson.js";

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

/** Trimmed player name, or null when the feed sends empty/whitespace/absent —
 * API-Football sometimes emits `""`/`null` names on live events before the
 * scorer/carded player is filled in. Normalizing here keeps a nameless GOAL
 * from rendering a blank subject downstream. */
function playerName(name: string | null | undefined): string | null {
  const trimmed = name?.trim();
  return trimmed ? trimmed : null;
}

/**
 * Map the API-Football short code (+ elapsed for the two ET halves) to a
 * fine-grained `Period`. ET is cumulative (91→105 first half, 106→120 second),
 * so the split is on `elapsed <= 105` per §1.
 * "BT" (Break Time) shows up at THREE distinct pauses, split by elapsed:
 * • ET setup break (or a null-elapsed blip) at ≤90' → BREAK ("BT")
 * • the pause between the two ET halves (~91–105') → EXTRA_BREAK ("ET HT")
 * • the pause after ET while the shootout is set up (>105') → PENALTIES.
 */
function derivePeriod(short: string, elapsed: number | null): Period {
  switch (short) {
    case "1H": return "FIRST";
    case "HT": return "HALF";
    case "2H": return "SECOND";
    case "ET": return (elapsed ?? 0) <= 105 ? "EXTRA_FIRST" : "EXTRA_SECOND";
    case "BT":
      if (elapsed == null || elapsed <= 90) return "BREAK";
      return elapsed <= 105 ? "EXTRA_BREAK" : "PENALTIES";
    case "P": return "PENALTIES";
    case "NS":
    case "TBD": return "PRE";
    case "FT":
    case "AET":
    case "PEN": return "FINISHED";
    default: return "OTHER"; // INT, LIVE (generic), postponed, cancelled, ...
  }
}

function hasErrors(errors: unknown): boolean {
  if (errors == null) return false;
  if (Array.isArray(errors)) return errors.length > 0;
  if (typeof errors === "object") return Object.keys(errors).length > 0;
  return Boolean(errors);
}

interface ApiLeague {
  league: { id: number; name: string; type: string; logo: string };
  country?: { name: string | null };
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
    status: { short: string; elapsed: number | null; extra: number | null };
  };
  league: { id: number; season: number; round: string };
  teams: { home: { id: number; name: string }; away: { id: number; name: string } };
  goals: { home: number | null; away: number | null };
  score?: { penalty?: { home: number | null; away: number | null } };
  events?: Array<{
    time: { elapsed: number | null; extra: number | null };
    team: { id: number; name: string };
    player: { name: string | null };
    /** For `subst`: the player coming ON. For a `Goal`: the assist provider. */
    assist?: { name: string | null };
    type: string;
    detail: string;
    comments?: string | null;
  }>;
}

export class ApiFootballProvider implements ScoreProvider {
  constructor(
    private readonly apiKey: string,
    private readonly fetchImpl: typeof fetch = fetch,
  ) {}

  private async get<T>(path: string): Promise<T[]> {
    const started = Date.now();
    log.debug("provider_request_start", { provider: "api-football", path });
    try {
      const res = await this.fetchImpl(`${BASE}${path}`, {
        headers: { "x-apisports-key": this.apiKey },
        signal: AbortSignal.timeout(10_000),
        redirect: "error",
      });
      if (!res.ok) throw new Error(`API-Football ${path} -> HTTP ${res.status}`);
      const body = (await readRemoteJson(res)) as { response?: T[]; errors?: unknown };
      // API-Football reports quota/auth/parameter failures as HTTP 200 with
      // a non-empty `errors` (object or array) and an empty `response`. Taking
      // that as "no fixtures" would overwrite the published schedule with
      // empty days, so it must fail the whole pass instead.
      if (hasErrors(body.errors)) {
        throw new Error(`API-Football ${path} -> errors: ${JSON.stringify(body.errors).slice(0, 300)}`);
      }
      if (!Array.isArray(body.response)) {
        throw new Error(`API-Football ${path} -> bad body: ${JSON.stringify(body.errors ?? body).slice(0, 300)}`);
      }
      if (body.response.length > 2048) throw new Error("API-Football response exceeds row limit");
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

  async fixturesForRange(
    leagueId: number,
    season: number,
    fromISO: string,
    toISO: string,
  ): Promise<MatchState[]> {
    const fixtures = await this.get<ApiFixture>(
      `/fixtures?league=${leagueId}&season=${season}&from=${fromISO}&to=${toISO}&timezone=UTC`,
    );
    log.info("provider_fixture_range", {
      leagueId, season, fromISO, toISO, fixtures: fixtures.length,
    });
    // No enrichment here: the range endpoint omits events, but the live fixtures
    // of ALL leagues are enriched together by the caller (see fetchLeagueFixtures)
    // so a normal night costs one ids call instead of one per league.
    return fixtures.map((f) => this.toState(f));
  }

  async fixturesByIds(ids: number[]): Promise<MatchState[]> {
    if (ids.length === 0) return [];
    const fixtures = await this.get<ApiFixture>(`/fixtures?ids=${ids.join("-")}`);
    log.info("provider_fixtures_by_ids", { requested: ids.length, fixtures: fixtures.length });
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
    const seasonRow = current ?? upcoming;
    const season = seasonRow?.year ?? null;
    // `current` is not trustworthy for "is it over": API-Football still flagged
    // WC 2026 current a month after the final. The season's end date is.
    const ended = season != null && seasonRow!.end < today;
    return {
      id: row.league.id,
      name: row.league.name,
      type: row.league.type,
      logo: row.league.logo,
      country: row.country?.name ?? null,
      season,
      scheduled: season != null,
      ended,
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
    type EventRecord = { player: string | null; minute: number | null; extra: number | null };
    const cards = {
      home: { yellow: 0, red: 0, yellowEvents: [] as EventRecord[], redEvents: [] as EventRecord[] },
      away: { yellow: 0, red: 0, yellowEvents: [] as EventRecord[], redEvents: [] as EventRecord[] },
    };
    const goals = {
      home: [] as GoalEvent[],
      away: [] as GoalEvent[],
    };
    const subs = { home: [] as SubEvent[], away: [] as SubEvent[] };
    let lastGoal: MatchState["lastGoal"];
    const kicks: PenaltyKick[] = [];
    const varEvents: VarEvent[] = [];

    for (const ev of f.events ?? []) {
      const side = ev.team.id === f.teams.home.id ? "home" : "away";
      const teamId = side === "home" ? homeId : awayId;
      const isShootoutKick =
        ev.type === "Goal" && /penalt/i.test(ev.detail) && /shootout/i.test(ev.comments ?? "");
      if (ev.type === "Card") {
        const cardEv = { player: playerName(ev.player?.name), minute: ev.time.elapsed, extra: ev.time.extra ?? null };
        if (ev.detail.startsWith("Yellow")) { cards[side].yellow++; cards[side].yellowEvents.push(cardEv); }
        else if (ev.detail.startsWith("Red")) { cards[side].red++; cards[side].redEvents.push(cardEv); }
      } else if (ev.type === "subst") {
        // `player` = leaving the pitch, `assist` = coming on.
        subs[side].push({
          playerOut: playerName(ev.player?.name),
          playerIn: playerName(ev.assist?.name),
          minute: ev.time.elapsed,
          extra: ev.time.extra ?? null,
        });
      } else if (ev.type === "Var") {
        // Goal cancellations already surface as a score drop (→ GOAL_CANCELLED);
        // keep only the VAR outcomes that don't change the score.
        if (!/goal/i.test(ev.detail)) {
          varEvents.push({
            teamId, detail: ev.detail, player: playerName(ev.player?.name),
            minute: ev.time.elapsed, extra: ev.time.extra ?? null,
          });
        }
      } else if (isShootoutKick) {
        // Shootout kicks live in score.penalty (counts) + here (player/result).
        kicks.push({ teamId, player: playerName(ev.player?.name), scored: !/missed/i.test(ev.detail) });
      } else if (ev.type === "Goal" && !/cancell/i.test(ev.detail) && !/missed/i.test(ev.detail)) {
        // Skip "Missed Penalty" — it never increments the score and must not
        // steal scorer attribution from a later real goal.
        const kind: GoalEvent["kind"] =
          /own/i.test(ev.detail) ? "own" : /penalt/i.test(ev.detail) ? "penalty" : null;
        const goalEv: GoalEvent = {
          player: playerName(ev.player?.name), minute: ev.time.elapsed, extra: ev.time.extra ?? null,
        };
        // Only tag non-normal goals so a plain goal stays `{player,minute,extra}`.
        if (kind) goalEv.kind = kind;
        // API-Football attributes an event (own goals included) to the team that
        // BENEFITS: `ev.team` is the scoring side and `player` is whoever put it
        // in (for an own goal, an opponent's player). So credit `side` directly
        // — do NOT flip. Verified live on fixture 1565179: the 111' own goal's
        // event team was the benefiting side, and flipping it desynced the goal
        // count from the aggregate `f.goals`, sticking the score a goal behind.
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
    const short = f.fixture.status.short;
    const rawElapsed = f.fixture.status.elapsed;
    // Derive the fine-grained period from the RAW elapsed, before the clamp
    // below — the ET first/second-half split keys off the true minute (105).
    const period = derivePeriod(short, rawElapsed);
    // The clock only ticks during the three playing halves.
    const running = short === "1H" || short === "2H" || short === "ET";
    // API-Football normally caps `elapsed` at each period boundary and carries
    // stoppage in `extra`, but it sometimes lets `elapsed` OVERRUN the cap
    // (verified live: ET ran to 124'). Fold any overrun back into `extra` so the
    // clock reads `90+3` / `120+4` instead of an impossible `93'` / `124'`.
    const CAP: Record<string, number> = { "1H": 45, "2H": 90, "ET": 120 };
    const cap = CAP[short];
    let minute = rawElapsed;
    let extra = f.fixture.status.extra ?? null;
    if (cap != null && rawElapsed != null && rawElapsed > cap) {
      extra = (extra ?? 0) + (rawElapsed - cap);
      minute = cap;
    }
    // Aggregate-first scoring: publish the score straight from API-Football's
    // authoritative `goals` counter, the instant it moves, BOTH directions. The
    // scorer-attributed `events[]` lags the counter and transiently empties, so
    // deriving the count from it caused false 0-0 / stuck-score drops — events
    // are attribution metadata only, never the score. A real VAR disallow (the
    // aggregate genuinely drops and stays) thus also publishes instantly.
    const live = status === "LIVE" || status === "HALF_TIME";
    const goalCount = (side: "home" | "away") => f.goals[side] ?? 0;

    // Diagnostic for scorer-name LATENESS: fires whenever the aggregate leads
    // the scorer-attributed events[]. Now that the score no longer waits on the
    // scorer, this measures how long a published goal shows without a name (the
    // 10–20s the events pipeline lags), not a withheld goal.
    if (live) {
      for (const side of ["home", "away"] as const) {
        const aggregate = f.goals[side] ?? 0;
        if (aggregate > goals[side].length) {
          log.info("goal_attribution_pending", {
            fixtureId: f.fixture.id, side, aggregate, attributed: goals[side].length,
            minute, extra,
          });
        }
      }
    }
    // Goals glitch: live, a non-zero aggregate, but events[] empty
    // (their events pipeline dropped out). Now harmless to the score (aggregate-
    // first), but worth flagging so it stays auditable.
    if (live && (f.events?.length ?? 0) === 0 && ((f.goals.home ?? 0) + (f.goals.away ?? 0)) > 0) {
      log.warning("live_events_missing", {
        fixtureId: f.fixture.id,
        homeGoals: f.goals.home ?? 0, awayGoals: f.goals.away ?? 0, minute,
      });
    }

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
      rawStatus: short,
      minute,
      extra,
      period,
      running,
      home: {
        id: homeId,
        name: f.teams.home.name,
        goals: goalCount("home"),
        yellowCards: cards.home.yellow,
        redCards: cards.home.red,
        yellowCardEvents: cards.home.yellowEvents,
        redCardEvents: cards.home.redEvents,
        goalEvents: goals.home,
        subs: subs.home,
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
        subs: subs.away,
      },
      lastGoal,
      varEvents,
      shootout,
    };
  }
}
