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

/* ── SF-symbol-like icons + status tone, matching EventRouter.swift.
   "circle.fill" glyphs are a filled disc (currentColor) with the inner mark
   knocked out in the pill's black background (#000). */
const ICON = {
  play:  '<svg viewBox="0 0 24 24" fill="currentColor"><circle cx="12" cy="12" r="10"/><path d="M10 8.2l6 3.8-6 3.8z" fill="#000"/></svg>',
  ball:  '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><polygon points="12,7 16.3,10.1 14.7,15 9.3,15 7.7,10.1" fill="currentColor" stroke="none"/><path d="M12 3v4M4.7 9.3l3.7 .8M19.3 9.3l-3.7 .8M7.7 20l1.6-5M16.3 20l-1.6-5"/></svg>',
  card:  '<svg viewBox="0 0 24 24" fill="currentColor"><rect x="7" y="4" width="10" height="16" rx="2.5"/></svg>',
  pause: '<svg viewBox="0 0 24 24" fill="currentColor"><circle cx="12" cy="12" r="10"/><rect x="8.4" y="7.8" width="2.4" height="8.4" rx="1" fill="#000"/><rect x="13.2" y="7.8" width="2.4" height="8.4" rx="1" fill="#000"/></svg>',
  flag:  '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M5.5 3a1 1 0 0 0-1 1v17h1.9v-6.6h8.9l-1.6-3.4 1.6-3.4H6.4V4a1 1 0 0 0-.9-1z"/></svg>',
  clock: '<svg viewBox="0 0 24 24" fill="currentColor"><circle cx="12" cy="12" r="10"/><path d="M12 6.4v6l3.8 2.2" fill="none" stroke="#000" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  target:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="5"/><circle cx="12" cy="12" r="1.6" fill="currentColor" stroke="none"/></svg>',
  check: '<svg viewBox="0 0 24 24" fill="currentColor"><circle cx="12" cy="12" r="10"/><path d="M7.4 12.3l3 3 6.2-6.6" fill="none" stroke="#000" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  xmark: '<svg viewBox="0 0 24 24" fill="currentColor"><circle cx="12" cy="12" r="10"/><path d="M8.4 8.4l7.2 7.2M15.6 8.4l-7.2 7.2" fill="none" stroke="#000" stroke-width="2" stroke-linecap="round"/></svg>',
};
const TYPE = {
  kickoff:  { ic: "play",   tone: "green"  },
  goal:     { ic: "ball",   tone: "white"  },
  yellow:   { ic: "card",   tone: "yellow" },
  red:      { ic: "card",   tone: "red"    },
  half:     { ic: "pause",  tone: "white"  },
  extra:    { ic: "clock",  tone: "white"  },
  shootout: { ic: "target", tone: "purple" },
  pengood:  { ic: "check",  tone: "green"  },
  penmiss:  { ic: "xmark",  tone: "red"    },
  full:     { ic: "flag",   tone: "green"  },
};

/* ── the 2022 Final, event by event (Argentina = home) ─────────────────────
   h/a = goals; ph/pa = shootout pens (only set once the shootout starts). */
