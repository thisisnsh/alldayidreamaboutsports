#!/usr/bin/env node
/**
 * Asserts everything §12 of the plan asks for, over the built _site/.
 * Runs in CI, so it must not touch the network.
 *
 *   node scripts/verify-build.mjs
 */
import { readFileSync, existsSync, readdirSync, statSync } from "node:fs";
import { join, dirname, relative } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const SITE = join(ROOT, "_site");
const ORIGIN = "https://alldayidreamaboutsports.com";
const DATA = join(ROOT, "src", "_data");
const EM_DASH = String.fromCodePoint(0x2014);

const fail = [];
const check = (ok, msg) => { if (!ok) fail.push(msg); };

function walk(dir, out = []) {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) walk(p, out);
    else out.push(p);
  }
  return out;
}

if (!existsSync(SITE)) {
  console.error("_site/ does not exist - run `npx @11ty/eleventy` first.");
  process.exit(1);
}

const files = walk(SITE);
const htmlFiles = files.filter((f) => f.endsWith(".html"));

/* ── catalog and authored content ─────────────────────────────────────── */
const leagues = JSON.parse(readFileSync(join(DATA, "leagues.json"), "utf8"));
const teams = JSON.parse(readFileSync(join(DATA, "teams.json"), "utf8"));
const extras = JSON.parse(readFileSync(join(DATA, "teamExtras.json"), "utf8"));
const leagueIds = new Set(leagues.map((league) => league.id));
const teamById = new Map(teams.map((team) => [team.id, team]));
const slugs = new Set();

check(teamById.size === teams.length, "duplicate team id in teams.json");
for (const team of teams) {
  check(!slugs.has(team.slug), `duplicate team slug: ${team.slug}`);
  slugs.add(team.slug);
  check(leagueIds.has(team.leagueId), `${team.displayName}: unknown league ${team.leagueId}`);

  const authored = extras[String(team.id)];
  check(!!authored, `${team.displayName}: missing teamExtras record`);
  check(!!authored?.blurb, `${team.displayName}: missing authored blurb`);
  check(!!authored?.leagueContext, `${team.displayName}: missing league context`);
  const relatedIds = new Set();
  for (const id of authored?.related || []) {
    const related = teamById.get(id);
    check(id !== team.id, `${team.displayName}: related list includes itself`);
    check(!relatedIds.has(id), `${team.displayName}: duplicate related team ${id}`);
    relatedIds.add(id);
    check(!!related, `${team.displayName}: unknown related team ${id}`);
    check(
      !related || related.leagueId === team.leagueId,
      `${team.displayName}: related team ${related?.displayName || id} is in another competition`
    );
  }
}
for (const id of Object.keys(extras)) {
  check(teamById.has(Number(id)), `teamExtras has orphan record ${id}`);
}

/* ── the page count ───────────────────────────────────────────────────── */
// 1 home + 2 hubs + 6 competitions + 144 teams + privacy + 404, plus the
// /privacy.html redirect stub that is copied rather than rendered.
const EXPECTED_PAGES = 155;
const stub = htmlFiles.filter((f) => f.endsWith("privacy.html")).length;
check(
  htmlFiles.length - stub === EXPECTED_PAGES,
  `expected ${EXPECTED_PAGES} rendered pages, found ${htmlFiles.length - stub}`
);

/* ── the files Pages cannot do without ────────────────────────────────── */
for (const f of ["CNAME", ".nojekyll", "robots.txt", "sitemap.xml", "style.css", "script.js", "privacy.html"]) {
  check(existsSync(join(SITE, f)), `missing ${f} in _site/`);
}

/* ── every sitemap <loc> is a page that actually built ────────────────── */
const sitemap = readFileSync(join(SITE, "sitemap.xml"), "utf8");
const locs = [...sitemap.matchAll(/<loc>([^<]+)<\/loc>/g)].map((m) => m[1]);
check(locs.length > 150, `sitemap has only ${locs.length} urls`);
const built = new Set(
  htmlFiles.map((f) => {
    const rel = "/" + relative(SITE, f).split("/").join("/");
    return rel.endsWith("/index.html") ? rel.slice(0, -"index.html".length) : rel;
  })
);
for (const loc of locs) {
  const path = loc.replace(ORIGIN, "");
  check(built.has(path), `sitemap lists ${loc} but ${path} did not build`);
}

