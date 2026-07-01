/* ═══════════════════════════════════════════════════════════════════════════
   All Day I Dream About Sports — interactive app preview

   No 3D, no framework. A single scripted timeline of the 2022 World Cup Final
   (Argentina vs France) drives three faithful pieces of the macOS app at once:
     · the notch-drop notification pills
     · the menu-bar dropdown fixture (live score + minute)
     · the goal-in-center celebration (tap the ball to celebrate with the world)
   ═══════════════════════════════════════════════════════════════════════════ */

const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
const rand = (a, b) => a + Math.random() * (b - a);
const pick = (a) => a[(Math.random() * a.length) | 0];

const TEAMS = {
  ARG: { name: "Argentina", crest: "assets/team-arg.png" },
  FRA: { name: "France", crest: "assets/team-fra.png" },
};

/* ── event-type → SF-symbol-ish icon + status tone (mirrors EventRouter.swift) */
const ICON = {
  ball: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><polygon points="12,7 16.3,10.1 14.7,15 9.3,15 7.7,10.1" fill="currentColor" stroke="none"/><path d="M12 3v4M4.7 9.3l3.7 .8M19.3 9.3l-3.7 .8M7.7 20l1.6-5M16.3 20l-1.6-5"/></svg>',
  card: '<svg viewBox="0 0 24 24" fill="currentColor"><rect x="7" y="4" width="10" height="16" rx="2.5"/></svg>',
  flag: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M5 3v18"/><path d="M5 4h12l-2 3.5L17 11H5"/></svg>',
  clock: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><path d="M12 7.5V12l3 2"/></svg>',
  target: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="8.5"/><circle cx="12" cy="12" r="3" fill="currentColor" stroke="none"/></svg>',
};
const TYPE = {
  kickoff: { ic: "flag", tone: "green" },
  goal: { ic: "ball", tone: "white" },
  yellow: { ic: "card", tone: "yellow" },
  red: { ic: "card", tone: "red" },
  half: { ic: "clock", tone: "white" },
  break: { ic: "clock", tone: "white" },
  pengood: { ic: "target", tone: "green" },
  penmiss: { ic: "target", tone: "red" },
  win: { ic: "flag", tone: "green" },
};

/* ── the 2022 Final, event by event (Argentina = home) ─────────────────────*/
const FINAL = [
  { min: "0'", type: "kickoff", label: "Kick-off", h: 0, a: 0, sub: "Argentina vs France · Final" },
  { min: "23'", type: "goal", label: "Goal", who: "Messi", team: "ARG", h: 1, a: 0, sub: "Penalty · Argentina 1–0 France", celebrate: true },
  { min: "36'", type: "goal", label: "Goal", who: "Di María", team: "ARG", h: 2, a: 0, celebrate: true },
  { min: "45+7", type: "yellow", label: "Yellow card", who: "E. Fernández", team: "ARG", h: 2, a: 0 },
  { min: "HT", type: "half", label: "Half-time", h: 2, a: 0, fx: "ht" },
  { min: "55'", type: "yellow", label: "Yellow card", who: "Rabiot", team: "FRA", h: 2, a: 0 },
  { min: "80'", type: "goal", label: "Goal", who: "Mbappé", team: "FRA", h: 2, a: 1, sub: "Penalty · Argentina 2–1 France", celebrate: true },
  { min: "81'", type: "goal", label: "Goal", who: "Mbappé", team: "FRA", h: 2, a: 2, celebrate: true },
  { min: "90+3", type: "break", label: "Full-time · to extra time", h: 2, a: 2, fx: "break" },
  { min: "108'", type: "goal", label: "Goal", who: "Messi", team: "ARG", h: 3, a: 2, celebrate: true },
  { min: "116'", type: "yellow", label: "Yellow card", who: "Montiel", team: "ARG", h: 3, a: 2 },
  { min: "118'", type: "goal", label: "Goal", who: "Mbappé", team: "FRA", h: 3, a: 3, sub: "Penalty · Argentina 3–3 France · hat-trick", celebrate: true },
  { min: "120+3", type: "break", label: "Extra time ends — penalties", h: 3, a: 3, fx: "break" },
  { min: "PENS", type: "pengood", label: "Penalty scored", who: "Messi", team: "ARG", h: 3, a: 3, sub: "Shootout · Argentina lead 1–0", fx: "pens" },
  { min: "PENS", type: "pengood", label: "Penalty scored", who: "Mbappé", team: "FRA", h: 3, a: 3, sub: "Shootout · level 1–1", fx: "pens" },
  { min: "PENS", type: "pengood", label: "Penalty scored", who: "Dybala", team: "ARG", h: 3, a: 3, sub: "Shootout · Argentina lead 2–1", fx: "pens" },
  { min: "PENS", type: "penmiss", label: "Penalty saved", who: "Coman", team: "FRA", h: 3, a: 3, sub: "Shootout · Martínez saves · 2–1", fx: "pens" },
  { min: "PENS", type: "pengood", label: "Penalty scored", who: "Paredes", team: "ARG", h: 3, a: 3, sub: "Shootout · Argentina lead 3–1", fx: "pens" },
  { min: "PENS", type: "penmiss", label: "Penalty missed", who: "Tchouaméni", team: "FRA", h: 3, a: 3, sub: "Shootout · wide · 3–1", fx: "pens" },
  { min: "PENS", type: "win", label: "Montiel scores — Argentina win!", team: "ARG", h: 3, a: 3, sub: "Champions · 4–2 on penalties", celebrate: true, fx: "ft" },
];

