/* ═══════════════════════════════════════════════════════════════════════════
   All Day I Dream About Sports — site behaviour.

   Three things, none of which block anything:
     1. the fixed background video, loaded only when it is worth loading
     2. reveal-on-scroll
     3. the nav (scrolled state, and the toggle on small screens)
   ═══════════════════════════════════════════════════════════════════════════ */

/* ───────────────────────── background video ────────────────────────────── */
(() => {
  const video = document.getElementById("bgvideo");
  const bar = document.getElementById("bufferbar");
  const poster = document.querySelector(".videobg-poster");

  // If the poster itself is unreachable, hide it rather than leave a browser's
  // broken-image mark sitting behind the hero.
  if (poster) poster.addEventListener("error", () => poster.remove(), { once: true });

  if (!video) return;

  // Who does not get 20MB of video: phones, anyone who asked for less motion,
  // and anyone whose browser says they are trying to save data. They keep the
  // poster, which is the video's own first frame, so nothing looks missing.
  const conn = navigator.connection || {};
  const skip =
    window.matchMedia("(max-width: 767px)").matches ||
    window.matchMedia("(prefers-reduced-motion: reduce)").matches ||
    conn.saveData === true;

  if (skip) {
    video.remove();
    return;
  }

  const add = (type, src) => {
    if (!src) return;
    const s = document.createElement("source");
    s.type = type;
    s.src = src;
    video.appendChild(s);
  };
  add("video/webm", video.dataset.webm);
  add("video/mp4", video.dataset.mp4);

  // A hairline rule at the top of the viewport, showing the buffer filling.
  // A status, not a spinner — it never asks to be looked at.
  let done = false;
  const progress = () => {
    if (done || !bar) return;
    const d = video.duration;
    if (!d || !video.buffered.length) return;
    bar.hidden = false;
    bar.firstElementChild.style.transform = `scaleX(${Math.min(
      1,
      video.buffered.end(video.buffered.length - 1) / d
    )})`;
  };

  const settle = () => {
    if (done) return;
    done = true;
    if (bar) bar.hidden = true;
  };

  video.addEventListener("progress", progress);
  video.addEventListener("loadedmetadata", progress);

  video.addEventListener(
    "canplay",
    () => {
      settle();
      // The poster stays underneath, so the crossfade has nothing to reveal.
      video.classList.add("is-ready");
      const p = video.play();
      if (p && p.catch) p.catch(() => {});
    },
    { once: true }
  );

  // If it never arrives, the poster simply remains and nothing is broken.
  video.addEventListener("error", settle, { once: true });

  video.preload = "auto";
  video.load();
})();

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
