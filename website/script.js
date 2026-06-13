/* ═══════════════════════════════════════════════════════════════════════════
   All Day I Dream About Sports — the constellation engine
   A single field of particles that morphs through the story:
   soccer ball → globe (celebrations) → other sports balls (what's next).
   ═══════════════════════════════════════════════════════════════════════════ */

const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
const rand = (a, b) => a + Math.random() * (b - a);
const pick = (a) => a[(Math.random() * a.length) | 0];

/* ── Palette (kept in sync with style.css) ─────────────────────────────────*/
const C = {
  bone: [255, 255, 255],
  plum: [128, 82, 255],
  plumSoft: [165, 133, 255],
  amber: [255, 184, 41],
  lichen: [31, 170, 138],
  red: [255, 59, 82],
  dim: [120, 120, 132],
  orange: [232, 118, 46],
  tennis: [205, 220, 57],
  pigskin: [173, 102, 60],
  ink: [18, 14, 24],
};

/* ═══════════════════════════════════════════════════════════════════════════
   1. PARTICLE FIELD
   ═══════════════════════════════════════════════════════════════════════════ */
const cosmos = document.getElementById("cosmos");
const cx2 = cosmos.getContext("2d", { alpha: true });

const N = window.innerWidth < 760 ? 1100 : 1700;
let DPR = Math.min(window.devicePixelRatio || 1, 2);
let W = 0, H = 0, focusX = 0.62, focusY = 0.5, worldR = 0;

/* Fibonacci sphere — evenly distributed unit directions. Each particle keeps a
   fixed identity (its direction) so morphs are pure position/colour lerps. */
const dirs = new Float32Array(N * 3);
(function seed() {
  const golden = Math.PI * (3 - Math.sqrt(5));
  for (let i = 0; i < N; i++) {
    const y = 1 - (i / (N - 1)) * 2;
    const r = Math.sqrt(Math.max(0, 1 - y * y));
    const t = golden * i;
    dirs[i * 3] = Math.cos(t) * r;
    dirs[i * 3 + 1] = y;
    dirs[i * 3 + 2] = Math.sin(t) * r;
  }
})();

/* Icosahedron vertices → pentagon centres for the soccer ball */
const ico = (() => {
  const p = (1 + Math.sqrt(5)) / 2;
  const v = [
    [0, 1, p], [0, -1, p], [0, 1, -p], [0, -1, -p],
    [1, p, 0], [-1, p, 0], [1, -p, 0], [-1, -p, 0],
    [p, 0, 1], [-p, 0, 1], [p, 0, -1], [-p, 0, -1],
  ];
  return v.map(([a, b, c]) => { const l = Math.hypot(a, b, c); return [a / l, b / l, c / l]; });
})();
function pentagonDist(x, y, z) {
  let best = -1;
  for (let k = 0; k < ico.length; k++) {
    const d = x * ico[k][0] + y * ico[k][1] + z * ico[k][2];
    if (d > best) best = d;
  }
  return best; // 1 at a pentagon centre
}

/* ── Shape definitions ─────────────────────────────────────────────────────
   Each sets the particle's LOCAL position (pre-rotation), colour, and an
   accent flag (a=1 → drawn brighter & larger so the pattern reads).           */
function shapeSoccer(i, out) {
  const x = dirs[i * 3], y = dirs[i * 3 + 1], z = dirs[i * 3 + 2];
  out.x = x; out.y = y; out.z = z;
  const pd = pentagonDist(x, y, z);
  if (pd > 0.905) { out.c = C.plumSoft; out.a = 1; }   // pentagon cap
  else if (pd > 0.885) { out.c = C.plum; out.a = 1; }  // pentagon rim
  else { out.c = C.bone; out.a = 0; }                  // hexagon field
}

function shapeGlobe(i, out) {
  const x = dirs[i * 3], y = dirs[i * 3 + 1], z = dirs[i * 3 + 2];
  out.x = x; out.y = y; out.z = z;
  // wireframe globe: bright on meridians / parallels, dim elsewhere
  const lat = Math.asin(y);                 // -PI/2..PI/2
  const lon = Math.atan2(z, x);             // -PI..PI
  const par = Math.abs((lat / (Math.PI / 6)) % 1);     // parallels every 30°
  const mer = Math.abs((lon / (Math.PI / 6)) % 1);     // meridians every 30°
  const onGrid = par < 0.12 || par > 0.88 || mer < 0.1 || mer > 0.9;
  if (Math.abs(lat) < 0.08) { out.c = C.plumSoft; out.a = 1; }   // equator pulse
  else if (onGrid) { out.c = C.bone; out.a = 1; }
  else { out.c = C.dim; out.a = 0; }
}

