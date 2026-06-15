import { getMessaging, Messaging } from "firebase-admin/messaging";
import { firebaseApp } from "./store.js";
import type { MatchEvent } from "./types.js";
import { log } from "./log.js";

export function topicForTeam(leagueId: number, teamId: number): string {
  return `l${leagueId}_${teamId}`;
}

/** Data-only pushes; the app renders animations/notifications itself. */
export class Fcm {
  private readonly messaging: Messaging;

  constructor(messaging?: Messaging) {
    this.messaging = messaging ?? getMessaging(firebaseApp());
  }

  private async sendData(topic: string, data: Record<string, string>): Promise<void> {
    const started = Date.now();
    log.info("fcm_topic_send_start", {
      topic,
      eventId: data.eventId,
      type: data.type,
      fixtureId: Number(data.fixtureId),
    });
    try {
      const messageId = await this.messaging.send({
        topic,
        data,
        apns: {
          headers: { "apns-priority": "5", "apns-push-type": "background" },
          payload: { aps: { contentAvailable: true } },
        },
      });
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
    log.info("fcm_event_publish_start", {
      eventId: ev.eventId,
      type: ev.type,
      fixtureId: ev.fixtureId,
      topics: [...topics],
    });
    await Promise.all([...topics].map((t) => this.sendData(t, data)));
    log.info("fcm_event_publish_complete", {
      eventId: ev.eventId,
      type: ev.type,
      fixtureId: ev.fixtureId,
      topics: [...topics],
    });
  }

}