/* ═══════════════════════════════════════════════════════════════════════════
   DOM
   ═══════════════════════════════════════════════════════════════════════════ */
const $ = (id) => document.getElementById(id);
const pillstack = $("pillstack");
const appmenu = $("appmenu");
const trayApp = $("trayApp");
const macframe = $("macframe");
const fixtureRow = $("fixtureRow");
const fxEmpty = $("fxEmpty");
const scoreH = $("scoreH");
const scoreA = $("scoreA");
const fxTrail = $("fxTrail");
const fxMin = $("fxMin");
const cbOverlay = $("cbOverlay");
const cbBall = $("cbBall");
const cbBadge = $("cbBadge");
const cbCount = $("cbCount");
const playBtn = $("playBtn");
const playLabel = $("playLabel");
const playIco = playBtn ? playBtn.querySelector(".play-ico") : null;

/* live clock in the faux menu bar */
const trayClock = $("trayClock");
if (trayClock) {
  const d = new Date();
  const day = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][d.getDay()];
  let h = d.getHours(), m = d.getMinutes();
  const ap = h >= 12 ? "PM" : "AM"; h = h % 12 || 12;
  trayClock.textContent = `${day} ${h}:${String(m).padStart(2, "0")} ${ap}`;
}

/* ═══════════════════════════════════════════════════════════════════════════
   Notch pills
   ═══════════════════════════════════════════════════════════════════════════ */
function pillHTML(ev) {
  const t = TYPE[ev.type] || TYPE.break;
  const crest = ev.team ? `<img class="pill-crest" src="${TEAMS[ev.team].crest}" alt="${TEAMS[ev.team].name}" />` : "";
  const who = ev.who ? ` — <b>${ev.who}</b>` : "";
  const sub = ev.sub || `${TEAMS.ARG.name} ${ev.h} – ${ev.a} ${TEAMS.FRA.name}`;
  return (
    `<span class="pill-ic" data-tone="${t.tone}">${ICON[t.ic]}</span>` +
    `<span class="pill-body">` +
      `<span class="pill-title"><span class="min">${ev.min}</span> ${ev.label}${who}${crest}</span>` +
      `<span class="pill-sub">${sub}</span>` +
    `</span>`
  );
}
function dropPill(ev, animate = true) {
  if (!pillstack) return;
  const el = document.createElement("div");
  el.className = animate ? "pill drop" : "pill";
  el.innerHTML = pillHTML(ev);
  pillstack.prepend(el);
  while (pillstack.children.length > 3) pillstack.lastChild.remove();
}

/* ═══════════════════════════════════════════════════════════════════════════
   Menu-bar fixture row
   ═══════════════════════════════════════════════════════════════════════════ */
function updateFixture(ev) {
  if (!fixtureRow) return;
  fxEmpty.hidden = true;
  fixtureRow.hidden = false;
  scoreH.textContent = ev.h;
  scoreA.textContent = ev.a;
  const st = ev.fx || "live";
  fxTrail.className = "fx-trail" + (st === "ft" ? " ft" : st === "live" || st === "pens" ? " live" : "");
  fxMin.textContent =
    st === "ft" ? "FT" : st === "ht" ? "HT" : st === "pens" ? "PENS" : st === "break" ? ev.min : ev.min;
}

/* ═══════════════════════════════════════════════════════════════════════════
   Goal-in-center celebration
   ═══════════════════════════════════════════════════════════════════════════ */