function shapeBasketball(i, out) {
  const x = dirs[i * 3], y = dirs[i * 3 + 1], z = dirs[i * 3 + 2];
  out.x = x; out.y = y; out.z = z;
  const seam = Math.abs(x) < 0.05 || Math.abs(z) < 0.05 ||
    Math.abs(Math.abs(y) - 0.62) < 0.045;
  out.c = seam ? C.ink : C.orange; out.a = 0;
}

function shapeTennis(i, out) {
  const x = dirs[i * 3], y = dirs[i * 3 + 1], z = dirs[i * 3 + 2];
  out.x = x; out.y = y; out.z = z;
  const lon = Math.atan2(z, x);
  const seam = Math.abs(y - 0.55 * Math.sin(2 * lon)) < 0.07;
  out.c = seam ? C.bone : C.tennis; out.a = seam ? 1 : 0;
}

function shapeBaseball(i, out) {
  const x = dirs[i * 3], y = dirs[i * 3 + 1], z = dirs[i * 3 + 2];
  out.x = x; out.y = y; out.z = z;
  const lon = Math.atan2(z, x);
  const seam = Math.abs(y - 0.5 * Math.sin(2 * lon)) < 0.05 ||
    Math.abs(y + 0.5 * Math.sin(2 * lon)) < 0.05;
  out.c = seam ? C.red : C.bone; out.a = seam ? 1 : 0;
}

function shapeFootball(i, out) {
  // American football — prolate ellipsoid stretched on x
  const x = dirs[i * 3], y = dirs[i * 3 + 1], z = dirs[i * 3 + 2];
  out.x = x * 1.42; out.y = y * 0.74; out.z = z * 0.74;
  const lace = Math.abs(x) < 0.55 && Math.abs(z) < 0.05 && y > 0.45;
  out.c = lace ? C.bone : C.pigskin; out.a = lace ? 1 : 0;
}

const SHAPES = {
  soccer: shapeSoccer,
  globe: shapeGlobe,
  basketball: shapeBasketball,
  tennis: shapeTennis,
  baseball: shapeBaseball,
  football: shapeFootball,
};

/* Per-particle live state */
const px = new Float32Array(N), py = new Float32Array(N), pz = new Float32Array(N);
const cr = new Float32Array(N), cg = new Float32Array(N), cb = new Float32Array(N);
const tx = new Float32Array(N), ty = new Float32Array(N), tz = new Float32Array(N);
const tr = new Float32Array(N), tg = new Float32Array(N), tb = new Float32Array(N);
const acc = new Float32Array(N);
const seedOff = new Float32Array(N);
for (let i = 0; i < N; i++) seedOff[i] = Math.random() * Math.PI * 2;

const tmp = { x: 0, y: 0, z: 0, c: C.bone, a: 0 };
function setTargets(name) {
  const fn = SHAPES[name];
  for (let i = 0; i < N; i++) {
    tmp.a = 0;
    fn(i, tmp);
    tx[i] = tmp.x; ty[i] = tmp.y; tz[i] = tmp.z;
    tr[i] = tmp.c[0]; tg[i] = tmp.c[1]; tb[i] = tmp.c[2];
    acc[i] = tmp.a;
  }
}

/* Initialise to soccer, scattered out so the first reveal "assembles". */
setTargets("soccer");
for (let i = 0; i < N; i++) {
  const s = reduceMotion ? 1 : rand(1.6, 3.2);
  px[i] = tx[i] * s; py[i] = ty[i] * s; pz[i] = tz[i] * s;
  cr[i] = tr[i]; cg[i] = tg[i]; cb[i] = tb[i];
}

let currentShape = "soccer";
function morphTo(name) {
  if (name === currentShape) return;
  currentShape = name;
  setTargets(name);
}

/* Celebration pings — plum sparks that erupt from the globe / on tap */
const pings = [];
function spawnPing(originScreen) {
  pings.push({
    a: rand(0, Math.PI * 2), el: rand(-1, 1),
    r: 0, vr: rand(0.7, 1.4), life: 0, ttl: rand(0.9, 1.6),
    fixed: originScreen || null,
  });
}

