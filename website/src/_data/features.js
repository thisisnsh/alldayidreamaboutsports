// What the app actually does, read out of the app source rather than guessed:
// SettingsView.swift, MenuPopoverView.swift, TeamPickerView.swift,
// MatchModels.swift, Theme.swift and infra/remoteconfig.template.json.
//
// The home page carries the full set; league and team pages carry the same
// capabilities reworded around the competition or the club, so no two feature
// sections on the site read alike.
import site from "./site.js";

const cap = site.followCap;

const home = [
  {
    h: "Every moment, dropped under the notch",
    p: "Fourteen event types — kickoff, goal, disallowed goal, yellow, red, half-time, second half, full-time, extra time, penalty shootout, penalty kick, substitution, VAR decision and the celebration tally — each with its own switch. Turn on what you care about and the rest never appears.",
  },
  {
    h: "Capsules you can stack",
    p: "Pin several matches at once and the stack animates so the others slide when one expands. Hover any capsule for the full event timeline — every goal, card and substitution on a shared minute column — and set each one small, medium or large, top or bottom.",
  },
  {
    h: "Never in the way of your work",
    p: "A capsule never intercepts a click meant for the window behind it. Alerts slide in below the notch and slide out again, and the app has no Dock icon to lose your place to.",
  },
  {
    h: "Celebrate the goal with everyone else",
    p: "The moment your team scores, the goal takes over the screen and you tap the ball to celebrate with fans worldwide. Goal-in-centre, corner confetti and the confetti pop each toggle independently, and a Preview button fires one whenever you want to see it.",
  },
  {
    h: `Follow up to ${cap} teams at once`,
    p: `Any mix of leagues. The picker has follow-all and unfollow-all per league, a live "3 of ${cap}" counter, and a banner when you have filled every slot.`,
  },
  {
    h: "Today's matches, or all of them",
    p: "My Teams shows today's fixtures for the clubs you follow. All Teams shows every match across all five leagues, with matchday labels per competition. Both read the same file, so switching costs nothing.",
  },
  {
    h: "The minute on your screen is the right one",
    p: "The match clock ticks locally between polls, stoppage time renders honestly as 45+3 or 90+, and penalty shootouts, own goals, penalties and aggregate-first scoring are all handled. A VAR decision that arrives too late to be in order is suppressed rather than fired out of sequence.",
  },
  {
    h: "It fits the machine you already use",
    p: "System, light or dark theme applied instantly. Choose which monitor the overlays appear on, open at login, stay out of the Dock, and update itself through Sparkle with an in-menu banner when a new build lands.",
  },
  {
    h: "Nothing about you is sent anywhere",
    p: "Nothing is pushed and nothing is per-user: every Mac polls the same CDN-cached JSON file. We do not know which teams you follow, because that never leaves your device.",
  },
];

/** Five rows, every one naming the competition. */
function forLeague(league, clubCount) {
  const L = league.name;
  const isCup = league.type === "Cup";
  const unit = isCup ? "nations" : "clubs";
  return [
    {
      h: `${L} goals, under your notch`,
      p: `Every ${L} goal, card, penalty, substitution and VAR decision drops below the MacBook notch as it happens — fourteen event types in all, each with its own switch. Turn off the substitutions and keep the goals, or take the lot.`,
    },
    {
      h: `Pin the ${L} match to a corner`,
      p: `A floating capsule holds the running ${L} scoreline while you work, and hovering it opens the whole match timeline on a shared minute column. Pin more than one when the ${L} plays a full round at the same time.`,
    },
    {
      h: `Follow ${isCup ? "any of the 48 nations" : `any of the ${clubCount} ${unit}`}`,
      p: `Every ${L} ${isCup ? "nation" : "club"} is one tap in the picker, or take the whole ${L} in one go with follow-all. You can carry up to ${cap} teams at a time across any mix of competitions.`,
    },
    {
      h: `The ${L} clock, told honestly`,
      p: `The minute ticks locally between polls, so a ${L} match reads 45+3 or 90+ when that is what it is. Penalty shootouts, own goals and aggregate scoring are all handled properly rather than flattened into a number.`,
    },
    {
      h: `Celebrate the ${L} goal with the rest of the world`,
      p: `When a ${L} goal goes in, the celebration takes over your screen and the taps are counted worldwide. Goal-in-centre, confetti and the pop sound each have their own switch if you would rather it stayed quiet.`,
    },
  ];
}

/** Five rows in the second person, every one naming the club. */
function forTeam(team, league) {
  const T = team.displayName;
  const L = league.name;
  const national = team.national;
  return [
    {
      h: `Their goals, the second they go in`,
      p: `${T} score and the alert drops below your notch before the group chat gets there. Cards, penalties, substitutions and VAR decisions come the same way — fourteen event types, each one switchable, so you can keep the goals and drop the rest.`,
    },
    {
      h: `Their score, pinned to your corner`,
      p: `A floating capsule holds the ${T} scoreline while you work, and never steals a click from the window underneath. Hover it for the full timeline of the match — every goal, card and substitution on one minute column.`,
    },
    {
      h: `Their celebration, shared with everyone else's`,
      p: `When ${T} score, the goal can take over your screen so you can tap the ball and celebrate live with fans across the globe. Or it can not — goal-in-centre, confetti and the pop sound each toggle on their own.`,
    },
    {
      h: national
        ? `${T} saved, and ${cap - 1} club sides alongside them`
        : `${T} and up to ${cap - 1} others`,
      p: national
        ? `${T} stay in your picker between tournaments, and you can carry up to ${cap} teams at once — so the club sides you follow week to week sit right beside them.`
        : `Follow up to ${cap} teams at once across any mix of leagues. Pin several matches at the same time and the capsules stack, so ${T} and the rest of the ${L} round sit side by side.`,
    },
    {
      h: `Nothing about following ${T} leaves your Mac`,
      p: `Your picks and settings stay on the device — every Mac polls the same CDN-cached file, so we have no idea you follow ${T}. Free on ${site.requires}, no account tier, nothing to unlock.`,
    },
  ];
}

export default { home, forLeague, forTeam };
