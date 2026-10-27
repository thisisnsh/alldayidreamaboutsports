import { randomUUID } from "node:crypto";
import { diff, mergeHistory, regresses } from "./events.js";
import { contentState, hash, isTerminal, scoreText, type Delivery, type Installation, type Match, type MatchRecord } from "./model.js";

export interface Plan { record: MatchRecord; deliveries: Delivery[] }
export function plan(previous: MatchRecord | undefined, raw: Match, subscribers: Installation[], now: number): Plan | null {
  if (previous && (now <= previous.observedAt || regresses(previous.snapshot, raw))) return null;
  const next = mergeHistory(previous?.snapshot, raw);
  const old = previous?.snapshot;
  const revision = (previous?.revision ?? 0) + 1;
  const continuous = previous != null && now - previous.observedAt <= 90_000;
  const events = continuous ? diff(old!, next) : [];
  // Score/phase changes matter now. Clock-only changes are coalesced to a minute.
  const urgent = !!old && (scoreText(old) !== scoreText(next) || old.status !== next.status || old.rawStatus !== next.rawStatus);
  const heartbeat = !previous || now - previous.heartbeatAt >= 60_000;
  const deliveries: Delivery[] = [];
  for (const sub of subscribers) {
    if (sub.expiresAt <= now) continue;
    for (const activity of sub.activities.filter(a => a.fixtureId === next.fixtureId)) {
      // New subscriptions receive a current snapshot even if the game hasn't changed.
      if (!urgent && !heartbeat && sub.updatedAt <= (previous?.observedAt ?? 0)) continue;
      if (next.status === "SCHEDULED") continue;
      const terminal = isTerminal(next);
      const key = hash(`liveactivity:${activity.token}`);
      deliveries.push({
        id: key, version: randomUUID(), installationId: sub.id, token: activity.token,
        kind: "liveactivity", fixtureId: next.fixtureId, priority: urgent || terminal ? 10 : 5,
        collapseId: key, expiresAt: now + (terminal ? 3_600_000 : 120_000), nextAttempt: now, attempts: 0,
        payload: { aps: {
          timestamp: Math.floor(now / 1000), event: terminal ? "end" : "update",
          "content-state": contentState(next, now),
          ...(terminal ? { "dismissal-date": Math.floor(now / 1000) + 3600 }
            : { "stale-date": Math.floor(now / 1000) + 120 }),
        } },
      });
    }
    if (!sub.alertsEnabled || !sub.deviceToken || !sub.teamIds.some(id => id === next.home.id || id === next.away.id)) continue;
    // Never send events that predate the device's subscription.
    if (previous && (sub.alertsSince ?? sub.updatedAt) > previous.observedAt) continue;
    for (const event of events.filter(e => sub.eventTypes.includes(e.type))) {
      const key = hash(`alert:${sub.id}:${next.fixtureId}:${revision}:${event.id}`);
      deliveries.push({
        id: key, version: randomUUID(), installationId: sub.id, token: sub.deviceToken,
        kind: "alert", fixtureId: next.fixtureId, priority: 10, collapseId: key,
        expiresAt: now + 120_000, nextAttempt: now, attempts: 0,
        payload: { aps: {
          alert: { title: event.title, body: `${next.home.name} ${scoreText(next)} ${next.away.name}${event.detail ? ` · ${event.detail}` : ""}` },
          sound: "default", "thread-id": `match-${next.fixtureId}`,
          // Sports alerts use normal interruption level; no claim to critical privileges.
          "interruption-level": "active",
        }, fixtureId: next.fixtureId, eventId: event.id, eventType: event.type },
      });
    }
  }
  return { record: { snapshot: next, observedAt: now, heartbeatAt: urgent || heartbeat ? now : previous!.heartbeatAt, revision }, deliveries };
}