let celebrations = 2314608;
if (cbCount) cbCount.textContent = celebrations.toLocaleString("en-US");

let cbTimer = null;
function showCelebration(team) {
  if (!cbOverlay) return;
  if (cbBadge && team) cbBadge.innerHTML = `<img src="${TEAMS[team].crest}" alt="${TEAMS[team].name}" width="26" height="26" />`;
  cbOverlay.classList.add("show");
  cbOverlay.setAttribute("aria-hidden", "false");
  // the goal takes over the screen, then fades so the menu returns
  clearTimeout(cbTimer);
  cbTimer = setTimeout(hideCelebration, reduceMotion ? 2600 : 2800);
  if (!reduceMotion) {
    burstConfetti(1);
    bumpCelebrations(Math.floor(rand(1400, 4200)));
  }
}
function hideCelebration() {
  if (!cbOverlay) return;
  cbOverlay.classList.remove("show");
  cbOverlay.setAttribute("aria-hidden", "true");
}
function bumpCelebrations(n) {
  celebrations += n;
  if (cbCount) cbCount.textContent = celebrations.toLocaleString("en-US");
}

/* tap the ball → celebrate with the world */
if (cbBall) {
  cbBall.addEventListener("click", () => {
    bumpCelebrations(Math.floor(rand(1, 5)));
    const r = cbBall.getBoundingClientRect();
    if (!reduceMotion) {
      burstConfetti(0.5, { x: r.left + r.width / 2, y: r.top + r.height / 2 });
      popBall(r);
    }
  });
}
/* little balls that fly off when you tap */
function popBall(r) {
  for (let i = 0; i < 5; i++) {
    const b = document.createElement("span");
    b.className = "cb-pop";
    b.style.backgroundImage = `url(${TEAMS.ARG.crest})`;
    b.style.left = r.width / 2 + "px";
    b.style.top = r.height / 2 + "px";
    const ang = rand(0, Math.PI * 2), dist = rand(50, 120);
    b.style.setProperty("--dx", `calc(-50% + ${Math.cos(ang) * dist}px)`);
    b.style.setProperty("--dy", `calc(-50% + ${Math.sin(ang) * dist}px)`);
    cbBall.appendChild(b);
    setTimeout(() => b.remove(), 800);
  }
}

/* menu-bar icon toggles the dropdown, like the real menu-bar app */
if (trayApp && appmenu) {
  trayApp.addEventListener("click", () => {
    const hidden = appmenu.style.display === "none";
    appmenu.style.display = hidden ? "" : "none";
    trayApp.setAttribute("aria-expanded", hidden ? "true" : "false");
  });
}

/* ═══════════════════════════════════════════════════════════════════════════
   Timeline playback — one clock drives pills + fixture + celebration
   ═══════════════════════════════════════════════════════════════════════════ */
let idx = 0, playing = false, finished = false, timer = null, autoPlayed = false;

function setLabel(text, mode) {
  if (playLabel) playLabel.textContent = text;
  if (playIco) playIco.textContent = mode === "pause" ? "❚❚" : "▶";
}
function resetTimeline() {
  clearTimeout(timer);
  idx = 0; finished = false;
  if (pillstack) pillstack.innerHTML = "";
  if (fixtureRow) fixtureRow.hidden = true;
  if (fxEmpty) fxEmpty.hidden = false;
  hideCelebration();
}
function step() {
  if (idx >= FINAL.length) {
    playing = false; finished = true;
    setLabel("Replay the 2022 Final", "play");
    return;
  }
  const ev = FINAL[idx++];
  dropPill(ev);
  updateFixture(ev);
  if (ev.celebrate) showCelebration(ev.team);
  const gap = (reduceMotion ? 3600 : 2200) + (ev.celebrate ? 1000 : 0);
  timer = setTimeout(step, gap);
}
function play() {
  if (reduceMotion) return jumpToFinal();
  if (finished) resetTimeline();
  playing = true;
  setLabel("Pause", "pause");
  step();
}
function pause() {
  clearTimeout(timer);
  playing = false;
  setLabel("Resume", "play");
}
/* reduced motion: no animation — just show the finished state */
function jumpToFinal() {
  resetTimeline();
  const last = FINAL.slice(-3);
  last.forEach((ev) => dropPill(ev, false));
  updateFixture(FINAL[FINAL.length - 1]);
  finished = true;
  setLabel("Replay the 2022 Final", "play");
}
if (playBtn) {
  playBtn.addEventListener("click", () => (playing ? pause() : play()));
}

