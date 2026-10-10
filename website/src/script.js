/* All Day I Dream About Sports: scroll reveals and responsive navigation. */

/* ───────────────────────── reveal on scroll ────────────────────────────── */
(() => {
  const items = document.querySelectorAll(".reveal");
  if (!items.length) return;

  if (
    !("IntersectionObserver" in window) ||
    window.matchMedia("(prefers-reduced-motion: reduce)").matches
  ) {
    items.forEach((el) => el.classList.add("in"));
    return;
  }

  const io = new IntersectionObserver(
    (entries) => {
      for (const e of entries) {
        if (!e.isIntersecting) continue;
        e.target.classList.add("in");
        io.unobserve(e.target);
      }
    },
    { rootMargin: "0px 0px -8% 0px", threshold: 0.05 }
  );
  items.forEach((el) => io.observe(el));
})();

/* ───────────────────────────── nav ─────────────────────────────────────── */
(() => {
  const nav = document.getElementById("nav");
  if (nav) {
    const onScroll = () => nav.classList.toggle("scrolled", window.scrollY > 12);
    onScroll();
    addEventListener("scroll", onScroll, { passive: true });
  }

  const toggle = document.getElementById("nav-toggle");
  const links = document.getElementById("nav-links");
  if (!toggle || !links) return;
  nav?.classList.add("nav-enhanced");

  const close = () => {
    links.classList.remove("open");
    toggle.setAttribute("aria-expanded", "false");
    toggle.setAttribute("aria-label", "Open menu");
  };
  close();

  toggle.addEventListener("click", () => {
    const open = links.classList.toggle("open");
    toggle.setAttribute("aria-expanded", String(open));
    toggle.setAttribute("aria-label", open ? "Close menu" : "Open menu");
  });
  links.addEventListener("click", (e) => {
    if (e.target.closest("a")) {
      close();
    }
  });
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape" && links.classList.contains("open")) {
      close();
      toggle.focus();
    }
  });
})();

/* The complete directory is server-rendered. Search only enhances browsing. */
(() => {
  const input = document.getElementById("team-search");
  const directory = document.getElementById("team-directory");
  const count = document.getElementById("search-count");
  if (!input || !directory || !count) return;
  const groups = [...directory.querySelectorAll("[data-team-group]")];
  const normalize = (text) => text.normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase().trim();
  const records = groups.map((group) => ({
    group,
    backlink: group.nextElementSibling?.matches(".backline") ? group.nextElementSibling : null,
    heading: normalize(group.querySelector("h2")?.textContent || ""),
    teams: [...group.querySelectorAll(".crestgrid li")].map((item) => ({
      item, name: normalize(item.dataset.searchName || item.textContent),
    })),
  }));
  const filter = () => {
    const query = normalize(input.value);
    let matches = 0;
    for (const { group, backlink, heading, teams } of records) {
      let visible = 0;
      for (const { item, name } of teams) {
        const show = !query || name.includes(query) || heading.includes(query);
        item.hidden = !show;
        if (show) visible++;
      }
      group.hidden = visible === 0;
      if (backlink) backlink.hidden = visible === 0;
      matches += visible;
    }
    count.textContent = matches === 0
      ? "No teams found. Try another team or league name."
      : `${matches} ${matches === 1 ? "team" : "teams"}${query ? " found" : " to explore"}.`;
    document.querySelectorAll(".league-jumps a").forEach((link) => {
      const target = document.getElementById(link.hash.slice(1));
      link.hidden = !!target?.hidden;
    });
  };
  input.addEventListener("input", filter);
  input.closest(".team-search").hidden = false;
  filter();
})();
