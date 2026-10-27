import { createHash } from "node:crypto";
import { z } from "zod";

const id = z.number().int().positive().max(Number.MAX_SAFE_INTEGER);
const count = z.number().int().min(0).max(100);
const minute = z.number().int().min(0).max(300).nullable();
const extra = z.number().int().min(0).max(60).nullable();
const name = z.string().max(256);
const timing = z.object({ minute, extra, player: name.nullable().optional() });
const team = z.object({
  id, name, goals: count, yellowCards: count, redCards: count,
  goalEvents: z.array(timing.extend({ kind: name.nullable().optional() })).max(100),
  yellowCardEvents: z.array(timing).max(100), redCardEvents: z.array(timing).max(100),
  subs: z.array(z.object({ minute, extra, playerIn: name.nullable(), playerOut: name.nullable() })).max(100).default([]),
});
export const matchSchema = z.object({
  fixtureId: id, leagueId: id, kickoffISO: z.string().datetime({ offset: true }),
  status: z.enum(["SCHEDULED", "LIVE", "HALF_TIME", "FINISHED", "OTHER"]),
  rawStatus: z.string().max(16), minute, extra, home: team, away: team,
  varEvents: z.array(timing.extend({ teamId: id.nullable(), detail: name })).max(100).default([]),
  shootout: z.object({ home: count, away: count, kicks: z.array(z.object({
    teamId: id, player: name.nullable(), scored: z.boolean(),
  })).max(200) }).optional(),
});
export type Match = z.infer<typeof matchSchema>;
export const eventTypes = ["KICKOFF", "GOAL", "GOAL_CANCELLED", "VAR_DECISION", "YELLOW_CARD", "RED_CARD", "SUBSTITUTION",
  "HALF_TIME", "SECOND_HALF", "EXTRA_TIME", "PENALTY_SHOOTOUT", "PENALTY_KICK", "FULL_TIME"] as const;
export type EventType = typeof eventTypes[number];
const token = z.string().regex(/^[a-f0-9]{32,512}$/).refine(s => s.length % 2 === 0);
export const registrationSchema = z.object({
  deviceToken: token.nullable(),
  teamIds: z.array(id).max(512),
  eventTypes: z.array(z.enum(eventTypes)).max(eventTypes.length),
  alertsEnabled: z.boolean(),
  activities: z.array(z.object({
    id: z.string().min(1).max(128), fixtureId: id, token,
  }).strict()).max(8),
}).strict();
export type Registration = z.infer<typeof registrationSchema>;
export interface Installation extends Registration {
  id: string; topics: string[]; updatedAt: number; alertsSince?: number; expiresAt: number;
}
export interface MatchRecord {
  snapshot: Match; observedAt: number; heartbeatAt: number; revision: number;
}
export interface Delivery {
  id: string; version: string; installationId: string; token: string;
  kind: "alert" | "liveactivity"; fixtureId: number;
  payload: Record<string, unknown>; priority: 5 | 10; collapseId: string;
  expiresAt: number; nextAttempt: number; attempts: number;
}
export const hash = (value: string) => createHash("sha256").update(value).digest("hex");
export const scoreText = (m: Match) => m.shootout
  ? `${m.home.goals} (${m.shootout.home}) – ${m.away.goals} (${m.shootout.away})`
  : `${m.home.goals} – ${m.away.goals}`;
export function contentState(m: Match, now: number) {
  return {
    score: scoreText(m),
    clock: m.status === "FINISHED" ? "Full-time" : m.status === "HALF_TIME" ? "Half-time"
      : m.status === "OTHER" ? "Match interrupted" : m.minute == null ? "Live"
      : `${m.minute}${m.extra ? `+${m.extra}` : ""}′`,
    // Swift JSONDecoder's default Date representation is seconds since 2001, not Unix.
    updatedAt: now / 1000 - 978307200,
    finished: m.status === "FINISHED" || m.status === "OTHER",
  };
}
export function topicsFor(r: Registration): string[] {
  return [...new Set([
    ...(r.alertsEnabled && r.deviceToken ? r.teamIds.map(id => `team:${id}`) : []),
    ...r.activities.map(a => `match:${a.fixtureId}`),
  ])];
}
export function topicsForMatch(m: Match) { return [`team:${m.home.id}`, `team:${m.away.id}`, `match:${m.fixtureId}`]; }
export function isTerminal(m: Match) { return m.status === "FINISHED" || m.status === "OTHER"; }
