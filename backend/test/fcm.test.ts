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
  it.each(allTypes)("publishes %s to both team topics with an APNs background payload", async (type) => {
    const send = vi.fn()
      .mockResolvedValueOnce(`message-${type}-home`)
      .mockResolvedValueOnce(`message-${type}-away`);
    const fcm = new Fcm({ send } as never);

    await fcm.publishEvent(event(type));

    expect(send).toHaveBeenCalledTimes(2);
    expect(send.mock.calls.map(([message]) => message.topic).sort()).toEqual(["l1_16", "l1_6"]);
    for (const [message] of send.mock.calls) {
      expect(message).toMatchObject({
        data: {
          kind: "match_event",
          eventId: `100:${type}`,
          type,
          fixtureId: "100",
          leagueId: "1",
          homeTeamId: "6",
          awayTeamId: "16",
        },
        apns: {
          headers: { "apns-priority": "5", "apns-push-type": "background" },
          payload: { aps: { contentAvailable: true } },
        },
      });
    }
  });
});