/* ── per-page assertions ──────────────────────────────────────────────── */
const titles = new Map();
const descs = new Map();
const internalLinks = new Map(); // href → the pages that link to it
const noindex = new Set();

for (const file of htmlFiles) {
  const rel = "/" + relative(SITE, file);
  const html = readFileSync(file, "utf8");
  if (rel.endsWith("privacy.html")) continue;

  const url = rel.endsWith("/index.html") ? rel.slice(0, -"index.html".length) : rel;
  const isNoindex = /<meta name="robots" content="noindex/.test(html);
  if (isNoindex) noindex.add(url);

  check(!html.includes(EM_DASH), `${url}: contains an em dash`);
  check(!/\blive scores?\b/i.test(html), `${url}: implies that the website shows live scores`);

  const h1 = html.match(/<h1[\s>]/g) || [];
  check(h1.length === 1, `${url}: expected exactly one <h1>, found ${h1.length}`);

  const title = (html.match(/<title>([\s\S]*?)<\/title>/) || [])[1];
  check(!!title, `${url}: no <title>`);
  if (title && !isNoindex) {
    if (titles.has(title)) fail.push(`duplicate <title> on ${url} and ${titles.get(title)}: ${title}`);
    else titles.set(title, url);
  }

  const desc = (html.match(/<meta name="description" content="([\s\S]*?)" \/>/) || [])[1];
  check(!!desc, `${url}: no meta description`);
  if (desc && !isNoindex) {
    if (descs.has(desc)) fail.push(`duplicate meta description on ${url} and ${descs.get(desc)}`);
    else descs.set(desc, url);
  }

  check(
    html.includes(`<link rel="canonical" href="${ORIGIN}${url}" />`),
    `${url}: canonical is missing or points elsewhere`
  );

  // Every JSON-LD block on the page has to parse.
  for (const m of html.matchAll(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/g)) {
    try {
      const graph = JSON.parse(m[1])["@graph"];
      check(Array.isArray(graph) && graph.length >= 6, `${url}: @graph looks short`);
    } catch (e) {
      fail.push(`${url}: JSON-LD does not parse - ${e.message}`);
    }
  }

  // No third-party JavaScript anywhere on the site.
  for (const m of html.matchAll(/<script[^>]+src="(https?:)?\/\/([^"]+)"/g)) {
    fail.push(`${url}: third-party script from ${m[2]}`);
  }

  for (const m of html.matchAll(/href="(\/[^"#?]*)/g)) {
    const href = m[1];
    if (!internalLinks.has(href)) internalLinks.set(href, new Set());
    internalLinks.get(href).add(url);
  }
}

/* ── internal links all resolve ───────────────────────────────────────── */
const assets = new Set(files.map((f) => "/" + relative(SITE, f)));
for (const [href, from] of internalLinks) {
  const ok = built.has(href) || assets.has(href) || assets.has(href.replace(/\/$/, "/index.html"));
  check(ok, `dead internal link ${href} (from ${[...from][0]})`);
}

/* ── no orphans: every indexable page is linked from somewhere else ───── */
for (const url of built) {
  if (url === "/" || noindex.has(url) || url.endsWith("privacy.html")) continue;
  const linkers = internalLinks.get(url);
  const external = linkers && [...linkers].some((from) => from !== url);
  check(external, `orphan: nothing links to ${url}`);
}

/* ── report ──────────────────────────────────────────────────────────── */
if (fail.length) {
  console.error(`\n${fail.length} problem(s):\n`);
  for (const f of fail.slice(0, 40)) console.error("  ✗ " + f);
  if (fail.length > 40) console.error(`  … and ${fail.length - 40} more`);
  process.exit(1);
}
console.log(
  `✓ ${htmlFiles.length - stub} pages, ${locs.length} sitemap urls, ` +
    `${titles.size} unique titles, ${descs.size} unique descriptions, ` +
    `${internalLinks.size} internal link targets - all resolve, no orphans.`
);
