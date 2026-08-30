// What the app actually does, read out of the app source rather than guessed:
// SettingsView.swift, MenuPopoverView.swift, TeamPickerView.swift,
// MatchModels.swift, Theme.swift and infra/remoteconfig.template.json.
//
// The home page carries the full set; league and team pages carry the same
// capabilities reworded around the competition or the club, so no two feature
// sections on the site read alike.
const home = [
  {
    h: "Every moment, dropped under the notch",
    p: "Goals, cards, substitutions and full-time alerts appear beneath your MacBook notch as each match unfolds.",
  },
  {
    h: "Capsules you can stack",
    p: "Pin several matches at once. Hover any capsule for the full event timeline - every goal, card and substitution.",
  },
  {
    h: "Celebrate the goal with everyone else",
    p: "When the goal alert arrives, celebrate on screen with fans around the world.",
    celebration: true,
  },
  {
    h: "Follow teams or leagues",
    p: "Choose the teams you care about or follow an entire league, and keep every match that matters close by.",
  },
];

/** Four concise rows, each naming the competition where it adds context. */
function forLeague(league) {
  const L = league.name;
  const isCup = league.type === "Cup";
  return [
    {
      h: `${L} goals, under your notch`,
      p: `Goals, cards, substitutions and full-time alerts from the ${L} appear beneath your MacBook notch throughout the match.`,
    },
    {
      h: `Pin the ${L} match to a corner`,
      p: `Pin several matches at once. Hover any capsule for the full event timeline - every goal, card and substitution.`,
    },
    {
      h: "Follow teams or leagues",
      p: `Choose the ${isCup ? "nations" : "clubs"} you care about, or follow the whole ${L}.`,
    },
    {
      h: `Celebrate the ${L} goal with the rest of the world`,
      p: `When a ${L} goal alert arrives, celebrate on screen with fans around the world.`,
      celebration: true,
    },
  ];
}

/** Four concise rows in the second person, each naming the club where useful. */
function forTeam(team) {
  const T = team.displayName;
  return [
    {
      h: `${T} goals, moments after they go in`,
      p: `When a ${T} goal alert arrives, it drops below your notch. Cards, substitutions and full-time arrive there too.`,
    },
    {
      h: `Pin the ${T} match to a corner`,
      p: "Pin several matches at once. Hover any capsule for the full event timeline - every goal, card and substitution.",
    },
    {
      h: `Celebrate ${T} goals with everyone else`,
      p: `When a ${T} goal alert arrives, celebrate on screen with fans around the world.`,
      celebration: true,
    },
    {
      h: "Follow teams or leagues",
      p: `Follow ${T}, add other teams you care about, or follow an entire league.`,
    },
  ];
}

export default { home, forLeague, forTeam };
