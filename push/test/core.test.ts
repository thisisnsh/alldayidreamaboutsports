import { describe, expect, it, vi } from "vitest";
import { CDN } from "../src/cdn.js";
import { classify } from "../src/apns.js";
import { diff, mergeHistory } from "../src/events.js";
import { contentState, matchSchema, registrationSchema, topicsFor, type Installation, type Match, type MatchRecord } from "../src/model.js";
import { plan } from "../src/planner.js";

const now = 1_800_000_000_000;
function match(): Match {
  const team = (id: number, name: string) => ({ id, name, goals: 0, yellowCards: 0, redCards: 0, goalEvents: [], yellowCardEvents: [], redCardEvents: [], subs: [] });
  return { fixtureId: 123, leagueId: 39, kickoffISO: new Date(now - 3_600_000).toISOString(), status: "LIVE", rawStatus: "2H", minute: 70, extra: null,
    home: team(1, "Home"), away: team(2, "Away"), varEvents: [] };
}
function record(m = match()): MatchRecord { return { snapshot: m, observedAt: now - 5000, heartbeatAt: now - 5000, revision: 1 }; }
function subscriber(): Installation {
  return { id: "installation", deviceToken: "a".repeat(64), teamIds: [1], eventTypes: ["GOAL", "GOAL_CANCELLED", "FULL_TIME"],
    alertsEnabled: true, activities: [{ id: "activity", fixtureId: 123, token: "b".repeat(64) }], topics: ["team:1", "match:123"], updatedAt: now - 60_000, expiresAt: now + 86_400_000 };
}
function goal(): Match { const m = match(); m.home.goals = 1; m.home.goalEvents = [{ minute: 70, extra: null, player: "Scorer" }]; return m; }

describe("delivery policy", () => {
  it("seeds without announcing historical goals", () => {
    const result = plan(undefined, goal(), [subscriber()], now)!;
    expect(result.deliveries.map(d => d.kind)).toEqual(["liveactivity"]);
    expect(result.deliveries[0]!.priority).toBe(5);
  });
  it("sends a full score and a separate goal alert at high priority", () => {
    const result = plan(record(), goal(), [subscriber()], now)!;
    expect(result.deliveries.map(d => [d.kind, d.priority])).toEqual([["liveactivity", 10], ["alert", 10]]);
    expect(result.deliveries[1]!.payload.eventId).toBe("123:GOAL:1:1");
    expect(result.deliveries[0]!.payload).toMatchObject({ aps: { event: "update", "content-state": { score: "1 – 0" } } });
    expect(result.deliveries[0]!.collapseId).not.toBe(result.deliveries[1]!.collapseId);
  });
  it("does not send every clock tick; sends a low priority freshness heartbeat", () => {
    const next = match(); next.minute = 71;
    expect(plan(record(), next, [subscriber()], now)!.deliveries).toEqual([]);
    expect(plan({ ...record(), heartbeatAt: now - 60_000 }, next, [subscriber()], now)!.deliveries[0]!.priority).toBe(5);
  });
  it("suppresses alert replay after a polling outage", () => {
    const result = plan({ ...record(), observedAt: now - 100_000 }, goal(), [subscriber()], now)!;
    expect(result.deliveries.every(d => d.kind === "liveactivity")).toBe(true);
  });
  it("ends finished activities and preserves final score", () => {
    const m = goal(); m.status = "FINISHED"; m.rawStatus = "FT";
    const result = plan(record(), m, [subscriber()], now)!;
    expect(result.deliveries[0]!.payload).toMatchObject({ aps: { event: "end", "dismissal-date": now / 1000 + 3600,
      "content-state": { finished: true, clock: "Full-time", score: "1 – 0" } } });
  });
  it("handles a disallowed goal then a re-awarded goal", () => {
    expect(diff(goal(), match())[0]!.type).toBe("GOAL_CANCELLED");
    expect(diff(match(), goal())[0]!.type).toBe("GOAL");
    const first = plan(record(), goal(), [subscriber()], now)!;
    const again = plan({ ...record(), revision: 3 }, goal(), [subscriber()], now + 5000)!;
    expect(first.deliveries[1]!.id).not.toBe(again.deliveries[1]!.id);
  });
  it("keeps distinct events in distinct notification delivery records", () => {
    const m = goal(); m.away.goals = 1;
    const deliveries = plan(record(), m, [subscriber()], now)!.deliveries.filter(d => d.kind === "alert");
    expect(deliveries).toHaveLength(2);
    expect(new Set(deliveries.map(d => d.collapseId)).size).toBe(2);
  });
  it("respects disabled alerts, event preferences, expiry and team membership", () => {
    for (const sub of [{ ...subscriber(), alertsEnabled: false }, { ...subscriber(), eventTypes: [] },
      { ...subscriber(), teamIds: [99] }, { ...subscriber(), expiresAt: now - 1 }]) {
      expect(plan(record(), goal(), [sub], now)!.deliveries.some(d => d.kind === "alert")).toBe(false);
    }
  });
  it("doesn't alert a new subscriber about a previous event", () => {
    expect(plan(record(), goal(), [{ ...subscriber(), updatedAt: now }], now)!.deliveries.some(d => d.kind === "alert")).toBe(false);
  });
  it("rejects scheduled regressions, finished regressions, swapped teams and old observations", () => {
    expect(plan(record(), { ...match(), status: "SCHEDULED" }, [], now)).toBeNull();
    expect(plan(record({ ...match(), status: "FINISHED" }), match(), [], now)).toBeNull();
    expect(plan(record(), { ...match(), home: { ...match().home, id: 99 } }, [], now)).toBeNull();
    expect(plan(record(), match(), [], now - 6000)).toBeNull();
  });
  it("uses Swift's reference-date encoding in content state and Unix time in APNs metadata", () => {
    expect(contentState(match(), now).updatedAt + 978307200).toBe(now / 1000);
    expect((plan(undefined, match(), [subscriber()], now)!.deliveries[0]!.payload.aps as Record<string, unknown>).timestamp).toBe(now / 1000);
  });
  it("preserves event history across truncated CDN arrays", () => {
    const old = goal(); old.home.subs = [{ minute: 60, extra: null, playerIn: "A", playerOut: "B" }];
    const merged = mergeHistory(old, match());
    expect(merged.home.goalEvents).toHaveLength(1);
    expect(merged.home.subs).toHaveLength(1);
    expect(diff(merged, old).filter(e => e.type === "SUBSTITUTION")).toEqual([]);
  });
});

