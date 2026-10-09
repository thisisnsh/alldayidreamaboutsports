#!/usr/bin/env node
/**
 * Generates src/_data/leagues.json and src/_data/teams.json from the app's own
 * live catalog, and mirrors every league and team crest into src/assets/crests/
 * as a 96px WebP.
 *
 * Run by hand and commit the output - CI stays offline so a build is always
 * reproducible and never depends on the catalog being up.
 *
 *   node scripts/build-data.mjs
 *
 * Needs `sips` (macOS, built in) and `cwebp` (brew install webp).
 */
import { execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync, readFileSync, existsSync, rmSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import os from "node:os";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const CATALOG = "https://scores.alldayidreamaboutsports.com/catalog.json";
const CRESTS = join(ROOT, "src", "assets", "crests");
const DATA = join(ROOT, "src", "_data");

const slugify = (s) =>
  String(s)
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/&/g, " and ")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");

async function fetchJson(url) {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`${url} → ${res.status}`);
  return res.json();
}

/** Download a PNG, resize to 96px, write it out as WebP. Skips work already done. */
async function crest(url, outName) {
  const out = join(CRESTS, `${outName}.webp`);
  if (existsSync(out)) return;
  const res = await fetch(url);
  if (!res.ok) {
    console.warn(`  ! ${outName}: ${res.status} from source, skipped`);
    return;
  }
  const tmp = join(os.tmpdir(), `crest-${outName}-${process.pid}.png`);
  writeFileSync(tmp, Buffer.from(await res.arrayBuffer()));
  try {
    execFileSync("sips", ["-Z", "96", tmp, "--out", tmp], { stdio: "ignore" });
    execFileSync("cwebp", ["-quiet", "-q", "82", tmp, "-o", out], { stdio: "ignore" });
  } finally {
    rmSync(tmp, { force: true });
  }
}

const extrasPath = join(DATA, "teamExtras.json");
const extras = existsSync(extrasPath)
  ? JSON.parse(readFileSync(extrasPath, "utf8"))
  : {};

const catalog = await fetchJson(CATALOG);
mkdirSync(CRESTS, { recursive: true });

const leagues = catalog.leagues.map((l) => ({
  id: l.id,
  name: l.name,
  slug: slugify(l.name),
  type: l.type,
  country: l.country,
  season: l.season,
  active: l.active === true,
  ended: l.ended === true,
  crest: `/assets/crests/league-${l.id}.webp`,
  teamCount: (catalog.teams[String(l.id)] || []).length,
}));

// country → the league we cover there, used to point nation pages at clubs.
const clubLeagueByCountry = new Map(
  leagues.filter((l) => l.type !== "Cup").map((l) => [l.country, l.id])
);

const teams = [];
const seen = new Map();
for (const league of leagues) {
  for (const t of catalog.teams[String(league.id)] || []) {
    const extra = extras[String(t.id)] || {};
    const displayName = extra.displayName || t.name;
    // The slug comes from the catalog's short name, not the display name:
    // short names are already verified collision-free across all 144 teams,
    // and they keep the URL stable if a club's full name is ever restyled.
    const slug = extra.slug || slugify(t.name);
    if (seen.has(slug)) {
      throw new Error(
        `slug collision: "${slug}" wanted by ${displayName} (${t.id}) and ` +
          `${seen.get(slug)}. Add a displayName override in teamExtras.json.`
      );
    }
    seen.set(slug, `${displayName} (${t.id})`);
    teams.push({
      id: t.id,
      name: t.name,
      displayName,
      slug,
      code: t.code || null,
      country: t.country,
      leagueId: league.id,
      leagueName: league.name,
      leagueSlug: league.slug,
      national: league.type === "Cup",
      // For a national team, the club league we cover in that country - so a
      // nation page has somewhere real to send people while it has no fixtures.
      clubLeagueId:
        league.type === "Cup"
          ? clubLeagueByCountry.get(t.country) ?? null
          : null,
      crest: `/assets/crests/${t.id}.webp`,
    });
  }
}

console.log(`${leagues.length} leagues, ${teams.length} teams - mirroring crests…`);
for (const l of catalog.leagues) await crest(l.logo, `league-${l.id}`);
for (const list of Object.values(catalog.teams))
  for (const t of list) await crest(t.logo, String(t.id));

writeFileSync(join(DATA, "leagues.json"), JSON.stringify(leagues, null, 2) + "\n");
writeFileSync(join(DATA, "teams.json"), JSON.stringify(teams, null, 2) + "\n");
console.log(`wrote leagues.json, teams.json and ${leagues.length + teams.length} crests`);
