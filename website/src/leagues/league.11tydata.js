// Everything computed for a competition page. Pagination resolves `league`
// before computed data runs, so each of the six pages gets its own title,
// description, keywords, breadcrumbs and FAQ set rather than a shared one.
import leagueExtras from "../_data/leagueExtras.json" with { type: "json" };
import faq from "../_data/faq.js";

// See the note in teams/team.11tydata.js: computed data runs once against a
// proxy where the arrays are not yet arrays.
const list = (v) => (Array.isArray(v) ? v : []);

export default {
  eleventyComputed: {
    extras: (data) => leagueExtras[String(data.league.id)] || {},
    title: (data) => `${data.league.name} Match Alerts on Mac - Free`,
    description: (data) =>
      (leagueExtras[String(data.league.id)] || {}).heroSub,
    keywords: (data) => (leagueExtras[String(data.league.id)] || {}).keywords,
    pageName: (data) => `${data.league.name} match alerts on your Mac`,
    introHeading: (data) =>
      data.league.type === "Cup"
        ? "One summer, every match, and what happens next"
        : `The ${data.league.name} does not wait for your calendar`,
    crumbs: (data) => [
      { name: "Home", url: "/" },
      { name: "Leagues", url: "/leagues/" },
      { name: data.league.name, url: `/${data.league.slug}/` },
    ],
    faqItems: (data) =>
      faq.forLeague(data.league),
  },
};