describe("input and network boundaries", () => {
  it("requires bounded scores, correct tokens and known event types", () => {
    expect(() => matchSchema.parse({ ...match(), home: { ...match().home, goals: 101 } })).toThrow();
    const { id, topics, updatedAt, expiresAt, ...registration } = subscriber();
    expect(registrationSchema.safeParse(registration).success).toBe(true);
    expect(registrationSchema.safeParse({ ...registration, deviceToken: "bad" }).success).toBe(false);
    expect(registrationSchema.safeParse({ ...registration, eventTypes: ["UNKNOWN"] }).success).toBe(false);
    expect(topicsFor({ ...registration, alertsEnabled: false })).toEqual(["match:123"]);
  });
  it("uses CDN paths without cache busting and refuses mismatched fixture IDs", async () => {
    const fetcher = vi.fn(async () => new Response(JSON.stringify(match())));
    const cdn = new CDN("https://scores.alldayidreamaboutsports.com", fetcher as typeof fetch);
    await expect(cdn.match(999)).rejects.toThrow("Wrong fixture");
    expect(fetcher.mock.calls[0]).toMatchObject(["https://scores.alldayidreamaboutsports.com/matches/999.json", { redirect: "error" }]);
  });
  it("bounds chunked CDN bodies and rejects redirects via fetch policy", async () => {
    const cdn = new CDN("https://scores.alldayidreamaboutsports.com", vi.fn(async () => new Response("x".repeat(2_000_001))) as typeof fetch);
    await expect(cdn.match(123)).rejects.toThrow("too large");
  });
  it("treats a missing match as missing, not a zero score", async () => {
    const cdn = new CDN("https://scores.alldayidreamaboutsports.com", vi.fn(async () => new Response(null, { status: 404 })) as typeof fetch);
    expect(await cdn.match(123)).toBeNull();
  });
  it.each([
    [200, undefined, "ok"], [410, "Unregistered", "invalid-token"], [400, "BadDeviceToken", "invalid-token"],
    [429, undefined, "retry"], [500, undefined, "retry"], [0, undefined, "retry"],
    [403, "ExpiredProviderToken", "retry"], [403, "InvalidProviderToken", "permanent"], [413, undefined, "permanent"],
  ])("classifies APNs %s/%s", (status, reason, expected) => { expect(classify({ status, reason })).toBe(expected); });
});
