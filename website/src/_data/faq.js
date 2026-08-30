// The FAQ bank, plus the builders that assemble a scoped set for a league or
// a team page. There is no /faq/ page — the home page carries the full bank
// and every other page carries the questions that fit it, so each one earns
// its own FAQPage block instead of pointing at a shared one.
import site from "./site.js";

const cap = site.followCap;

/** The full bank, in the order the home page renders it. */
const home = [
  {
    q: "How do I get live football scores on my Mac?",
    a: "Download All Day I Dream About Sports — a free macOS app. It delivers live goal, card, penalty, substitution and full-time alerts right below your MacBook notch, and pins a live score capsule to any corner of your screen. No extra browser tab, no phone in your hand.",
  },
  {
    q: "Is All Day I Dream About Sports free?",
    a: "Yes — it is completely free on macOS 14 and later, with no account tier, no trial and nothing to unlock. A Windows version is coming; join the waitlist from the download button.",
  },
  {
    q: "Which leagues and teams can I follow?",
    a: "The Premier League, La Liga, Serie A, Bundesliga and Ligue 1 are live, covering 96 clubs, and 48 national teams are saved from the 2026 World Cup. The UEFA Champions League, Europa League and more sports are coming.",
  },
  {
    q: "What kinds of live football notifications does it show?",
    a: "Fourteen event types, each with its own switch: kickoff, goal, disallowed goal, yellow card, red card, half-time, second half, full-time, extra time, penalty shootout, penalty kick, substitution, VAR decision and the celebration tally. Turn on the ones you want and leave the rest off.",
  },
  {
    q: "Will live score notifications interrupt my work?",
    a: "No. Alerts slide in below the notch and get out of the way, and the floating score capsule never intercepts a click meant for the window behind it. It is built to keep you in flow while you follow the match.",
  },
  {
    q: `How many teams can I follow at once?`,
    a: `Up to ${cap}, across any mix of leagues. The picker has a follow-all and unfollow-all control per league, keeps a running "3 of ${cap}" counter, and tells you when you have reached the limit.`,
  },
  {
    q: "Can I pin more than one match to my screen?",
    a: "Yes. Pin several capsules at once and the stack animates so the others slide out of the way when one expands. Hover a capsule for the full event timeline — every goal, card and substitution on a shared minute column — and set each one to small, medium or large, at the top or the bottom of the screen.",
  },
  {
    q: "Can I celebrate goals with other fans in real time?",
    a: "Yes. The moment your team scores, the goal takes over your screen — tap the ball to celebrate live with football fans across the globe, all at once. Goal-in-centre, corner confetti and the confetti pop sound each have their own switch, and there is a Preview button to fire one on demand.",
  },
  {
    q: "Does it work across multiple monitors?",
    a: "Yes — choose which screen the alerts and capsules appear on. The app also follows your system, light or dark theme instantly, opens at login, and never appears in the Dock.",
  },
  {
    q: "How accurate is the live match clock?",
    a: "The minute ticks locally between polls, so it is right even in the seconds between updates. Stoppage time is rendered honestly as 45+3 or 90+, penalty shootouts, own goals and aggregate-first scoring are all handled, and a VAR decision that arrives too late to be in order is suppressed rather than fired out of sequence.",
  },
  {
    q: "Does it track me or need an account?",
    a: "Nothing is pushed to you and nothing is per-user: every Mac polls the same CDN-cached JSON file, so we do not know which teams you follow. Your picks and settings stay on your device. Signing in is only for the goal celebration.",
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
 * League page FAQ — seven questions, every one naming the league, so no two
 * league pages carry the same FAQPage block.
 */
function forLeague(league, clubCount) {
  const L = league.name;
  const isCup = league.type === "Cup";
  const covers = isCup
    ? `All 48 nations from the ${L} are saved in the app, and the results and events from the tournament are all handled by the same engine — extra time, penalty shootouts and aggregate scoring included.`
    : `Yes — every ${L} fixture in the season, for all ${clubCount} clubs. Follow one club or several and you get their matches; the All Teams tab shows the full ${L} matchday whether you follow those clubs or not.`;

  return [
    {
      q: `How do I follow the ${L} for free on my Mac?`,
      a: `Download All Day I Dream About Sports, open the team picker, and follow any ${L} club — or use follow-all to take the whole league in one go. It is free on ${site.requires}, with no account tier and nothing to unlock.`,
    },
    {
      q: `Can I get ${L} goal alerts without keeping a browser tab open?`,
      a: `Yes — that is the point of it. ${L} alerts drop below your MacBook notch and slide away again, and a floating capsule keeps the running score in a corner. No tab, no phone, no refreshing.`,
    },
    {
      q: `Does it cover every ${L} match?`,
      a: covers,
    },
    {
      q: `How fast are the ${L} live score notifications?`,
      a: `Fast enough that the notch alert usually beats the group chat. The app polls a CDN-cached feed on a short interval and ticks the match clock locally between polls, so the minute on your screen is right even between updates.`,
    },
    {
      q: `Which ${L} ${isCup ? "nations" : "clubs"} can I follow?`,
      a: `All ${clubCount} of them — each one has its own page on this site, and each one is one tap in the picker. You can follow up to ${cap} teams at a time across any mix of competitions.`,
    },
    {
      q: `Do I need an account to follow the ${L}?`,
      a: `No. Your ${L} picks and settings stay on your device and are never sent to us — every Mac polls the same cached file. Signing in is only needed for the goal celebration.`,
    },
    {
      q: `Is this app affiliated with the ${L}?`,
      a: `No. It is not affiliated with the ${L}, FIFA, or any club or brand. ${L} club names and crests are used only to identify the matches you choose to follow.`,
    },
  ];
}

/**
 * Team page FAQ — five questions, all naming the club, so 144 pages do not
 * share a single FAQ block between them.
 */
function forTeam(team, league) {
  const T = team.displayName;
  const L = league.name;
  const national = team.national;

  return [
    {
      q: `How do I get ${T} live scores on my Mac?`,
      a: national
        ? `Download All Day I Dream About Sports and follow ${T} in the team picker. Every ${T} goal, card and penalty from the 2026 World Cup dropped below the MacBook notch as it happened, and the pick is held for the next tournament.`
        : `Download All Day I Dream About Sports, open the team picker, and follow ${T}. Every ${T} goal, card, substitution and VAR decision then drops below your MacBook notch as it happens, and a live capsule pins the score to a corner of your screen.`,
    },
    {
      q: `Can I follow ${T} for free?`,
      a: `Yes — the app is free on ${site.requires}. There is no ${T} subscription, no tier and nothing to unlock; following ${T} costs the same as following nobody.`,
    },
    {
      q: `Will I get an alert the moment ${T} score?`,
      a: `Yes, and you can decide how loud it is${national ? " — this is how the 2026 tournament ran, and how 2030 will" : ""}. The goal alert drops under the notch, the capsule score updates, and if you want it, the goal takes over the screen so you can tap the ball and celebrate with fans worldwide. Goal-in-centre, confetti and the pop sound each have their own switch.`,
    },
    {
      q: `Can I follow ${T} and other teams at the same time?`,
      a: `Up to ${cap} teams at once, across any mix of leagues. Pin several matches at the same time and the capsules stack, so ${T}'s score and everyone else's sit side by side.`,
    },
    {
      q: national
        ? `Does it still cover ${T} between tournaments?`
        : `Does it cover every ${T} match in the ${L}?`,
      a: national
        ? `${T} are saved from the 2026 World Cup and held for 2030 — there are no international fixtures to alert on in between. In the meantime the five club leagues run live all season, so the app is not sitting idle.`
        : `Yes — every ${T} fixture in the ${L} season, with the full event timeline on each one. Stoppage time shows honestly as 45+3 or 90+, and the match clock ticks locally so the minute is right between polls.`,
    },
  ];
}

export default { home, forLeague, forTeam };
