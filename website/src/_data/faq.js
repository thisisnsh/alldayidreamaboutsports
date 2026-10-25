// The FAQ bank, plus the builders that assemble a scoped set for a league or
// a team page. There is no /faq/ page - the home page carries the full bank
// and every other page carries the questions that fit it, so each one earns
// its own FAQPage block instead of pointing at a shared one.
import site from "./site.js";

/** The full bank, in the order the home page renders it. */
const home = [
  {
    q: "How do I get football match alerts on my Mac?",
    a: "Download All Day I Dream About Sports from the Mac App Store. The free macOS app delivers goal, card, penalty, substitution and full-time alerts right below your MacBook notch, and pins a score capsule to any corner of your screen.",
  },
  {
    q: "Is All Day I Dream About Sports free?",
    a: "Yes - the app is free on the Mac App Store for macOS 14 and later, with no subscription, trial or paid tier. A Windows version is also planned.",
  },
  {
    q: "Which leagues and teams can I follow?",
    a: "The Premier League, La Liga, Serie A, Bundesliga and Ligue 1 are live, and national teams are saved from the 2026 World Cup. The UEFA Champions League, Europa League and more sports are coming.",
  },
  {
    q: "What kinds of live football notifications does it show?",
    a: "Fourteen event types, each with its own switch: kickoff, goal, disallowed goal, yellow card, red card, half-time, second half, full-time, extra time, penalty shootout, penalty kick, substitution, VAR decision and the celebration tally. Turn on the ones you want and leave the rest off.",
  },
  {
    q: "Will match notifications interrupt my work?",
    a: "No. Alerts slide in below the notch and get out of the way - pick a short, medium or long alert time - and the floating score capsule sits in whichever corner you drag it to. It is built to keep you in flow while you follow the match.",
  },
  {
    q: "Can I pin more than one match to my screen?",
    a: "Yes. Pin several capsules at once, drag each to any corner and they snap into place without overlapping. Click a capsule for the full event timeline - every goal, card and substitution on a shared minute column - and set them to small, medium or large.",
  },
  {
    q: "Can I celebrate goals with other fans?",
    a: "Yes. When the goal alert arrives, your team's crest and confetti burst from the bottom corners of the screen and sweep in toward the middle, gone within seconds. Goal confetti has its own switch - flipping it on plays a sample burst - and a short, medium or long confetti time.",
  },
  {
    q: "Does it work across multiple monitors?",
    a: "Yes - choose which screen the alerts and capsules appear on. The app also follows your system, light or dark theme instantly, opens at login, and never appears in the Dock.",
  },
  {
    q: "How accurate is the live match clock?",
    a: "The minute ticks locally between feed updates. Stoppage time is rendered as 45+3 or 90+, penalty shootouts, own goals and aggregate-first scoring are all handled, and a VAR decision that arrives too late to be in order is suppressed rather than fired out of sequence.",
  },
  {
    q: "Does it track me or need an account?",
    a: "No account and no sign-in. The teams you follow and your app settings stay on your Mac and are never stored on our side. We do count anonymous usage - screens opened, buttons used, settings toggled - plus crash reports, tied only to a random app-instance id, never to you. See the privacy policy for the full details.",
  },
  {
    q: "How do I keep the app up to date?",
    a: "The Mac App Store installs updates automatically. Direct downloads and the old Sparkle update feed have been retired.",
  },
  {
    q: "Is it affiliated with FIFA?",
    a: "No. It is not affiliated with FIFA or any league, club or brand. Team names and crests are used only to identify the matches you choose to follow.",
  },
];

/**
 * League page FAQ - seven questions, every one naming the league, so no two
 * league pages carry the same FAQPage block.
 */
function forLeague(league) {
  const L = league.name;
  const isCup = league.type === "Cup";
  const covers = isCup
    ? `The nations from the ${L} are saved in the app, and the results and events from the tournament are all handled by the same engine - extra time, penalty shootouts and aggregate scoring included.`
    : `Yes - every ${L} fixture in the season. Follow the clubs you care about and the menu shows their ${L} matches.`;

  return [
    {
      q: `How do I follow the ${L} for free on my Mac?`,
      a: `Download All Day I Dream About Sports from the Mac App Store, free on ${site.requires}, then follow a ${L} team or the whole competition.`,
    },
    {
      q: `Can I get ${L} goal alerts without keeping a browser tab open?`,
      a: `Yes - that is the point of it. ${L} alerts drop below your MacBook notch and slide away again, and a floating capsule keeps the running score in a corner. No tab, no phone, no refreshing.`,
    },
    {
      q: `Does it cover every ${L} match?`,
      a: covers,
    },
    {
      q: `How fast are the ${L} match alerts?`,
      a: `Match alerts follow the source feed and the app's polling interval, so a short delay is normal. The match clock continues locally between feed updates.`,
    },
    {
      q: `Which ${L} ${isCup ? "nations" : "clubs"} can I follow?`,
      a: `Every team covered by the app has its own page on this site. Choose the teams you care about or follow the whole ${L}.`,
    },
    {
      q: `Do I need an account to follow the ${L}?`,
      a: `No. There is no account or sign-in - just open the app and pick your ${L} teams. Your picks and settings stay on your Mac.`,
    },
    {
      q: `Is this app affiliated with the ${L}?`,
      a: `No. It is not affiliated with the ${L}, FIFA, or any club or brand. ${L} club names and crests are used only to identify the matches you choose to follow.`,
    },
  ];
}

/**
 * Team page FAQ - five questions, all naming the club, so 144 pages do not
 * share a single FAQ block between them.
 */
function forTeam(team, league) {
  const T = team.displayName;
  const L = league.name;
  const national = team.national;

  return [
    {
      q: `How do I follow ${T} on my Mac?`,
      a: national
        ? `Download All Day I Dream About Sports from the Mac App Store. ${T} are saved from the 2026 World Cup in the team picker for the next tournament.`
        : `Download All Day I Dream About Sports from the Mac App Store, then follow ${T} in the team picker for goal, card and VAR alerts below your MacBook notch, plus a pinned score capsule.`,
    },
    {
      q: `Can I follow ${T} for free?`,
      a: `Yes - the app is free on ${site.requires}. No account, no ${T} subscription and no paid tier.`,
    },
    {
      q: `Will I get an alert when ${T} score?`,
      a: `Yes. Alerts follow the source feed, so a short delay can occur${national ? " - this is how the 2026 tournament ran, and how 2030 will" : ""}. The goal alert drops under the notch, the capsule score updates, and if you want it, goal confetti of your team's crest bursts from the screen corners.`,
    },
    {
      q: `Can I follow ${T} and other teams at the same time?`,
      a: `Yes. Follow ${T} alongside teams from any of the other competitions in the app, and pin several matches at the same time.`,
    },
    {
      q: national
        ? `Does it still cover ${T} between tournaments?`
        : `Does it cover every ${T} match in the ${L}?`,
      a: national
        ? `${T} are saved from the 2026 World Cup and held for 2030 - there are no international fixtures to alert on in between. In the meantime the five club leagues run live all season, so the app is not sitting idle.`
        : `Yes - every ${T} fixture in the ${L} season, with the full event timeline on each one. Stoppage time shows honestly as 45+3 or 90+, and the match clock ticks locally so the minute is right between polls.`,
    },
  ];
}

export default { home, forLeague, forTeam };
