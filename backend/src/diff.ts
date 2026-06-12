import type { MatchEvent, MatchEventType, MatchState } from "./types.js";

/**
 * Pure diff engine: previous vs next state of one fixture → events to publish.
 * Event ids are deterministic so a poller retry recomputes the same ids and the
 * store layer can dedupe (publish-once guarantee lives in store.ts).
 */
export function diffMatch(prev: MatchState | null, next: MatchState): MatchEvent[] {
  const events: MatchEvent[] = [];
  const base = {
    fixtureId: next.fixtureId,
    leagueId: next.leagueId,
    homeTeam: next.home.code,
    awayTeam: next.away.code,
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
  if (next.status === "FINISHED" && was !== "FINISHED") {
    events.push(make("FULL_TIME"));
  }
  if (next.rawStatus === "P" && wasRaw !== "P") {
    events.push(make("PENALTY_SHOOTOUT"));
  }

  // Goals — one event per increment; decrements are VAR cancellations.
  for (const side of ["home", "away"] as const) {
    const before = prev?.[side].goals ?? 0;
    const after = next[side].goals;
    const team = next[side];
    const scorer =
      next.lastGoal?.teamCode === team.code ? next.lastGoal : undefined;
    for (let g = before + 1; g <= after; g++) {
      events.push(
        make("GOAL", {
          teamCode: team.code,
          player: scorer?.player ?? null,
          minute: scorer?.minute ?? next.minute,
          idSuffix: `${team.code}:${g}`,
        }),
      );
    }
    for (let g = before; g > after; g--) {
      events.push(
        make("GOAL_CANCELLED", {
          teamCode: team.code,
          minute: next.minute,
          idSuffix: `${team.code}:${g}`,
        }),
      );
    }
  }

  // Cards — count-based; one event per new card.
  for (const side of ["home", "away"] as const) {
    const team = next[side];
    for (const [kind, type] of [
      ["yellowCards", "YELLOW_CARD"],
      ["redCards", "RED_CARD"],
    ] as const) {
      const before = prev?.[side][kind] ?? 0;
      for (let c = before + 1; c <= team[kind]; c++) {
        events.push(
          make(type, {
            teamCode: team.code,
            minute: next.minute,
            idSuffix: `${team.code}:${c}`,
          }),
        );
      }
    }
  }

  return events;
}