const FINAL = [
  { type: "kickoff", h: 0, a: 0, fx: "live", fxMin: "1'" },
  { type: "goal", min: "23", pen: true, player: "Messi", team: "ARG", h: 1, a: 0, celebrate: true, fx: "live", fxMin: "23'" },
  { type: "goal", min: "36", player: "Di María", team: "ARG", h: 2, a: 0, celebrate: true, fx: "live", fxMin: "36'" },
  { type: "yellow", min: "45+7", player: "E. Fernández", team: "ARG", h: 2, a: 0, fx: "live", fxMin: "45+7'" },
  { type: "half", leadName: "Argentina", team: "ARG", h: 2, a: 0, fx: "ht" },
  { type: "yellow", min: "55", player: "Rabiot", team: "FRA", h: 2, a: 0, fx: "live", fxMin: "55'" },
  { type: "goal", min: "80", pen: true, player: "Mbappé", team: "FRA", h: 2, a: 1, celebrate: true, fx: "live", fxMin: "80'" },
  { type: "goal", min: "81", player: "Mbappé", team: "FRA", h: 2, a: 2, celebrate: true, fx: "live", fxMin: "81'" },
  { type: "extra", h: 2, a: 2, fx: "break", fxMin: "90'" },
  { type: "goal", min: "108", player: "Messi", team: "ARG", h: 3, a: 2, celebrate: true, fx: "live", fxMin: "108'" },
  { type: "yellow", min: "116", player: "Montiel", team: "ARG", h: 3, a: 2, fx: "live", fxMin: "116'" },
  { type: "goal", min: "118", pen: true, player: "Mbappé", team: "FRA", h: 3, a: 3, celebrate: true, fx: "live", fxMin: "118'" },
  { type: "shootout", h: 3, a: 3, ph: 0, pa: 0, fx: "pens" },
  { type: "pengood", player: "Mbappé", team: "FRA", h: 3, a: 3, ph: 0, pa: 1, fx: "pens" },
  { type: "pengood", player: "Messi", team: "ARG", h: 3, a: 3, ph: 1, pa: 1, fx: "pens" },
  { type: "penmiss", saved: true, player: "Coman", team: "FRA", h: 3, a: 3, ph: 1, pa: 1, fx: "pens" },
  { type: "pengood", player: "Dybala", team: "ARG", h: 3, a: 3, ph: 2, pa: 1, fx: "pens" },
  { type: "penmiss", player: "Tchouaméni", team: "FRA", h: 3, a: 3, ph: 2, pa: 1, fx: "pens" },
  { type: "pengood", player: "Paredes", team: "ARG", h: 3, a: 3, ph: 3, pa: 1, fx: "pens" },
  { type: "pengood", player: "Kolo Muani", team: "FRA", h: 3, a: 3, ph: 3, pa: 2, fx: "pens" },
  { type: "pengood", player: "Montiel", team: "ARG", h: 3, a: 3, ph: 4, pa: 2, celebrate: true, fx: "pens" },
  { type: "full", winner: "Argentina", team: "ARG", h: 3, a: 3, ph: 4, pa: 2, fx: "ft" },
];

/* score text mirrors ScorelineFormatter: "3" or "3+P4" once pens exist */
const scoreText = (goals, pens) => (pens == null ? `${goals}` : `${goals}+P${pens}`);
const crestTag = (t) => `<img class="pill-crest" src="${TEAMS[t].crest}" alt="${TEAMS[t].name}" />`;

