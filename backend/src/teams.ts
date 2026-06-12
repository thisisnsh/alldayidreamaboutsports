import type { TeamCode } from "./types.js";

export interface Team {
  code: TeamCode; // FIFA trigram
  name: string;
  flag: string; // emoji — explicit because ENG/SCO can't be derived from ISO codes
}

/**
 * WC2026 teams. 42 qualified as of the Nov 2025 draw; the 6 playoff slots
 * (decided March 2026) are refreshed from API-Football by /internal/sync-static,
 * which regenerates teams.json on the CDN. This list is the bundled fallback.
 */
export const TEAMS: Team[] = [
  { code: "ALG", name: "Algeria", flag: "🇩🇿" },
  { code: "ARG", name: "Argentina", flag: "🇦🇷" },
  { code: "AUS", name: "Australia", flag: "🇦🇺" },
  { code: "AUT", name: "Austria", flag: "🇦🇹" },
  { code: "BEL", name: "Belgium", flag: "🇧🇪" },
  { code: "BRA", name: "Brazil", flag: "🇧🇷" },
  { code: "CAN", name: "Canada", flag: "🇨🇦" },
  { code: "CPV", name: "Cape Verde", flag: "🇨🇻" },
  { code: "CIV", name: "Côte d'Ivoire", flag: "🇨🇮" },
  { code: "COL", name: "Colombia", flag: "🇨🇴" },
  { code: "CRO", name: "Croatia", flag: "🇭🇷" },
  { code: "CUW", name: "Curaçao", flag: "🇨🇼" },
  { code: "ECU", name: "Ecuador", flag: "🇪🇨" },
  { code: "EGY", name: "Egypt", flag: "🇪🇬" },
  { code: "ENG", name: "England", flag: "🏴󠁧󠁢󠁥󠁮󠁧󠁿" },
  { code: "FRA", name: "France", flag: "🇫🇷" },
  { code: "GER", name: "Germany", flag: "🇩🇪" },
  { code: "GHA", name: "Ghana", flag: "🇬🇭" },
  { code: "HAI", name: "Haiti", flag: "🇭🇹" },
  { code: "IRN", name: "Iran", flag: "🇮🇷" },
  { code: "JPN", name: "Japan", flag: "🇯🇵" },
  { code: "JOR", name: "Jordan", flag: "🇯🇴" },
  { code: "KOR", name: "South Korea", flag: "🇰🇷" },
  { code: "KSA", name: "Saudi Arabia", flag: "🇸🇦" },
  { code: "MAR", name: "Morocco", flag: "🇲🇦" },
  { code: "MEX", name: "Mexico", flag: "🇲🇽" },
  { code: "NED", name: "Netherlands", flag: "🇳🇱" },
  { code: "NOR", name: "Norway", flag: "🇳🇴" },
  { code: "NZL", name: "New Zealand", flag: "🇳🇿" },
  { code: "PAN", name: "Panama", flag: "🇵🇦" },
  { code: "PAR", name: "Paraguay", flag: "🇵🇾" },
  { code: "POR", name: "Portugal", flag: "🇵🇹" },
  { code: "QAT", name: "Qatar", flag: "🇶🇦" },
  { code: "RSA", name: "South Africa", flag: "🇿🇦" },
  { code: "SCO", name: "Scotland", flag: "🏴󠁧󠁢󠁳󠁣󠁴󠁿" },
  { code: "SEN", name: "Senegal", flag: "🇸🇳" },
  { code: "ESP", name: "Spain", flag: "🇪🇸" },
  { code: "SUI", name: "Switzerland", flag: "🇨🇭" },
  { code: "TUN", name: "Tunisia", flag: "🇹🇳" },
  { code: "USA", name: "United States", flag: "🇺🇸" },
  { code: "URU", name: "Uruguay", flag: "🇺🇾" },
  { code: "UZB", name: "Uzbekistan", flag: "🇺🇿" },
];

/** API-Football team names → our codes, for names that don't match TEAMS[].name. */
const NAME_ALIASES: Record<string, TeamCode> = {
  "Ivory Coast": "CIV",
  "Cote d'Ivoire": "CIV",
  "South Korea": "KOR",
  "Korea Republic": "KOR",
  USA: "USA",
  "United States": "USA",
  "Cabo Verde": "CPV",
  "Cape Verde Islands": "CPV",
  Curacao: "CUW",
  "IR Iran": "IRN",
};

const byName = new Map<string, Team>(TEAMS.map((t) => [t.name.toLowerCase(), t]));

export function teamCodeForName(name: string): TeamCode {
  const alias = NAME_ALIASES[name];
  if (alias) return alias;
  const team = byName.get(name.toLowerCase());
  if (team) return team.code;
  // Unknown (e.g. a March-2026 playoff qualifier missing from the seed):
  // derive a stable, topic-safe code from the name.
  return name.replace(/[^a-zA-Z]/g, "").slice(0, 3).toUpperCase() || "UNK";
}

export function teamForCode(code: TeamCode): Team | undefined {
  return TEAMS.find((t) => t.code === code);
}
