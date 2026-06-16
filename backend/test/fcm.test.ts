import { describe, expect, it, vi } from "vitest";
import { Fcm } from "../src/fcm.js";
import type { MatchEvent, MatchEventType } from "../src/types.js";

const allTypes: MatchEventType[] = [
  "KICKOFF",
  "GOAL",
  "GOAL_CANCELLED",
  "YELLOW_CARD",
  "RED_CARD",
  "HALF_TIME",
  "FULL_TIME",
  "EXTRA_TIME",
  "PENALTY_SHOOTOUT",
  "PENALTY_KICK",
];

function event(type: MatchEventType): MatchEvent {
  return {
    eventId: `100:${type}`,
    type,
    fixtureId: 100,
    leagueId: 1,
    homeTeamId: 6,
    awayTeamId: 16,
    homeName: "Brazil",
    awayName: "United States",
    homeGoals: 1,
    awayGoals: 0,
    teamId: type === "KICKOFF" ? undefined : 6,
    player: type === "KICKOFF" ? undefined : "Player",
    minute: type === "KICKOFF" ? undefined : 10,
  };
}

describe("Fcm", () => {
  it.each(allTypes)("publishes %s to both team topics as an urgent alert + silent companion", async (type) => {
    const send = vi.fn().mockResolvedValue(`message-${type}`);
    const fcm = new Fcm({ send } as never);

    await fcm.publishEvent(event(type));

    // Two topics × two pushes (urgent alert + silent companion) = four sends.
    expect(send).toHaveBeenCalledTimes(4);
    expect(send.mock.calls.map(([message]) => message.topic).sort())
      .toEqual(["l1_16", "l1_16", "l1_6", "l1_6"]);

    for (const topic of ["l1_6", "l1_16"]) {
      const pushes = send.mock.calls.map(([m]) => m).filter((m) => m.topic === topic);
      const alert = pushes.find((m) => m.apns.headers["apns-push-type"] === "alert");
      const silent = pushes.find((m) => m.apns.headers["apns-push-type"] === "background");

      expect(alert).toMatchObject({
        data: { kind: "match_event", eventId: `100:${type}`, type },
        apns: {
          headers: { "apns-priority": "10", "apns-push-type": "alert" },
          payload: {
            aps: {
              interruptionLevel: "time-sensitive",
              alert: { title: expect.any(String), body: expect.any(String) },
            },
          },
        },
      });
      // APNs rejects priority 10 with content-available — the alert must not set it.
      expect(alert.apns.payload.aps.contentAvailable).toBeUndefined();
      expect(alert.apns.payload.aps.alert.title.length).toBeGreaterThan(0);

      expect(silent).toMatchObject({
        data: { kind: "match_event", eventId: `100:${type}` },
        apns: {
          headers: { "apns-priority": "5", "apns-push-type": "background" },
          payload: { aps: { contentAvailable: true } },
        },
      });
    }
  });
});
