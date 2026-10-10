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

  toggle.addEventListener("click", () => {
    const open = links.classList.toggle("open");
    toggle.setAttribute("aria-expanded", String(open));
  });
  links.addEventListener("click", (e) => {
    if (e.target.closest("a")) {
      links.classList.remove("open");
      toggle.setAttribute("aria-expanded", "false");
    }
  });
})();
