import type { EventType, Match } from "./model.js";

export interface MatchEvent { id: string; type: EventType; title: string; detail?: string }
/** Deterministic IDs match the native diff. First observations are seeded by the caller. */
export function diff(previous: Match, next: Match): MatchEvent[] {
  const events: MatchEvent[] = [];
  const add = (type: EventType, title: string, suffix?: string, detail?: string) => {
    events.push({ id: `${next.fixtureId}:${type}${suffix ? `:${suffix}` : ""}`, type, title, ...(detail ? { detail } : {}) });
  };
  if (previous.status === "SCHEDULED" && next.status === "LIVE") add("KICKOFF", "Kickoff");
  if (previous.rawStatus !== "HT" && next.rawStatus === "HT") add("HALF_TIME", "Half-time");
  if (previous.rawStatus === "HT" && next.rawStatus === "2H") add("SECOND_HALF", "Second half");
  if (previous.status !== "FINISHED" && next.status === "FINISHED") add("FULL_TIME", "Full-time");
  if (!["ET", "BT"].includes(previous.rawStatus) && next.rawStatus === "ET") add("EXTRA_TIME", "Extra time");
  if (previous.rawStatus !== "P" && next.rawStatus === "P") add("PENALTY_SHOOTOUT", "Penalty shootout");
  for (const side of ["home", "away"] as const) {
    const before = previous[side], after = next[side];
    for (let n = before.goals + 1; n <= after.goals; n++) {
      const goal = after.goalEvents[n - 1];
      const label = goal?.kind === "own" ? "Own goal" : goal?.kind === "penalty" ? "Penalty goal" : "Goal";
      add("GOAL", `${label} · ${after.name}`, `${after.id}:${n}`, goal?.player ?? undefined);
    }
    for (let n = before.goals; n > after.goals; n--) add("GOAL_CANCELLED", `Goal disallowed · ${after.name}`, `${after.id}:${n}`);
    for (const [field, rows, type, label] of [
      ["yellowCards", "yellowCardEvents", "YELLOW_CARD", "Yellow card"],
      ["redCards", "redCardEvents", "RED_CARD", "Red card"],
    ] as const) {
      for (let n = before[field] + 1; n <= after[field]; n++) {
        add(type, `${label} · ${after.name}`, `${after.id}:${n}`, after[rows][n - 1]?.player ?? undefined);
      }
    }
    // Missing event arrays in a later CDN file must not generate new events when restored.
    for (let n = before.subs.length; n < after.subs.length; n++) {
      const sub = after.subs[n]!;
      add("SUBSTITUTION", `Substitution · ${after.name}`, `${after.id}:${n + 1}`,
        [sub.playerIn, sub.playerOut ? `for ${sub.playerOut}` : null].filter(Boolean).join(" "));
    }
  }
  for (let n = previous.varEvents.length; n < next.varEvents.length; n++) {
    const v = next.varEvents[n]!;
    // Avoid announcing delayed, backfilled VAR outcomes as current incidents.
    if (v.minute != null && next.minute != null && next.minute - v.minute > 3) continue;
    add("VAR_DECISION", "VAR", String(n + 1), v.detail);
  }
  for (let n = previous.shootout?.kicks.length ?? 0; n < (next.shootout?.kicks.length ?? 0); n++) {
    const kick = next.shootout!.kicks[n]!;
    add("PENALTY_KICK", kick.scored ? "Penalty scored" : "Penalty missed", String(n + 1), kick.player ?? undefined);
  }
  return events.length <= 64 ? events : [];
}

export function mergeHistory(previous: Match | undefined, next: Match): Match {
  if (!previous) return next;
  const merged = structuredClone(next);
  for (const side of ["home", "away"] as const) {
    for (const key of ["goalEvents", "yellowCardEvents", "redCardEvents", "subs"] as const) {
      if (previous[side][key].length > next[side][key].length) {
        // Preserve the typed arrays without widening their different element types.
        Object.assign(merged[side], { [key]: previous[side][key] });
      }
    }
  }
  if (previous.varEvents.length > next.varEvents.length) merged.varEvents = previous.varEvents;
  return merged;
}
export function regresses(previous: Match, next: Match) {
  return (previous.status === "FINISHED" && next.status !== "FINISHED")
    || (["LIVE", "HALF_TIME"].includes(previous.status) && next.status === "SCHEDULED")
    || previous.home.id !== next.home.id || previous.away.id !== next.away.id;
}