/* pill title — the app grammar: [minute′] Label — <bold noun> [crest] */
function pillTitle(ev) {
  const m = ev.min ? `<span class="min">${ev.min}′ </span>` : "";
  const cr = ev.team ? crestTag(ev.team) : "";
  switch (ev.type) {
    case "kickoff":  return "Kickoff";
    case "goal":     return `${m}${ev.pen ? "Penalty goal" : "Goal"} — <b>${ev.player}</b> ${cr}`;
    case "yellow":   return `${m}Yellow card — <b>${ev.player}</b> ${cr}`;
    case "red":      return `${m}Red card — <b>${ev.player}</b> ${cr}`;
    case "half":     return `Half-time — <b>${ev.leadName}</b> ahead ${cr}`;
    case "extra":    return "Extra time";
    case "shootout": return "Penalty shootout!";
    case "pengood":  return `Penalty — <b>${ev.player}</b> scored ✓ ${cr}`;
    case "penmiss":  return `Penalty — <b>${ev.player}</b> ${ev.saved ? "saved ✗" : "missed ✗"} ${cr}`;
    case "full":     return `Full-time — <b>${ev.winner}</b> won on pens ${cr}`;
    default:         return "";
  }
}
/* pill subtitle — the score row (kickoff reads "vs") */
function pillSub(ev) {
  if (ev.type === "kickoff") return `${TEAMS.ARG.name} vs ${TEAMS.FRA.name}`;
  return `${TEAMS.ARG.name} ${scoreText(ev.h, ev.ph)} - ${scoreText(ev.a, ev.pa)} ${TEAMS.FRA.name}`;
}

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
const fxSub = $("fxSub");
const capsule = $("capsule");
const capScore = $("capScore");
const capTrail = $("capTrail");
const capMin = $("capMin");
const cbOverlay = $("cbOverlay");
const cbBall = $("cbBall");
const cbBadge = $("cbBadge");
const cbCount = $("cbCount");
/* confetti canvas — confined to the demo frame */
const cbConf = $("cbConfetti");
const cbctx = cbConf ? cbConf.getContext("2d") : null;
const CONF_COLORS = ["#ffcc00", "#34c759", "#0a84ff", "#ff6482", "#ff9f0a", "#ffffff", "#ff3b30"];
let cbBits = [], cbRaf = null, cbLast = 0;
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
// One notch pill at a time: it drops in, holds, then rises back into the notch
// before the next one appears (mirrors the app's single displayed set).
let currentPill = null, pillExitTimer = null;
function buildPill(ev, animate = true) {
  const t = TYPE[ev.type];
  const el = document.createElement("div");
  el.className = animate ? "pill drop" : "pill";
  el.innerHTML =
    `<div class="pill-head"><span class="pill-ic" data-tone="${t.tone}">${ICON[t.ic]}</span>` +
    `<span class="pill-title">${pillTitle(ev)}</span></div>` +
    `<span class="pill-sub">${pillSub(ev)}</span>`;
  return el;
}
function showPill(ev) {
  if (!pillstack) return;
  clearTimeout(pillExitTimer);
  if (currentPill) { currentPill.remove(); currentPill = null; }
  currentPill = buildPill(ev);
  pillstack.appendChild(currentPill);
}
function exitCurrentPill() {
  if (!currentPill) return;
  const el = currentPill; currentPill = null;
  el.classList.remove("drop"); el.classList.add("exit");
  pillExitTimer = setTimeout(() => el.remove(), 400);
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
  fxTrail.className = "fx-trail" + (st === "ft" ? " ft" : (st === "live" || st === "pens" || st === "break") ? " live" : "");
  fxMin.textContent = st === "ft" ? "FT" : st === "ht" ? "HT" : st === "pens" ? "PENS" : (ev.fxMin || "");
  // sub line shows the stage — or the live shootout score once penalties start
  if (ev.ph != null) {
    fxSub.textContent = st === "ft"
      ? `Penalties ${ev.ph} – ${ev.pa} · ${ev.winner} win`
      : `Penalties ${ev.ph} – ${ev.pa}`;
  } else {
    fxSub.textContent = "World Cup 2022 · Final";
  }
}

/* ═══════════════════════════════════════════════════════════════════════════
   Pinned score capsule — the floating, draggable scoreboard
   ═══════════════════════════════════════════════════════════════════════════ */
// The capsule is a compact score pill — just the crests, scoreline and live
// minute, no event timeline.
function updateCapsule(ev) {
  if (!capsule) return;
  capsule.hidden = false;
  capScore.textContent = `${scoreText(ev.h, ev.ph)} – ${scoreText(ev.a, ev.pa)}`;
  const st = ev.fx || "live";
  capTrail.className = "cap-trail" + (st === "ft" ? " ft" : (st === "live" || st === "pens" || st === "break") ? " live" : "");
  capMin.textContent = st === "ft" ? "FT" : st === "ht" ? "HT" : st === "pens" ? "PENS" : (ev.fxMin || "");
}

/* drag the capsule anywhere inside the screen (accounts for the mobile zoom) */
if (capsule && macframe) {
  let dragging = false, sx = 0, sy = 0, ox = 0, oy = 0;
  const zoom = () => parseFloat(macframe.style.zoom) || 1;
  capsule.addEventListener("pointerdown", (e) => {
    dragging = true; capsule.classList.add("dragging"); capsule.setPointerCapture(e.pointerId);
    sx = e.clientX; sy = e.clientY; ox = capsule.offsetLeft; oy = capsule.offsetTop; e.preventDefault();
  });
  capsule.addEventListener("pointermove", (e) => {
    if (!dragging) return;
    const k = zoom();
    let nx = ox + (e.clientX - sx) / k, ny = oy + (e.clientY - sy) / k;
    nx = Math.max(4, Math.min(macframe.clientWidth - capsule.offsetWidth - 4, nx));
    ny = Math.max(4, Math.min(macframe.clientHeight - capsule.offsetHeight - 4, ny));
    capsule.style.left = nx + "px"; capsule.style.top = ny + "px"; capsule.style.right = "auto";
  });
  const endDrag = () => { dragging = false; capsule.classList.remove("dragging"); };
  capsule.addEventListener("pointerup", endDrag);
  capsule.addEventListener("pointercancel", endDrag);
}

