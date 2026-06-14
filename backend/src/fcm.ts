import { getMessaging, Messaging } from "firebase-admin/messaging";
import { firebaseApp } from "./store.js";
import type { MatchEvent } from "./types.js";

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
    await Promise.all([...topics].map((t) => this.sendData(t, data)));
  }

  async publishCelebrationCount(
    leagueId: number,
    fixtureId: number,
    homeTeamId: number,
    awayTeamId: number,
    totals: Record<string, number>,
  ): Promise<void> {
    const data: Record<string, string> = {
      kind: "celebration_count",
      fixtureId: String(fixtureId),
      totals: JSON.stringify(totals),
    };
    const topics = new Set([topicForTeam(leagueId, homeTeamId), topicForTeam(leagueId, awayTeamId)]);
    await Promise.all([...topics].map((t) => this.sendData(t, data)));
  }
}