/* Resize */
function resize() {
  DPR = Math.min(window.devicePixelRatio || 1, 2);
  W = window.innerWidth; H = window.innerHeight;
  cosmos.width = W * DPR; cosmos.height = H * DPR;
  cx2.setTransform(DPR, 0, 0, DPR, 0, 0);
  const mobile = W < 880;
  focusX = mobile ? 0.5 : 0.64;
  focusY = mobile ? 0.3 : 0.5;        // sit the form above the text on phones
  worldR = Math.min(W, H) * (mobile ? 0.3 : 0.4);
}
window.addEventListener("resize", resize);
resize();

/* Render loop */
let yaw = 0, pitch = -0.18, t0 = performance.now();
const EASE = 0.055, FOCAL = 2.6;

function frame(now) {
  const dt = Math.min((now - t0) / 1000, 0.05); t0 = now;
  if (!reduceMotion) yaw += dt * 0.18;

  cx2.clearRect(0, 0, W, H);

  const cxp = W * focusX, cyp = H * focusY;
  const cy = Math.cos(yaw), sy = Math.sin(yaw);
  const cp = Math.cos(pitch), sp = Math.sin(pitch);
  const breathe = reduceMotion ? 0 : Math.sin(now / 2600) * 0.015;

  for (let i = 0; i < N; i++) {
    // ease local position + colour toward target
    px[i] += (tx[i] - px[i]) * EASE;
    py[i] += (ty[i] - py[i]) * EASE;
    pz[i] += (tz[i] - pz[i]) * EASE;
    cr[i] += (tr[i] - cr[i]) * EASE;
    cg[i] += (tg[i] - cg[i]) * EASE;
    cb[i] += (tb[i] - cb[i]) * EASE;

    let x = px[i] * (1 + breathe), y = py[i] * (1 + breathe), z = pz[i] * (1 + breathe);
    // rotate Y (yaw) then X (pitch)
    let x1 = x * cy + z * sy;
    let z1 = -x * sy + z * cy;
    let y1 = y * cp - z1 * sp;
    let z2 = y * sp + z1 * cp;

    const persp = FOCAL / (FOCAL - z2);
    const sx = cxp + x1 * worldR * persp;
    const syp = cyp + y1 * worldR * persp;

    // depth shading: front particles brighter & larger
    const depth = (z2 + 1) / 2;            // 0 back .. 1 front
    const isAcc = acc[i] > 0.5;
    let alpha = 0.16 + depth * 0.84;
    let size = (0.7 + depth * 1.7) * persp;
    if (isAcc) { alpha = Math.min(1, alpha + 0.22); size *= 1.55; }

    const tw = reduceMotion ? 1 : 0.82 + 0.18 * Math.sin(now / 600 + seedOff[i]);

    cx2.globalAlpha = alpha * tw;
    cx2.fillStyle = `rgb(${cr[i] | 0},${cg[i] | 0},${cb[i] | 0})`;
    // tiny triangle
    cx2.beginPath();
    cx2.moveTo(sx, syp - size);
    cx2.lineTo(sx - size, syp + size);
    cx2.lineTo(sx + size, syp + size);
    cx2.closePath();
    cx2.fill();
  }

  // celebration pings ride the same sphere, bursting outward
  cx2.globalAlpha = 1;
  for (let k = pings.length - 1; k >= 0; k--) {
    const p = pings[k];
    p.life += dt; p.r += p.vr * dt;
    if (p.life > p.ttl) { pings.splice(k, 1); continue; }
    const fade = 1 - p.life / p.ttl;
    let sx, syp, sz = 1;
    if (p.fixed) { sx = p.fixed.x; syp = p.fixed.y - p.r * 70; }
    else {
      const rr = 1 + p.r * 0.6;
      let x = Math.cos(p.a) * Math.cos(p.el) * rr;
      let y = Math.sin(p.el) * rr;
      let z = Math.sin(p.a) * Math.cos(p.el) * rr;
      let x1 = x * cy + z * sy, z1 = -x * sy + z * cy;
      let y1 = y * cp - z1 * sp; let z2 = y * sp + z1 * cp;
      const persp = FOCAL / (FOCAL - z2);
      sx = cxp + x1 * worldR * persp; syp = cyp + y1 * worldR * persp; sz = persp;
    }
    cx2.globalAlpha = fade * 0.9;
    cx2.fillStyle = `rgb(${C.plumSoft.join(",")})`;
    cx2.beginPath();
    cx2.arc(sx, syp, 1.8 * sz, 0, Math.PI * 2);
    cx2.fill();
  }
  cx2.globalAlpha = 1;

  requestAnimationFrame(frame);
}
requestAnimationFrame(frame);

