import { getMessaging, Messaging } from "firebase-admin/messaging";
import { firebaseApp } from "./store.js";
import type { MatchEvent } from "./types.js";
import { log } from "./log.js";

export function topicForTeam(leagueId: number, teamId: number): string {
  return `l${leagueId}_${teamId}`;
}

/**
 * User-facing copy for the system notification. It's a delivery-grade fallback:
 * the running app still draws its own rich pill from the data payload, but this
 * guarantees the user is told even when the app can't render (asleep screen,
 * not running). Also required so APNs treats the push as a real alert.
 */
export function notificationText(ev: MatchEvent): { title: string; body: string } {
  const score = `${ev.homeName} ${ev.homeGoals}-${ev.awayGoals} ${ev.awayName}`;
  const min = ev.minute != null ? `${ev.minute}' ` : "";
  const team = ev.teamId === ev.homeTeamId ? ev.homeName : ev.awayName;
  const who = ev.player || team;
  switch (ev.type) {
    case "GOAL": return { title: `⚽️ GOAL — ${who}`, body: `${min}${score}` };
    case "GOAL_CANCELLED": return { title: `VAR — goal disallowed (${team})`, body: score };
    case "YELLOW_CARD": return { title: `🟨 Yellow card — ${who}`, body: `${min}${score}` };
    case "RED_CARD": return { title: `🟥 Red card — ${who}`, body: `${min}${score}` };
    case "KICKOFF": return { title: "Kick-off", body: `${ev.homeName} vs ${ev.awayName}` };
    case "HALF_TIME": return { title: "Half-time", body: score };
    case "FULL_TIME": return { title: "Full-time", body: score };
    case "EXTRA_TIME": return { title: "Extra time", body: `${ev.homeName} vs ${ev.awayName}` };
    case "PENALTY_SHOOTOUT": return { title: "Penalty shootout!", body: score };
    case "PENALTY_KICK":
      return { title: `Penalty — ${who} ${ev.scored ? "scored ✓" : "missed ✗"}`, body: score };
    default: return { title: ev.type, body: score };
  }
}

/**
 * Time-sensitive pushes. Match events are urgent, so each one is sent as TWO
 * APNs pushes (a single push can't be both — APNs rejects priority 10 with
 * content-available):
 *   1. A priority-10 `alert` push (`interruption-level: time-sensitive`) — the
 *      guaranteed, never-throttled delivery that shows the system banner.
 *   2. A priority-5 `background` push (`content-available`) — a best-effort wake
 *      so a running app can draw its own rich overlay. APNs budgets/delays these
 *      (the old single-channel bug), so it rides on top of (1), never alone.
 * Both carry the same data payload, and the app dedupes by event id.
 */
export class Fcm {
  private readonly messaging: Messaging;

  constructor(messaging?: Messaging) {
    this.messaging = messaging ?? getMessaging(firebaseApp());
  }

  private async sendData(
    topic: string,
    data: Record<string, string>,
    notif: { title: string; body: string },
  ): Promise<void> {
    const started = Date.now();
    log.info("fcm_topic_send_start", {
      topic,
      eventId: data.eventId,
      type: data.type,
      fixtureId: Number(data.fixtureId),
    });
    try {
      // Two pushes per event, because APNs can't do both at once (it rejects
      // priority 10 alongside content-available):
      //   1. Urgent alert (priority 10, time-sensitive) — the GUARANTEED, never
      //      throttled delivery. Shows a system banner and, when the app is
      //      frontmost, drives the overlay via willPresent.
      //   2. Silent companion (priority 5, background) — best-effort wake so a
      //      running menu-bar app draws its rich pill/celebration overlay. APNs
      //      throttles these, so it's a bonus on top of (1), never the guarantee.
      const collapseId = (data.eventId ?? "").slice(0, 64);
      const [messageId] = await Promise.all([
        this.messaging.send({
          topic,
          data,
          apns: {
            headers: {
              "apns-priority": "10",
              "apns-push-type": "alert",
              "apns-collapse-id": collapseId,
            },
            payload: {
              aps: {
                alert: { title: notif.title, body: notif.body },
                sound: "default",
                interruptionLevel: "time-sensitive",
              },
            },
          },
        }),
        this.messaging.send({
          topic,
          data,
          apns: {
            headers: {
              "apns-priority": "5",
              "apns-push-type": "background",
            },
            payload: { aps: { contentAvailable: true } },
          },
        }),
      ]);
      log.info("fcm_topic_send_complete", {
        topic,
        eventId: data.eventId,
        type: data.type,
        fixtureId: Number(data.fixtureId),
        messageId,
        durationMs: Date.now() - started,
      });
    } catch (error) {
      log.error("fcm_topic_send_failed", error, {
        topic,
        eventId: data.eventId,
        type: data.type,
        fixtureId: Number(data.fixtureId),
        durationMs: Date.now() - started,
      });
      throw error;
    }
  }

  async publishEvent(ev: MatchEvent): Promise<void> {
    const data: Record<string, string> = {
      kind: "match_event",
      eventId: ev.eventId,
      type: ev.type,
      fixtureId: String(ev.fixtureId),
      leagueId: String(ev.leagueId),
      homeTeamId: String(ev.homeTeamId),
      awayTeamId: String(ev.awayTeamId),
      homeName: ev.homeName,
      awayName: ev.awayName,
      homeGoals: String(ev.homeGoals),
      awayGoals: String(ev.awayGoals),
      teamId: ev.teamId == null ? "" : String(ev.teamId),
      player: ev.player ?? "",
      minute: ev.minute == null ? "" : String(ev.minute),
      penHome: ev.penHome == null ? "" : String(ev.penHome),
      penAway: ev.penAway == null ? "" : String(ev.penAway),
      scored: ev.scored == null ? "" : String(ev.scored),
    };
    const topics = new Set([
      topicForTeam(ev.leagueId, ev.homeTeamId),
      topicForTeam(ev.leagueId, ev.awayTeamId),
    ]);
    const notif = notificationText(ev);
    log.info("fcm_event_publish_start", {
      eventId: ev.eventId,
      type: ev.type,
      fixtureId: ev.fixtureId,
      topics: [...topics],
    });
    await Promise.all([...topics].map((t) => this.sendData(t, data, notif)));
    log.info("fcm_event_publish_complete", {
      eventId: ev.eventId,
      type: ev.type,
      fixtureId: ev.fixtureId,
      topics: [...topics],
    });
  }

}
