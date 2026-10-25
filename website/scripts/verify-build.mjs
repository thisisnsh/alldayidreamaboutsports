#!/usr/bin/env node
/**
 * Checks SEO metadata, crawlability and content over the built _site/.
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
// Nunjucks escapes attributes; JSON-LD contains the original text.
const decodeHtml = (value) => value?.replace(/&(?:amp|lt|gt|quot|apos|#39|#x27);/g,
  (entity) => ({ "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": '"', "&apos;": "'", "&#39;": "'", "&#x27;": "'" })[entity]);

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
// Home, two hubs, competitions, teams, support, privacy and 404, plus the
// /privacy.html and /comingsoon/ redirect stubs that are copied rather than rendered.
const APP_STORE = "https://apps.apple.com/app/all-day-i-dream-about-sports/id6818873010";
const STUBS = ["/privacy.html", "/comingsoon/"];
const isStub = (file) => STUBS.includes(("/" + relative(SITE, file)).replace(/index\.html$/, ""));
const EXPECTED_PAGES = 6 + leagues.length + teams.length;
const stub = htmlFiles.filter(isStub).length;
check(
  htmlFiles.length - stub === EXPECTED_PAGES,
  `expected ${EXPECTED_PAGES} rendered pages, found ${htmlFiles.length - stub}`
);

/* ── the files Pages cannot do without ────────────────────────────────── */
for (const f of ["CNAME", ".nojekyll", "robots.txt", "sitemap.xml", "style.css", "script.js", "privacy.html"]) {
  check(existsSync(join(SITE, f)), `missing ${f} in _site/`);
}

const homeHtml = readFileSync(join(SITE, "index.html"), "utf8");
check(/<iframe[^>]+src="https:\/\/www\.youtube-nocookie\.com\/embed\/B75DYFddkV0"/.test(homeHtml),
  "homepage is missing the embedded YouTube demo");
check(!homeHtml.includes("autoplay=1"), "the YouTube demo must not autoplay");
check(stub === STUBS.length, "missing a redirect stub (/privacy.html or /comingsoon/)");
check(readFileSync(join(SITE, "comingsoon", "index.html"), "utf8").includes(`url=${APP_STORE}`),
  "/comingsoon/ must redirect to the App Store");
for (const file of files.filter((f) => /\.(html|js|css)$/.test(f))) {
  const source = readFileSync(file, "utf8");
  check(!/download(?:-staging)?\.alldayidreamaboutsports\.com/.test(source),
    `${relative(SITE, file)}: references a retired download hostname`);
  check(!/bgvideo|videobg|video-loading/.test(source),
    `${relative(SITE, file)}: still contains the retired background video`);
}

/* ── every sitemap <loc> is a page that actually built ────────────────── */
const sitemap = readFileSync(join(SITE, "sitemap.xml"), "utf8");
const locs = [...sitemap.matchAll(/<loc>([^<]+)<\/loc>/g)].map((m) => m[1]);
check(new Set(locs).size === locs.length, "sitemap contains duplicate URLs");
const built = new Set(
  htmlFiles.map((f) => {
    const rel = "/" + relative(SITE, f).split("/").join("/");
    return rel.endsWith("/index.html") ? rel.slice(0, -"index.html".length) : rel;
  })
);
for (const loc of locs) {
  check(loc.startsWith(`${ORIGIN}/`), `sitemap lists a noncanonical origin: ${loc}`);
  const path = loc.replace(ORIGIN, "");
  check(built.has(path), `sitemap lists ${loc} but ${path} did not build`);
}

/* ── per-page assertions ──────────────────────────────────────────────── */
const titles = new Map();
const descs = new Map();
const internalLinks = new Map(); // href → the pages that link to it
const noindex = new Set();
const fragments = new Map(htmlFiles.map((file) => {
  const rel = "/" + relative(SITE, file);
  const url = rel.endsWith("/index.html") ? rel.slice(0, -"index.html".length) : rel;
  const html = readFileSync(file, "utf8");
  const ids = [...html.matchAll(/\bid="([^"]+)"/g)].map((m) => m[1]);
  check(new Set(ids).size === ids.length, `${url}: duplicate element ids`);
  return [url, new Set(ids)];
}));

