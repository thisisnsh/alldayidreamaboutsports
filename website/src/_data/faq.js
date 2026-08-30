// The FAQ bank, plus the builders that assemble a scoped set for a league or
// a team page. There is no /faq/ page - the home page carries the full bank
// and every other page carries the questions that fit it, so each one earns
// its own FAQPage block instead of pointing at a shared one.
import site from "./site.js";

/** The full bank, in the order the home page renders it. */
const home = [
  {
    q: "How do I get football match alerts on my Mac?",
    a: "Download All Day I Dream About Sports - a free macOS app. It delivers goal, card, penalty, substitution and full-time alerts right below your MacBook notch, and pins a score capsule to any corner of your screen. No extra browser tab, no phone in your hand.",
  },
  {
    q: "Is All Day I Dream About Sports free?",
    a: "Yes - it is completely free on macOS 14 and later. You sign in to use the app, but there is no subscription, trial or paid tier. A Windows version is coming; join the waitlist from the download button.",
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
    a: "No. Alerts slide in below the notch and get out of the way, and the floating score capsule never intercepts a click meant for the window behind it. It is built to keep you in flow while you follow the match.",
  },
  {
    q: "Can I pin more than one match to my screen?",
    a: "Yes. Pin several capsules at once and the stack animates so the others slide out of the way when one expands. Hover a capsule for the full event timeline - every goal, card and substitution on a shared minute column - and set each one to small, medium or large, at the top or the bottom of the screen.",
  },
  {
    q: "Can I celebrate goals with other fans?",
    a: "Yes. When the goal alert arrives, the goal takes over your screen - tap the ball to celebrate with football fans across the globe. Goal-in-centre, corner confetti and the confetti pop sound each have their own switch, and there is a Preview button to fire one on demand.",
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
    a: "Yes, you sign in with Google to use the app. We store the profile details needed for sign-in, while the teams you follow and your app settings stay on your device. We do count anonymous usage - screens opened, buttons used, settings toggled - but only as aggregate numbers that are never tied to your account, and your teams and settings are not stored on our side. See the privacy policy for the full details.",
  },
  {
    q: "How do I keep the app up to date?",
    a: "It updates itself through Sparkle, and shows an Update available banner in the menu when a new build is ready. There is nothing to download twice.",
  },
  {
    q: "Can I see every match, not just my teams?",
    a: "Yes. The menu has a My Teams tab for today's fixtures involving the clubs you follow, and an All Teams tab for every match across all five leagues, with matchday labels per league. Both read the same file, so switching costs nothing.",
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
    : `Yes - every ${L} fixture in the season. Follow a club or the whole league, and the All Teams tab shows the full ${L} matchday.`;

  return [
    {
      q: `How do I follow the ${L} for free on my Mac?`,
      a: `Download All Day I Dream About Sports, sign in, and follow a ${L} club or the whole league. It is free on ${site.requires}, with no subscription or paid tier.`,
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
      a: `Yes. Sign in with Google to use the app. Your ${L} picks and settings stay on your device rather than being attached to your profile.`,
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
        ? `Download All Day I Dream About Sports and follow ${T} in the team picker. ${T} goals, cards and penalties from the 2026 World Cup dropped below the MacBook notch throughout the tournament, and the pick is held for the next tournament.`
        : `Download All Day I Dream About Sports, open the team picker, and follow ${T}. ${T} goals, cards, substitutions and VAR decisions then drop below your MacBook notch throughout the match, and a capsule pins the score to a corner of your screen.`,
    },
    {
      q: `Can I follow ${T} for free?`,
      a: `Yes - the app is free on ${site.requires}. You need to sign in, but there is no ${T} subscription or paid tier.`,
    },
    {
      q: `Will I get an alert when ${T} score?`,
      a: `Yes. Alerts follow the source feed, so a short delay can occur${national ? " - this is how the 2026 tournament ran, and how 2030 will" : ""}. The goal alert drops under the notch, the capsule score updates, and if you want it, the goal takes over the screen so you can tap the ball and celebrate with fans worldwide. Goal-in-centre, confetti and the pop sound each have their own switch.`,
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