/* ═══════════════════════════════════════════════════════════════════════════
   2. SCROLL → SHAPE  (each section claims a form)
   ═══════════════════════════════════════════════════════════════════════════ */
const shapeCycle = ["basketball", "tennis", "baseball", "football"];
let cycleTimer = null, cycleIdx = 0;

function startCycle() {
  stopCycle();
  morphTo(shapeCycle[cycleIdx % shapeCycle.length]);
  cycleTimer = setInterval(() => {
    cycleIdx++;
    morphTo(shapeCycle[cycleIdx % shapeCycle.length]);
  }, 2400);
}
function stopCycle() { if (cycleTimer) { clearInterval(cycleTimer); cycleTimer = null; } }

let globeTimer = null;
function startGlobePings() {
  stopGlobePings();
  globeTimer = setInterval(() => { if (!reduceMotion) for (let i = 0; i < 3; i++) spawnPing(); }, 700);
}
function stopGlobePings() { if (globeTimer) { clearInterval(globeTimer); globeTimer = null; } }

const sectionObserver = new IntersectionObserver((entries) => {
  entries.forEach((e) => {
    if (!e.isIntersecting || e.intersectionRatio < 0.5) return;
    const shape = e.target.dataset.shape;
    stopCycle(); stopGlobePings();
    if (shape === "cycle") startCycle();
    else { morphTo(shape); if (shape === "globe") startGlobePings(); }
  });
}, { threshold: [0.5] });

document.querySelectorAll("[data-shape]").forEach((s) => sectionObserver.observe(s));

/* ═══════════════════════════════════════════════════════════════════════════
   3. REVEAL ON SCROLL
   ═══════════════════════════════════════════════════════════════════════════ */
const revealObserver = new IntersectionObserver((entries) => {
  entries.forEach((e) => { if (e.isIntersecting) { e.target.classList.add("in"); revealObserver.unobserve(e.target); } });
}, { threshold: 0.18 });
document.querySelectorAll(".reveal").forEach((el) => revealObserver.observe(el));

/* ═══════════════════════════════════════════════════════════════════════════
   4. NAV background on scroll
   ═══════════════════════════════════════════════════════════════════════════ */
const nav = document.querySelector(".nav");
const onScroll = () => nav.classList.toggle("scrolled", window.scrollY > 30);
window.addEventListener("scroll", onScroll, { passive: true });
onScroll();

/* ═══════════════════════════════════════════════════════════════════════════
   5. NOTCH DROPS — live alert demo
   ═══════════════════════════════════════════════════════════════════════════ */
const desktop = document.getElementById("desktop");
const ALERTS = [
  { cls: "goal", ico: "⚽", title: "GOAL — Messi 108'", sub: "ARG 3 — 2 FRA", time: "now" },
  { cls: "yellow", ico: "🟨", title: "Yellow card — Montiel", sub: "ARG 3 — 2 FRA · 116'", time: "1m" },
  { cls: "red", ico: "🟥", title: "Red card — Coman", sub: "ARG 3 — 2 FRA · 119'", time: "2m" },
  { cls: "goal", ico: "⚽", title: "GOAL — Mbappé 118'", sub: "ARG 3 — 3 FRA", time: "now" },
  { cls: "full", ico: "🏁", title: "Full time — Argentina win", sub: "ARG 3 — 3 FRA · 4–2 pens", time: "now" },
  { cls: "goal", ico: "🎉", title: "4.2M fans celebrating", sub: "Argentina · live now", time: "now" },
];
let alertIdx = 0;
function dropAlert() {
  if (!desktop) return;
  const a = ALERTS[alertIdx % ALERTS.length]; alertIdx++;
  const el = document.createElement("div");
  el.className = "pill drop";
  el.innerHTML =
    `<span class="pill-ico ${a.cls}">${a.ico}</span>` +
    `<span class="pill-body"><span class="pill-title">${a.title}</span><span class="pill-sub">${a.sub}</span></span>` +
    `<span class="pill-time">${a.time}</span>`;
  desktop.prepend(el);
  if (a.cls === "goal" && a.ico === "⚽") burstConfetti(0.4);
  while (desktop.children.length > 3) desktop.lastChild.remove();
}
let notchTimer = null;
const notchObserver = new IntersectionObserver((entries) => {
  entries.forEach((e) => {
    if (e.isIntersecting && !notchTimer) {
      dropAlert();
      notchTimer = setInterval(dropAlert, reduceMotion ? 4000 : 2600);
    } else if (!e.isIntersecting && notchTimer) {
      clearInterval(notchTimer); notchTimer = null;
    }
  });
}, { threshold: 0.4 });
if (desktop) notchObserver.observe(desktop.closest(".panel"));