/* autoplay once when the preview scrolls into view */
if (macframe) {
  new IntersectionObserver((entries, obs) => {
    entries.forEach((e) => {
      if (e.isIntersecting && !autoPlayed) {
        autoPlayed = true;
        if (reduceMotion) jumpToFinal();
        else play();
        obs.disconnect();
      }
    });
  }, { threshold: 0.45 }).observe(macframe);
}

/* ═══════════════════════════════════════════════════════════════════════════
   Confetti (2D overlay) — app palette
   ═══════════════════════════════════════════════════════════════════════════ */
const conf = document.getElementById("confetti");
const cc = conf.getContext("2d");
let bits = [], confRaf = null, confLast = 0, confDpr = Math.min(window.devicePixelRatio || 1, 2);
const CONF_COLORS = ["#ffcc00", "#34c759", "#0a84ff", "#ff6482", "#ff9f0a", "#ffffff", "#ff3b30"];
function sizeConf() { confDpr = Math.min(window.devicePixelRatio || 1, 2); conf.width = innerWidth * confDpr; conf.height = innerHeight * confDpr; cc.setTransform(confDpr, 0, 0, confDpr, 0, 0); }
window.addEventListener("resize", sizeConf); sizeConf();
function burstConfetti(scale = 1, origin) {
  if (reduceMotion) return;
  const sources = origin ? [{ x: origin.x, y: origin.y, base: -Math.PI / 2, spread: Math.PI }]
    : [{ x: -10, y: innerHeight + 10, base: -1.15, spread: 0.5 }, { x: innerWidth + 10, y: innerHeight + 10, base: -Math.PI + 1.15, spread: 0.5 }];
  for (const s of sources) {
    const n = Math.floor((origin ? 40 : 60) * scale);
    for (let i = 0; i < n; i++) {
      const ang = s.base + rand(-s.spread, s.spread), sp = rand(420, 900) * (origin ? 1 : 1.1);
      bits.push({ x: s.x, y: s.y, vx: Math.cos(ang) * sp, vy: Math.sin(ang) * sp, color: pick(CONF_COLORS), size: rand(5, 11), rot: rand(0, Math.PI), spin: rand(-9, 9), life: 0, ttl: rand(2.2, 3.6) });
    }
  }
  if (!confRaf) { confLast = performance.now(); confRaf = requestAnimationFrame(tickConf); }
}
function tickConf(now) {
  const dt = Math.min((now - confLast) / 1000, 0.05); confLast = now;
  cc.clearRect(0, 0, innerWidth, innerHeight);
  bits = bits.filter((p) => {
    p.life += dt; if (p.life > p.ttl) return false;
    p.vy += 1500 * dt; p.x += p.vx * dt; p.y += p.vy * dt; p.rot += p.spin * dt;
    const fade = p.life > p.ttl - 1 ? Math.max(0, p.ttl - p.life) : 1;
    cc.save(); cc.globalAlpha = fade; cc.translate(p.x, p.y); cc.rotate(p.rot); cc.fillStyle = p.color; cc.fillRect(-p.size / 2, -p.size / 2, p.size, p.size * 0.62); cc.restore();
    return true;
  });
  if (bits.length) confRaf = requestAnimationFrame(tickConf); else { cc.clearRect(0, 0, innerWidth, innerHeight); confRaf = null; }
}
document.querySelectorAll("[data-confetti]").forEach((el) => el.addEventListener("click", () => burstConfetti(0.8)));

/* ═══════════════════════════════════════════════════════════════════════════
   Reveal on scroll + nav
   ═══════════════════════════════════════════════════════════════════════════ */
const revealObserver = new IntersectionObserver((entries) => {
  entries.forEach((e) => { if (e.isIntersecting) { e.target.classList.add("in"); revealObserver.unobserve(e.target); } });
}, { threshold: 0.18 });
document.querySelectorAll(".reveal").forEach((el) => revealObserver.observe(el));

const nav = document.querySelector(".nav");
const onScroll = () => nav.classList.toggle("scrolled", window.scrollY > 30);
window.addEventListener("scroll", onScroll, { passive: true });
onScroll();

const navToggle = document.querySelector(".nav-toggle");
if (navToggle) {
  const setMenu = (open) => {
    nav.classList.toggle("menu-open", open);
    navToggle.setAttribute("aria-expanded", open ? "true" : "false");
  };
  navToggle.addEventListener("click", () => setMenu(!nav.classList.contains("menu-open")));
  nav.querySelectorAll(".nav-links a").forEach((a) => a.addEventListener("click", () => setMenu(false)));
}