for (const file of htmlFiles) {
  const rel = "/" + relative(SITE, file);
  const html = readFileSync(file, "utf8");
  if (isStub(file)) continue;

  const url = rel.endsWith("/index.html") ? rel.slice(0, -"index.html".length) : rel;
  const isNoindex = /<meta name="robots" content="noindex/.test(html);
  if (isNoindex) noindex.add(url);

  check(!html.includes(EM_DASH), `${url}: contains an em dash`);
  check(!/\blive scores?\b/i.test(html), `${url}: implies that the website shows live scores`);
  for (const match of html.matchAll(/<a\b[^>]*href="([^"]+)"[^>]*>(?:(?!<\/a>)[\s\S])*?(?:Download|App Store)[^<]*<\/a>/g)) {
    check(match[1] === APP_STORE, `${url}: download button does not point to the App Store`);
  }
  check(!/coming to the (?:mac )?app store|launching on|comingsoon/i.test(html), `${url}: still announces a pending launch`);

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
  check(html.includes(`<meta property="og:url" content="${ORIGIN}${url}" />`),
    `${url}: social URL differs from canonical`);

  // Every JSON-LD block on the page has to parse.
  const schemaBlocks = [...html.matchAll(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/g)];
  check(schemaBlocks.length > 0, `${url}: missing structured data`);
  for (const m of schemaBlocks) {
    try {
      const graph = JSON.parse(m[1])["@graph"];
      check(Array.isArray(graph) && graph.length >= 5, `${url}: @graph looks short`);
      const hasVideo = graph.some((node) => node["@type"] === "VideoObject");
      check(hasVideo === (url === "/"), `${url}: video schema must describe the homepage's visible demo`);
      const webpage = graph.find((node) => node["@id"] === `${ORIGIN}${url}#webpage`);
      check(webpage?.url === `${ORIGIN}${url}`, `${url}: schema page URL differs from canonical`);
      check(webpage?.description === decodeHtml(desc), `${url}: schema description differs from meta description`);
      const video = graph.find((node) => node["@type"] === "VideoObject");
      if (video) {
        check(html.includes(`src="${video.embedUrl}"`), `${url}: video schema player is not embedded`);
        check(!video.contentUrl, `${url}: YouTube provides an embed URL, not a direct video content URL`);
      }
      const directory = graph.find((node) => node["@type"] === "ItemList");
      if (url === "/teams/" || url === "/leagues/") {
        const expected = url === "/teams/" ? teams : leagues;
        check(webpage?.["@type"] === "CollectionPage", `${url}: directory must be a CollectionPage`);
        check(webpage?.mainEntity?.["@id"] === directory?.["@id"], `${url}: page must reference its directory`);
        check(directory?.numberOfItems === expected.length, `${url}: wrong directory size`);
        check(directory?.itemListElement?.length === expected.length, `${url}: incomplete directory schema`);
        for (const [i, entry] of (directory?.itemListElement || []).entries()) {
          const record = expected[i];
          const path = url === "/teams/" ? `/teams/${record?.slug}/` : `/${record?.slug}/`;
          check(entry.position === i + 1, `${url}: invalid directory position`);
          check(entry.url === `${ORIGIN}${path}`, `${url}: wrong directory entry URL`);
          check(entry.name === (record?.displayName || record?.name), `${url}: wrong directory entry name`);
          check(html.includes(`href="${path}"`), `${url}: directory schema entry has no visible link`);
        }
      }
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

  for (const m of html.matchAll(/href="((?:\/[^"#?]*)?)#([^"]+)"/g)) {
    const target = m[1] || url;
    check(fragments.get(target)?.has(m[2]), `${url}: broken section link ${m[1]}#${m[2]}`);
  }
  for (const m of html.matchAll(/<img\b[^>]*src="(\/[^"]+)"/g)) {
    check(existsSync(join(SITE, m[1])), `${url}: missing image ${m[1]}`);
  }
}

/* ── sitemap exactly covers the indexable pages ───────────────────────── */
const sitemapUrls = new Set(locs);
for (const url of built) {
  const indexable = !noindex.has(url) && !STUBS.includes(url);
  check(sitemapUrls.has(`${ORIGIN}${url}`) === indexable,
    indexable ? `indexable page missing from sitemap: ${url}` : `noindex page included in sitemap: ${url}`);
}

/* ── internal links all resolve ───────────────────────────────────────── */
const assets = new Set(files.map((f) => "/" + relative(SITE, f)));
for (const [href, from] of internalLinks) {
  const ok = built.has(href) || assets.has(href) || assets.has(href.replace(/\/$/, "/index.html"));
  check(ok, `dead internal link ${href} (from ${[...from][0]})`);
}

/* ── no orphans: every indexable page is linked from somewhere else ───── */
for (const url of built) {
  if (url === "/" || noindex.has(url) || STUBS.includes(url)) continue;
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
