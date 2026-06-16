import type { MatchEvent, MatchEventType, MatchState } from "./types.js";

/**
 * Pure diff engine: previous vs next state of one fixture → events to publish.
 * Event ids are deterministic so a poller retry recomputes the same ids and the
 * store layer can dedupe (publish-once guarantee lives in store.ts).
 */
export function diffMatch(prev: MatchState | null, next: MatchState): MatchEvent[] {
  // No previous state means the state file was deleted (or never written). If the
  // match is already over, treat it as already processed — don't re-fire historical
  // goals/cards/full-time. Same for a mid-match deletion: LIVE with no history
  // would otherwise re-emit all goals scored so far.
  if (prev === null && next.status === "FINISHED") return [];

  const events: MatchEvent[] = [];
  const base = {
    fixtureId: next.fixtureId,
    leagueId: next.leagueId,
    homeTeamId: next.home.id,
    awayTeamId: next.away.id,
    homeName: next.home.name,
    awayName: next.away.name,
    homeGoals: next.home.goals,
    awayGoals: next.away.goals,
  };
  const make = (
    type: MatchEventType,
    extra: Partial<MatchEvent> & { idSuffix?: string } = {},
  ): MatchEvent => {
    const { idSuffix, ...rest } = extra;
    return {
      ...base,
      type,
      eventId: `${next.fixtureId}:${type}${idSuffix ? `:${idSuffix}` : ""}`,
      ...rest,
    };
  };

  // Status transitions
  const was = prev?.status ?? "SCHEDULED";
  const wasRaw = prev?.rawStatus ?? "NS";
  if (was === "SCHEDULED" && next.status === "LIVE") {
    events.push(make("KICKOFF"));
  }
  if (next.rawStatus === "HT" && wasRaw !== "HT") {
    events.push(make("HALF_TIME"));
  }
  // Shootout tally, attached to the score-bearing end-of-match events below.
  const pens = next.shootout
    ? { penHome: next.shootout.home, penAway: next.shootout.away }
    : {};
  if (next.status === "FINISHED" && was !== "FINISHED") {
    events.push(make("FULL_TIME", pens));
  }
  // ET begins once; don't re-fire across the BT break between the two ET halves.
  if (next.rawStatus === "ET" && wasRaw !== "ET" && wasRaw !== "BT") {
    events.push(make("EXTRA_TIME"));
  }
  if (next.rawStatus === "P" && wasRaw !== "P") {
    events.push(make("PENALTY_SHOOTOUT", pens));
  }

  // Penalty shootout — one event per new kick, running tally computed from the
  // ordered kick list so ids are deterministic and the pill shows live scores.
  const prevKicks = prev?.shootout?.kicks.length ?? 0;
  const kicks = next.shootout?.kicks ?? [];
  let penHome = 0;
  let penAway = 0;
  for (let i = 0; i < kicks.length; i++) {
    const kick = kicks[i]!;
    if (kick.scored) {
      if (kick.teamId === next.home.id) penHome++;
      else penAway++;
    }
    if (i < prevKicks) continue; // already published
    events.push(
      make("PENALTY_KICK", {
        teamId: kick.teamId,
        player: kick.player,
        scored: kick.scored,
        penHome,
        penAway,
        idSuffix: String(i + 1),
      }),
    );
  }

  // Goals — one event per increment; decrements are VAR cancellations.
  for (const side of ["home", "away"] as const) {
    const before = prev?.[side].goals ?? 0;
    const after = next[side].goals;
    const team = next[side];
    for (let g = before + 1; g <= after; g++) {
      // The provider only advances the goal count once the matching scorer
      // event exists (see apiFootball goalCount), so goalEvents[g-1] is the
      // scorer. The team-name fallback only fires for a goal an unenriched
      // finished snapshot surfaced — so a GOAL is never emitted nameless.
      const goalEv = team.goalEvents?.[g - 1];
      events.push(
        make("GOAL", {
          teamId: team.id,
          player: goalEv?.player ?? team.name,
          minute: goalEv?.minute ?? next.minute,
          idSuffix: `${team.id}:${g}`,
        }),
      );
    }
    for (let g = before; g > after; g--) {
      events.push(
        make("GOAL_CANCELLED", {
          teamId: team.id,
          minute: next.minute,
          idSuffix: `${team.id}:${g}`,
        }),
      );
    }
  }

  // Cards — count-based; one event per new card.
  for (const side of ["home", "away"] as const) {
    const team = next[side];
    for (const [kind, evKey, type] of [
      ["yellowCards", "yellowCardEvents", "YELLOW_CARD"],
      ["redCards", "redCardEvents", "RED_CARD"],
    ] as const) {
      const before = prev?.[side][kind] ?? 0;
      for (let c = before + 1; c <= team[kind]; c++) {
        const cardEv = team[evKey][c - 1];
        events.push(
          make(type, {
            teamId: team.id,
            player: cardEv?.player ?? null,
            minute: cardEv?.minute ?? next.minute,
            idSuffix: `${team.id}:${c}`,
          }),
        );
      }
    }
  }

  return events;
}
