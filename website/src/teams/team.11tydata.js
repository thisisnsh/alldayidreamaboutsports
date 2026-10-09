// Everything computed for a team page. The authored record in teamExtras.json
// is what stops 144 pages built from the same four catalog fields reading like
// 144 copies of each other, so the intro, the related-teams block and the second
// paragraph all come from there.
import teamExtras from "../_data/teamExtras.json" with { type: "json" };
import faq from "../_data/faq.js";

const extrasFor = (id) => teamExtras[String(id)] || {};
const publicCatalogName = (name) => String(name).replace(/^1\.\s+/, "");

// 11ty runs computed functions once against a dependency-detecting proxy, where
// the data values are not yet real arrays. Everything here has to survive that
// pass, so read lists through this.
const list = (v) => (Array.isArray(v) ? v : []);

export default {
  eleventyComputed: {
    extras: (data) => extrasFor(data.team.id),
    league: (data) => list(data.leagues).find((l) => l.id === data.team.leagueId),

    title: (data) =>
      `Follow ${data.team.displayName} on Mac - Free Match Alerts`,
    description: (data) => {
      const t = data.team;
      return t.national
        ? `Follow ${t.displayName} on your Mac. Every goal, card and VAR call from the 2026 World Cup dropped below your MacBook notch - saved and ready for 2030. Free for macOS.`
        : `Follow ${t.displayName} on your Mac. Every goal, card, substitution and VAR call from the ${t.leagueName} dropped below your MacBook notch, with the score pinned to a corner. Free for macOS.`;
    },
    keywords: (data) => {
      const t = data.team;
      const n = t.displayName;
      const catalogName = publicCatalogName(t.name);
      const short = catalogName !== n ? `${catalogName} match alerts, ` : "";
      return `${n} match alerts, ${short}follow ${n} on Mac, ${n} goal alerts, ${n} notifications macOS, ${t.leagueName} match alerts`;
    },
    pageName: (data) => `Follow ${data.team.displayName} on your Mac`,

    heroSub: (data) => {
      const t = data.team;
      const e = extrasFor(t.id);
      const nick = e.nickname ? ` - ${e.nickname} - ` : " ";
      return t.national
        ? `Every ${t.displayName} goal, card and penalty from the 2026 World Cup landed below your MacBook notch during the tournament. ${t.displayName}${nick}stay saved in the app, ready for 2030.`
        : `${t.displayName} goals, cards, substitutions and VAR decisions drop below your MacBook notch throughout the match, and the ${t.leagueName} scoreline pins to a corner of your screen while you work.`;
    },

    introHeading: (data) => {
      const t = data.team;
      const e = extrasFor(t.id);
      return e.nickname
        ? `Why ${t.displayName} are worth an alert`
        : `${t.displayName}, in short`;
    },

    // The second paragraph, built from the authored leagueContext so no two
    // team pages carry the same one.
    introSecond: (data) => {
      const t = data.team;
      const e = extrasFor(t.id);
      const ctx = e.leagueContext ? `, ${e.leagueContext},` : "";
      const alias =
        publicCatalogName(t.name) !== t.displayName
          ? ` (you will hear them called simply ${publicCatalogName(t.name)})`
          : "";
      return t.national
        ? `${t.displayName}${ctx} are saved from the 2026 World Cup${alias}. There are no international fixtures to alert on between tournaments, so this page is here for when 2030 comes around - and the club leagues run every week in the meantime.`
        : `${t.displayName}${ctx} play in the ${t.leagueName}${alias}. Follow them in the app and keep up with every one of their fixtures this season on your Mac - no tab, no phone, no refreshing.`;
    },

    relatedTeams: (data) => {
      const ids = extrasFor(data.team.id).related || [];
      const all = list(data.teams);
      return ids.map((id) => all.find((t) => t.id === id)).filter(Boolean);
    },

    // Six clubs from the same competition, rotated by this club's own position
    // so the sibling links form a chain rather than all pointing at the first six.
    // Related teams are left out because they already have a block of their own.
    siblings: (data) => {
      const relatedIds = extrasFor(data.team.id).related || [];
      const pool = list(data.teams).filter(
        (t) =>
          t.leagueId === data.team.leagueId &&
          t.id !== data.team.id &&
          !relatedIds.includes(t.id)
      );
      if (!pool.length) return [];
      const idx = pool.findIndex((t) => t.id > data.team.id);
      const k = ((idx < 0 ? 0 : idx) + pool.length) % pool.length;
      return pool.slice(k).concat(pool.slice(0, k)).slice(0, 6);
    },

    // For a national side, the club league we cover in that country - so the
    // page has somewhere live to send people while the nation has no fixtures.
    clubLeague: (data) =>
      data.team.clubLeagueId
        ? list(data.leagues).find((l) => l.id === data.team.clubLeagueId)
        : null,

    countryClubs: (data) =>
      data.team.clubLeagueId
        ? list(data.teams)
            .filter((t) => t.leagueId === data.team.clubLeagueId)
            .slice(0, 6)
        : [],

    siblingHeading: (data) =>
      data.team.national
        ? "More nations from 2026"
        : `More ${data.team.leagueName} clubs to follow`,

    crumbs: (data) => [
      { name: "Home", url: "/" },
      {
        name: data.team.leagueName,
        url: `/${data.team.leagueSlug}/`,
      },
      { name: data.team.displayName, url: `/teams/${data.team.slug}/` },
    ],

    faqItems: (data) =>
      faq.forTeam(
        data.team,
        list(data.leagues).find((l) => l.id === data.team.leagueId) || {}
      ),
  },
};
