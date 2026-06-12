import { getMessaging, Messaging } from "firebase-admin/messaging";
import { firebaseApp } from "./store.js";
import type { MatchEvent } from "./types.js";

export function topicForTeam(leagueId: number, teamCode: string): string {
  return `l${leagueId}_${teamCode}`;
}

/** Data-only pushes; the app renders animations/notifications itself. */
export class Fcm {
  private readonly messaging: Messaging;

  constructor(messaging?: Messaging) {
    this.messaging = messaging ?? getMessaging(firebaseApp());
  }

  private async sendData(topic: string, data: Record<string, string>): Promise<void> {
    await this.messaging.send({
      topic,
      data,
      apns: {
        headers: { "apns-priority": "5", "apns-push-type": "background" },
        payload: { aps: { contentAvailable: true } },
      },
    });
  }

  async publishEvent(ev: MatchEvent): Promise<void> {
    const data: Record<string, string> = {
      kind: "match_event",
      eventId: ev.eventId,
      type: ev.type,
      fixtureId: String(ev.fixtureId),
      leagueId: String(ev.leagueId),
      homeTeam: ev.homeTeam,
      awayTeam: ev.awayTeam,
      homeName: ev.homeName,
      awayName: ev.awayName,
      homeGoals: String(ev.homeGoals),
      awayGoals: String(ev.awayGoals),
      teamCode: ev.teamCode ?? "",
      player: ev.player ?? "",
      minute: ev.minute == null ? "" : String(ev.minute),
    };
    const topics = new Set([
      topicForTeam(ev.leagueId, ev.homeTeam),
      topicForTeam(ev.leagueId, ev.awayTeam),
    ]);
    await Promise.all([...topics].map((t) => this.sendData(t, data)));
  }

  async publishCelebrationCount(
    leagueId: number,
    fixtureId: number,
    homeTeam: string,
    awayTeam: string,
    totals: Record<string, number>,
  ): Promise<void> {
    const data: Record<string, string> = {
      kind: "celebration_count",
      fixtureId: String(fixtureId),
      totals: JSON.stringify(totals),
    };
    const topics = new Set([topicForTeam(leagueId, homeTeam), topicForTeam(leagueId, awayTeam)]);
    await Promise.all([...topics].map((t) => this.sendData(t, data)));
  }
}