/* Fit the demo to the viewport: zoom it down on narrow desktops/tablets (same
   layout & aspect, just smaller); on phones leave it big and horizontally
   scrollable, started centred. */
let scrollCentred = false;
function fitFrame() {
  if (!macframe) return;
  macframe.style.width = ""; macframe.style.maxWidth = ""; macframe.style.zoom = "";
  // phones: CSS keeps the demo big and lets it scroll horizontally — no zoom-fit.
  // Start the scroll centred (once) so the demo reads as centre-aligned, not
  // pinned to the left edge.
  if (window.innerWidth <= 760) {
    sizeCbConf();
    const sc = macframe.parentElement;
    if (sc && !scrollCentred && sc.scrollWidth > sc.clientWidth) {
      sc.scrollLeft = (sc.scrollWidth - sc.clientWidth) / 2;
      scrollCentred = true;
    }
    return;
  }
  // otherwise measure the naturally fitted width, then lock the design width and
  // zoom the whole frame down to match it (preserves the exact layout, smaller)
  const design = 900;
  const natural = macframe.clientWidth;
  if (natural && natural < design) {
    macframe.style.zoom = (natural / design).toFixed(4);
    macframe.style.width = design + "px";
    macframe.style.maxWidth = "none";
  }
  sizeCbConf();
}
window.addEventListener("resize", fitFrame);
fitFrame();

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
  cbTimer = setTimeout(hideCelebration, reduceMotion ? 2600 : 3000);
  if (!reduceMotion) {
    // confetti erupts from the demo frame's own corners (confined to the demo),
    // with a follow-up burst — the same corner-burst the app shows on a goal
    cbBurst(1);
    setTimeout(() => cbBurst(0.85), 480);
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
      // ball centre in the frame's own coordinate space (undo the mobile zoom)
      const mfr = macframe.getBoundingClientRect();
      const k = parseFloat(macframe.style.zoom) || 1;
      cbPoint((r.left + r.width / 2 - mfr.left) / k, (r.top + r.height / 2 - mfr.top) / k, 1);
      popBall(r);
    }
  });
}
/* little balls that fly off when you tap */
function popBall(r) {
  for (let i = 0; i < 5; i++) {
    const b = document.createElement("span");
    b.className = "cb-pop";
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
let idx = 0, playing = false, finished = false, timer = null, gapTimer = null, autoPlayed = false;

function setLabel(text, mode) {
  if (playLabel) playLabel.textContent = text;
  if (playIco) playIco.textContent = mode === "pause" ? "❚❚" : "▶";
}
function clearTimers() { clearTimeout(timer); clearTimeout(gapTimer); }
function resetTimeline() {
  clearTimers();
  idx = 0; finished = false;
  if (pillstack) pillstack.innerHTML = "";
  currentPill = null;
  if (fixtureRow) fixtureRow.hidden = true;
  if (fxEmpty) fxEmpty.hidden = false;
  if (capsule) capsule.hidden = true;
  hideCelebration();
}
function step() {
  if (idx >= FINAL.length) {
    playing = false; finished = true;
    setLabel("Replay the 2022 Final", "play");
    timer = setTimeout(exitCurrentPill, 2400);
    return;
  }
  const ev = FINAL[idx++];
  showPill(ev);
  updateFixture(ev);
  updateCapsule(ev);
  if (ev.celebrate) showCelebration(ev.team);
  const isPen = ev.type === "pengood" || ev.type === "penmiss";
  const dwell = reduceMotion ? 2600 : ev.celebrate ? 2800 : isPen ? 1700 : 2100;
  // pill leaves, then a clear empty beat (notch alone) before the next drops
  timer = setTimeout(() => { exitCurrentPill(); gapTimer = setTimeout(step, 820); }, dwell);
}
function play() {
  if (reduceMotion) return jumpToFinal();
  if (finished) resetTimeline();
  playing = true;
  setLabel("Pause", "pause");
  step();
}
function pause() {
  clearTimers();
  playing = false;
  setLabel("Resume", "play");
}
/* reduced motion: no animation — just show the finished state */
function jumpToFinal() {
  resetTimeline();
  const last = FINAL[FINAL.length - 1];
  showPill(last);
  if (currentPill) currentPill.classList.remove("drop");
  updateFixture(last);
  updateCapsule(last);
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
   Confetti — confined to the demo frame (canvas lives inside .macframe, which
   clips it). Mirrors the app's ConfettiView: a steep burst up-and-inward from
   the two bottom corners, weak gravity so pieces hang before falling back.
   ═══════════════════════════════════════════════════════════════════════════ */
function sizeCbConf() {
  if (!cbConf || !cbctx) return;
  const dpr = Math.min(window.devicePixelRatio || 1, 2);
  const w = cbConf.clientWidth, h = cbConf.clientHeight;
  if (!w || !h) return;
  cbConf.width = Math.round(w * dpr); cbConf.height = Math.round(h * dpr);
  cbctx.setTransform(dpr, 0, 0, dpr, 0, 0);
}
function cbStart() { if (!cbRaf) { cbLast = performance.now(); cbRaf = requestAnimationFrame(cbTick); } }
/* goal burst — from the frame's two bottom corners */
function cbBurst(scale = 1) {
  if (reduceMotion || !cbConf) return;
  sizeCbConf();
  const W = cbConf.clientWidth, H = cbConf.clientHeight;
  const corners = [{ x: -8, y: H + 8, dir: 1 }, { x: W + 8, y: H + 8, dir: -1 }];
  for (const c of corners) {
    const n = Math.floor(72 * scale);
    for (let i = 0; i < n; i++) {
      const ang = rand(1.05, 1.5), sp = rand(360, 720); // steep: up, barely inward
      cbBits.push({ x: c.x, y: c.y, vx: Math.cos(ang) * sp * c.dir, vy: -Math.sin(ang) * sp, color: pick(CONF_COLORS), size: rand(7, 15), rot: rand(0, Math.PI), spin: rand(-6, 6), life: 0, ttl: rand(2.6, 3.8) });
    }
  }
  cbStart();
}
/* tap burst — a small spray from the ball */
function cbPoint(px, py, scale = 1) {
  if (reduceMotion || !cbConf) return;
  sizeCbConf();
  const n = Math.floor(26 * scale);
  for (let i = 0; i < n; i++) {
    const ang = rand(0, Math.PI * 2), sp = rand(120, 360);
    cbBits.push({ x: px, y: py, vx: Math.cos(ang) * sp, vy: Math.sin(ang) * sp - 160, color: pick(CONF_COLORS), size: rand(5, 11), rot: rand(0, Math.PI), spin: rand(-8, 8), life: 0, ttl: rand(1.4, 2.4) });
  }
  cbStart();
}
function cbTick(now) {
  const dt = Math.min((now - cbLast) / 1000, 0.05); cbLast = now;
  const W = cbConf.clientWidth, H = cbConf.clientHeight;
  cbctx.clearRect(0, 0, W, H);
  const GRAV = H * 1.35; // gravity scaled to the frame — arc up, then fall back
  cbBits = cbBits.filter((p) => {
    p.life += dt; if (p.life > p.ttl) return false;
    p.vy += GRAV * dt; p.x += p.vx * dt; p.y += p.vy * dt; p.rot += p.spin * dt;
    if (p.y > H + 30) return false;
    const fade = p.life > p.ttl - 1 ? Math.max(0, p.ttl - p.life) : 1;
    cbctx.save(); cbctx.globalAlpha = fade; cbctx.translate(p.x, p.y); cbctx.rotate(p.rot); cbctx.fillStyle = p.color; cbctx.fillRect(-p.size / 2, -p.size / 4, p.size, p.size / 2); cbctx.restore();
    return true;
  });
  if (cbBits.length) cbRaf = requestAnimationFrame(cbTick); else { cbctx.clearRect(0, 0, W, H); cbRaf = null; }
}
window.addEventListener("resize", sizeCbConf); sizeCbConf();

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
