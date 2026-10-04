import { z } from "zod";

// Match the native client's generous bounds at the publication boundary, so
// malformed upstream scores cannot reach older installed clients either.
const id = z.number().int().positive().max(Number.MAX_SAFE_INTEGER);
const count = z.number().int().min(0).max(100);
const minute = z.number().int().min(0).max(300).nullable();
const extra = z.number().int().min(0).max(60).nullable();
const name = z.string().max(256);
const timing = z.object({ minute, extra }).passthrough();
const team = z.object({
  id, name, goals: count, yellowCards: count, redCards: count,
  goalEvents: z.array(timing).max(100),
  yellowCardEvents: z.array(timing).max(100),
  redCardEvents: z.array(timing).max(100),
  subs: z.array(timing).max(100).optional(),
}).passthrough();

const match = z.object({
  fixtureId: id, leagueId: id,
  kickoffISO: z.string().datetime({ offset: true }),
  status: z.enum(["SCHEDULED", "LIVE", "HALF_TIME", "FINISHED", "OTHER"]),
  rawStatus: z.string().max(16), minute, extra,
  home: team, away: team,
  varEvents: z.array(timing).max(100).optional(),
  lastGoal: timing.optional(),
  shootout: z.object({
    home: count, away: count,
    kicks: z.array(z.object({ teamId: id, player: name.nullable(), scored: z.boolean() }).passthrough()).max(200),
  }).passthrough().optional(),
}).passthrough();

/** Validate without stripping additive fields from the published contract. */
export function assertSafeScoreObject(key: string, value: unknown): void {
  if (key.startsWith("matches/")) {
    const parsed = match.safeParse(value);
    if (!parsed.success || key !== `matches/${parsed.data.fixtureId}.json`) {
      throw new Error("Refusing to publish invalid match data");
    }
  } else if (key.startsWith("fixtures-")) {
    const parsed = z.object({ matches: z.array(match).max(512) }).safeParse(value);
    if (!/^fixtures-\d{4}-\d{2}-\d{2}\.json$/.test(key) || !parsed.success) {
      throw new Error("Refusing to publish invalid fixture data");
    }
  }
}
