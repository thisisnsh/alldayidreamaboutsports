// 11ty config. Input is src/, output is _site/ — the same shape cuecard.dev
// uses, so the two sites stay easy to keep in step.
export default function (eleventyConfig) {
  // Static files that ship as-is. CNAME and .nojekyll are load-bearing:
  // without CNAME the custom domain drops, without .nojekyll Pages runs
  // Jekyll over the output and eats anything starting with an underscore.
  eleventyConfig.addPassthroughCopy({ "src/assets": "assets" });
  eleventyConfig.addPassthroughCopy("src/style.css");
  eleventyConfig.addPassthroughCopy("src/script.js");
  eleventyConfig.addPassthroughCopy("src/robots.txt");
  eleventyConfig.addPassthroughCopy("src/site.webmanifest");
  // Copied verbatim, never rendered: it is the noindex stub that redirects the
  // old /privacy.html URL to /privacy/, and must stay crawlable.
  eleventyConfig.addPassthroughCopy("src/privacy.html");
  eleventyConfig.ignores.add("src/privacy.html");
  eleventyConfig.addPassthroughCopy("src/*.png");
  eleventyConfig.addPassthroughCopy("src/*.ico");
  eleventyConfig.addPassthroughCopy({ "src/CNAME": "CNAME" });
  eleventyConfig.addPassthroughCopy({ "src/.nojekyll": ".nojekyll" });

  // Slug for a name that may carry accents or punctuation.
  eleventyConfig.addFilter("slugify", (s) =>
    String(s)
      .normalize("NFD")
      .replace(/[\u0300-\u036f]/g, "")
      .toLowerCase()
      .replace(/&/g, " and ")
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-+|-+$/g, "")
  );

  // JSON-LD is emitted from data, so it has to be escaped for a <script> block.
  eleventyConfig.addFilter("jsonld", (obj) =>
    JSON.stringify(obj, null, 2).replace(/</g, "\\u003c")
  );

  eleventyConfig.addFilter("pad", (n) => String(n).padStart(2, "0"));

  eleventyConfig.addFilter("take", (arr, n) => (arr || []).slice(0, n));

  // Rotate a list by an offset, so "more clubs from this league" blocks on
  // sibling pages point at different siblings instead of all at the first six.
  eleventyConfig.addFilter("rotate", (arr, n) => {
    const a = arr || [];
    if (!a.length) return a;
    const k = ((n % a.length) + a.length) % a.length;
    return a.slice(k).concat(a.slice(0, k));
  });

  eleventyConfig.addFilter("reject", (arr, key, value) =>
    (arr || []).filter((x) => x[key] !== value)
  );

  eleventyConfig.addFilter("where", (arr, key, value) =>
    (arr || []).filter((x) => x[key] === value)
  );

  eleventyConfig.addFilter("find", (arr, key, value) =>
    (arr || []).find((x) => x[key] === value)
  );

  // Pull specific records out of a list, in the order the ids were given.
  eleventyConfig.addFilter("pickIds", (arr, ids) => {
    const byId = new Map((arr || []).map((x) => [x.id, x]));
    return (ids || []).map((id) => byId.get(id)).filter(Boolean);
  });

  return {
    dir: {
      input: "src",
      output: "_site",
      includes: "_includes",
      data: "_data",
    },
    markdownTemplateEngine: "njk",
    htmlTemplateEngine: "njk",
    templateFormats: ["njk", "html", "md"],
  };
}