/* ═══════════════════════════════════════════════════════════════════════════
   6. CELEBRATIONS — counter + tap-to-celebrate
   ═══════════════════════════════════════════════════════════════════════════ */
const counterEl = document.getElementById("count");
let count = 4210338, displayCount = count;
function fmt(n) { return Math.floor(n).toLocaleString("en-US"); }
if (counterEl) {
  counterEl.textContent = fmt(displayCount);
  // gentle live drift upward
  setInterval(() => { if (!reduceMotion) count += Math.floor(rand(3, 22)); }, 900);
  (function animateCount() {
    displayCount += (count - displayCount) * 0.12;
    counterEl.textContent = fmt(displayCount);
    requestAnimationFrame(animateCount);
  })();
}

const celebrateBtn = document.getElementById("celebrate");
if (celebrateBtn) {
  celebrateBtn.addEventListener("click", () => {
    count += Math.floor(rand(80, 260));
    const r = celebrateBtn.getBoundingClientRect();
    burstConfetti(1, { x: r.left + r.width / 2, y: r.top });
    if (currentShape === "globe") for (let i = 0; i < 10; i++) spawnPing();
  });
}

/* ═══════════════════════════════════════════════════════════════════════════
   7. CONFETTI
   ═══════════════════════════════════════════════════════════════════════════ */
const conf = document.getElementById("confetti");
const cc = conf.getContext("2d");
let bits = [], confRaf = null, confLast = 0;
const CONF_COLORS = ["#8052ff", "#a585ff", "#ffb829", "#1faa8a", "#ffffff", "#ff3b52"];

function sizeConf() { conf.width = innerWidth * DPR; conf.height = innerHeight * DPR; cc.setTransform(DPR, 0, 0, DPR, 0, 0); }
window.addEventListener("resize", sizeConf); sizeConf();

function burstConfetti(scale = 1, origin) {
  if (reduceMotion) return;
  const sources = origin
    ? [{ x: origin.x, y: origin.y, spread: Math.PI, base: -Math.PI / 2 }]
    : [
        { x: -10, y: innerHeight + 10, base: -1.15, spread: 0.5 },
        { x: innerWidth + 10, y: innerHeight + 10, base: -Math.PI + 1.15, spread: 0.5 },
      ];
  for (const s of sources) {
    const count = Math.floor((origin ? 70 : 60) * scale);
    for (let i = 0; i < count; i++) {
      const ang = s.base + rand(-s.spread, s.spread);
      const sp = rand(420, 900) * (origin ? 1 : 1.1);
      bits.push({
        x: s.x, y: s.y,
        vx: Math.cos(ang) * sp, vy: Math.sin(ang) * sp,
        color: pick(CONF_COLORS), size: rand(5, 11),
        rot: rand(0, Math.PI), spin: rand(-9, 9),
        life: 0, ttl: rand(2.2, 3.6),
      });
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
    cc.save(); cc.globalAlpha = fade; cc.translate(p.x, p.y); cc.rotate(p.rot);
    cc.fillStyle = p.color; cc.fillRect(-p.size / 2, -p.size / 2, p.size, p.size * 0.62); cc.restore();
    return true;
  });
  if (bits.length) confRaf = requestAnimationFrame(tickConf);
  else { cc.clearRect(0, 0, innerWidth, innerHeight); confRaf = null; }
}

/* download click flourish */
document.querySelectorAll("[data-confetti]").forEach((el) =>
  el.addEventListener("click", () => burstConfetti(0.8))
);
