/* ═══════════════════════════════════════════════════════════════════════════
   All Day I Dream About Sports — the constellation engine (Three.js / WebGL)

   A dense cloud of 3D triangles (tetrahedra) that morphs through the story:
   soccer ball → globe (celebrations) → other sports balls (what's next).
   Inspired by dala.craftedbygc.com — lit, instanced, mouse-reactive.
   ═══════════════════════════════════════════════════════════════════════════ */

import * as THREE from "./assets/three.module.min.js";

const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
const rand = (a, b) => a + Math.random() * (b - a);
const pick = (a) => a[(Math.random() * a.length) | 0];

/* ── Palette, in 0..1 (kept in sync with style.css) ────────────────────────*/
const C = {
  bone: [1, 1, 1],
  plum: [0.502, 0.322, 1.0],
  plumSoft: [0.647, 0.522, 1.0],
  dim: [0.62, 0.62, 0.72],
  seam: [0, 0, 0],
};

/* ═══════════════════════════════════════════════════════════════════════════
   1. SHAPE MATH  — every particle keeps a fixed identity (a fibonacci-sphere
   direction); a shape just decides its target position, colour & visibility.
   ═══════════════════════════════════════════════════════════════════════════ */
const N = window.innerWidth < 760 ? 3000 : 5200;

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

// truncated-icosahedron panels: pentagon centres (icosahedron verts) +
// hexagon centres (dodecahedron verts) → a real soccer-ball tiling
const norm3 = (a, b, c) => { const l = Math.hypot(a, b, c); return [a / l, b / l, c / l]; };
const PHI = (1 + Math.sqrt(5)) / 2, IPHI = 1 / PHI;
const pentC = [
  [0, 1, PHI], [0, -1, PHI], [0, 1, -PHI], [0, -1, -PHI],
  [1, PHI, 0], [-1, PHI, 0], [1, -PHI, 0], [-1, -PHI, 0],
  [PHI, 0, 1], [-PHI, 0, 1], [PHI, 0, -1], [-PHI, 0, -1],
].map(([a, b, c]) => norm3(a, b, c));
const hexC = [
  [1, 1, 1], [1, 1, -1], [1, -1, 1], [1, -1, -1],
  [-1, 1, 1], [-1, 1, -1], [-1, -1, 1], [-1, -1, -1],
  [0, IPHI, PHI], [0, IPHI, -PHI], [0, -IPHI, PHI], [0, -IPHI, -PHI],
  [IPHI, PHI, 0], [IPHI, -PHI, 0], [-IPHI, PHI, 0], [-IPHI, -PHI, 0],
  [PHI, 0, IPHI], [PHI, 0, -IPHI], [-PHI, 0, IPHI], [-PHI, 0, -IPHI],
].map(([a, b, c]) => norm3(a, b, c));
const panels = [...pentC.map((c) => ({ c, pent: 1 })), ...hexC.map((c) => ({ c, pent: 0 }))];

function shapeSoccer(i, o) {
  const x = dirs[i * 3], y = dirs[i * 3 + 1], z = dirs[i * 3 + 2];
  o.x = x; o.y = y; o.z = z;
  let d1 = -2, d2 = -2, pent = 0;
  for (let k = 0; k < panels.length; k++) {
    const p = panels[k].c;
    const d = x * p[0] + y * p[1] + z * p[2];
    if (d > d1) { d2 = d1; d1 = d; pent = panels[k].pent; }
    else if (d > d2) { d2 = d; }
  }
  if (d1 - d2 < 0.05) { o.c = C.seam; o.v = 0; }          // seam → invisible gap
  else if (pent) { o.c = C.plum; o.v = 1; }               // pentagon → purple
  else { o.c = C.bone; o.v = 1; }                         // hexagon → white
}

function shapeGlobe(i, o) {
  const x = dirs[i * 3], y = dirs[i * 3 + 1], z = dirs[i * 3 + 2];
  o.x = x; o.y = y; o.z = z; o.v = 1;
  const lat = Math.asin(y), lon = Math.atan2(z, x);
  const par = Math.abs((lat / (Math.PI / 6)) % 1);
  const mer = Math.abs((lon / (Math.PI / 6)) % 1);
  const onGrid = par < 0.13 || par > 0.87 || mer < 0.1 || mer > 0.9;
  if (Math.abs(lat) < 0.07) o.c = C.plum;                 // purple equator
  else if (onGrid) o.c = C.bone;                          // bright graticule
  else o.c = C.dim;                                       // soft planet body
}

function shapeBasketball(i, o) {
  const x = dirs[i * 3], y = dirs[i * 3 + 1], z = dirs[i * 3 + 2];
  o.x = x; o.y = y; o.z = z; o.v = 1;
  const seam = Math.abs(x) < 0.05 || Math.abs(z) < 0.05 || Math.abs(Math.abs(y) - 0.62) < 0.045;
  o.c = seam ? C.plum : C.bone;
}
function shapeTennis(i, o) {
  const x = dirs[i * 3], y = dirs[i * 3 + 1], z = dirs[i * 3 + 2];
  o.x = x; o.y = y; o.z = z; o.v = 1;
  const lon = Math.atan2(z, x);
  o.c = Math.abs(y - 0.55 * Math.sin(2 * lon)) < 0.07 ? C.plum : C.bone;
}
function shapeBaseball(i, o) {
  const x = dirs[i * 3], y = dirs[i * 3 + 1], z = dirs[i * 3 + 2];
  o.x = x; o.y = y; o.z = z; o.v = 1;
  const lon = Math.atan2(z, x);
  const s = Math.abs(y - 0.5 * Math.sin(2 * lon)) < 0.05 || Math.abs(y + 0.5 * Math.sin(2 * lon)) < 0.05;
  o.c = s ? C.plum : C.bone;
}
function shapeFootball(i, o) {
  const x = dirs[i * 3], y = dirs[i * 3 + 1], z = dirs[i * 3 + 2];
  o.x = x * 1.42; o.y = y * 0.74; o.z = z * 0.74; o.v = 1;
  const lace = (Math.abs(x) < 0.55 && Math.abs(z) < 0.05 && y > 0.45) || Math.abs(x) > 1.15;
  o.c = lace ? C.plum : C.bone;
}
const SHAPES = { soccer: shapeSoccer, globe: shapeGlobe, basketball: shapeBasketball, tennis: shapeTennis, baseball: shapeBaseball, football: shapeFootball };

/* Per-instance live state */
const lx = new Float32Array(N), ly = new Float32Array(N), lz = new Float32Array(N);   // current unit pos
const txp = new Float32Array(N), typ = new Float32Array(N), tzp = new Float32Array(N); // target
const cr = new Float32Array(N), cg = new Float32Array(N), cb = new Float32Array(N);
const tcr = new Float32Array(N), tcg = new Float32Array(N), tcb = new Float32Array(N);
const vis = new Float32Array(N), tvis = new Float32Array(N);
const seedOff = new Float32Array(N);
for (let i = 0; i < N; i++) seedOff[i] = Math.random() * Math.PI * 2;

const _o = { x: 0, y: 0, z: 0, c: C.bone, v: 1 };
function setTargets(name) {
  const fn = SHAPES[name];
  for (let i = 0; i < N; i++) {
    _o.v = 1; fn(i, _o);
    txp[i] = _o.x; typ[i] = _o.y; tzp[i] = _o.z;
    tcr[i] = _o.c[0]; tcg[i] = _o.c[1]; tcb[i] = _o.c[2]; tvis[i] = _o.v;
  }
}

setTargets("soccer");
for (let i = 0; i < N; i++) {
  const s = reduceMotion ? 1 : rand(1.7, 3.4);
  lx[i] = txp[i] * s; ly[i] = typ[i] * s; lz[i] = tzp[i] * s;
  cr[i] = tcr[i]; cg[i] = tcg[i]; cb[i] = tcb[i]; vis[i] = tvis[i];
}

let currentShape = "soccer";
function morphTo(name) { if (name !== currentShape) { currentShape = name; setTargets(name); } }

/* ═══════════════════════════════════════════════════════════════════════════
   2. THREE.JS SCENE
   ═══════════════════════════════════════════════════════════════════════════ */
const canvas = document.getElementById("cosmos");
let renderer = null;
try {
  renderer = new THREE.WebGLRenderer({ canvas, alpha: true, antialias: true, powerPreference: "high-performance" });
  renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
} catch (e) {
  canvas.style.display = "none";   // no WebGL → the rest of the page still works
}

const scene = new THREE.Scene();
const camera = new THREE.PerspectiveCamera(40, 1, 0.1, 100);
camera.position.set(0, 0, 6.6);

scene.add(new THREE.AmbientLight(0xffffff, 1.15));
const key = new THREE.DirectionalLight(0xffffff, 1.5); key.position.set(-2, 2.5, 4); scene.add(key);
const rim = new THREE.DirectionalLight(0x8052ff, 1.1); rim.position.set(3, -1.5, 1.5); scene.add(rim);

// base 3D triangle: a tetrahedron, flat-shaded so each facet catches the light
const triGeo = new THREE.TetrahedronGeometry(1, 0);
const triMat = new THREE.MeshStandardMaterial({ roughness: 0.5, metalness: 0.04, flatShading: true });
const mesh = new THREE.InstancedMesh(triGeo, triMat, N);
mesh.instanceMatrix.setUsage(THREE.DynamicDrawUsage);
mesh.frustumCulled = false;
// allocate instance colours
const _col = new THREE.Color();
for (let i = 0; i < N; i++) { _col.setRGB(cr[i], cg[i], cb[i]); mesh.setColorAt(i, _col); }
mesh.instanceColor.setUsage(THREE.DynamicDrawUsage);
const colArr = mesh.instanceColor.array;
scene.add(mesh);

// fixed per-instance orientation so the tetra facets vary across the cloud
const qBase = [];
for (let i = 0; i < N; i++) {
  const q = new THREE.Quaternion();
  q.setFromEuler(new THREE.Euler(rand(0, 6.28), rand(0, 6.28), rand(0, 6.28)));
  qBase.push(q);
}

/* celebration pings — bright little triangles that flow outward from the globe */
const MAXP = 220;
const pingMat = new THREE.MeshBasicMaterial({ transparent: true, blending: THREE.AdditiveBlending, depthWrite: false });
const pingMesh = new THREE.InstancedMesh(triGeo, pingMat, MAXP);
pingMesh.instanceMatrix.setUsage(THREE.DynamicDrawUsage);
pingMesh.frustumCulled = false;
for (let i = 0; i < MAXP; i++) { _col.setRGB(0, 0, 0); pingMesh.setColorAt(i, _col); }
const pingColArr = pingMesh.instanceColor.array;
scene.add(pingMesh);
const pings = [];
function spawnPing(fixedScreen) {
  pings.push({
    a: rand(0, 6.28), el: rand(-1.2, 1.2), r: 0, vr: rand(0.9, 1.9),
    life: 0, ttl: rand(1.0, 1.9), size: rand(0.02, 0.04),
    q: new THREE.Quaternion().setFromEuler(new THREE.Euler(rand(0, 6), rand(0, 6), rand(0, 6))),
    spin: rand(-4, 4), white: Math.random() < 0.32, fixed: fixedScreen || null,
  });
}

/* layout: radius + on-screen placement, responsive */
let mobile = false, R = 1.8, triSize = 0.03;
function resize() {
  const w = window.innerWidth, h = window.innerHeight;
  if (renderer) { renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2)); renderer.setSize(w, h, false); }
  camera.aspect = w / h; camera.updateProjectionMatrix();
  mobile = w < 880;
  if (mobile) { R = 0.82; triSize = 0.02; mesh.position.set(0, 1.5, 0); }
  else { R = 1.85; triSize = 0.032; mesh.position.set(1.55, 0, 0); }
  pingMesh.position.copy(mesh.position);
}
window.addEventListener("resize", resize);
resize();

/* ── scene state set per section (hover direction, pulse, density) ─────────*/
const scene_ = { hover: "repel", pulse: false };
let densityTarget = 1, density = 1;

/* pointer → magnet (canvas is fixed, full-viewport) */
let pmx = 0, pmy = 0, magOn = false;
if (!("ontouchstart" in window)) {
  window.addEventListener("mousemove", (e) => { pmx = e.clientX; pmy = e.clientY; magOn = true; }, { passive: true });
  window.addEventListener("mouseout", (e) => { if (!e.relatedTarget) magOn = false; });
}
// world-space mouse on the z=0 plane (in mesh-local coords)
const _ray = new THREE.Vector3();
let mlx = 0, mly = 0;
function updateMouseWorld() {
  _ray.set((pmx / window.innerWidth) * 2 - 1, -(pmy / window.innerHeight) * 2 + 1, 0.5);
  _ray.unproject(camera);
  _ray.sub(camera.position).normalize();
  const t = -camera.position.z / _ray.z;
  mlx = camera.position.x + _ray.x * t - mesh.position.x;
  mly = camera.position.y + _ray.y * t - mesh.position.y;
}

/* ── render loop ───────────────────────────────────────────────────────────*/
const _v = new THREE.Vector3();
const _qRot = new THREE.Quaternion();
const _qInst = new THREE.Quaternion();
const _qSpin = new THREE.Quaternion();
const _axisZ = new THREE.Vector3(0, 0, 1);
const _e = new THREE.Euler();
const _dummy = new THREE.Object3D();
let yaw = 0, pitch = -0.16, t0 = performance.now();
const EASE = 0.06;

function frame(now) {
  const dt = Math.min((now - t0) / 1000, 0.05); t0 = now;
  if (!reduceMotion) yaw += dt * 0.16;

  density += (densityTarget - density) * 0.06;
  let pulse = 1;
  if (scene_.pulse && !reduceMotion) {
    const ph = (now % 1500) / 1500;                       // heartbeat every 1.5s
    pulse = 1 + 0.085 * (Math.exp(-7 * ph) + 0.55 * Math.exp(-7 * Math.abs(ph - 0.22)));
  }
  const breathe = reduceMotion ? 0 : Math.sin(now / 2600) * 0.012;
  const Reff = R * density * pulse * (1 + breathe);
  const magR = Reff * 1.18, magR2 = magR * magR;

  _e.set(pitch, yaw, 0); _qRot.setFromEuler(_e);
  if (magOn) updateMouseWorld();

  for (let i = 0; i < N; i++) {
    lx[i] += (txp[i] - lx[i]) * EASE;
    ly[i] += (typ[i] - ly[i]) * EASE;
    lz[i] += (tzp[i] - lz[i]) * EASE;

    _v.set(lx[i], ly[i], lz[i]).applyQuaternion(_qRot).multiplyScalar(Reff);

    if (magOn) {
      const dx = _v.x - mlx, dy = _v.y - mly;
      const d2 = dx * dx + dy * dy;
      if (d2 < magR2) {
        const dist = Math.sqrt(d2) || 1e-4, f = 1 - dist / magR;
        let amt = f * f * Reff * 0.6;
        if (scene_.hover === "attract") amt = -Math.min(amt, dist * 0.85);
        _v.x += (dx / dist) * amt; _v.y += (dy / dist) * amt;
      }
    }

    const tw = reduceMotion ? 1 : 0.9 + 0.1 * Math.sin(now / 600 + seedOff[i]);
    vis[i] += (tvis[i] - vis[i]) * EASE;
    _dummy.position.copy(_v);
    _qInst.multiplyQuaternions(_qRot, qBase[i]);
    _dummy.quaternion.copy(_qInst);
    _dummy.scale.setScalar(triSize * vis[i] * tw);
    _dummy.updateMatrix();
    mesh.setMatrixAt(i, _dummy.matrix);

    cr[i] += (tcr[i] - cr[i]) * EASE; cg[i] += (tcg[i] - cg[i]) * EASE; cb[i] += (tcb[i] - cb[i]) * EASE;
    colArr[i * 3] = cr[i]; colArr[i * 3 + 1] = cg[i]; colArr[i * 3 + 2] = cb[i];
  }
  mesh.instanceMatrix.needsUpdate = true;
  mesh.instanceColor.needsUpdate = true;

  // pings
  for (let k = pings.length - 1; k >= 0; k--) {
    const p = pings[k];
    p.life += dt; p.r += p.vr * dt;
    if (p.life > p.ttl || k >= MAXP) { pings.splice(k, 1); continue; }
  }
  for (let i = 0; i < MAXP; i++) {
    const p = pings[i];
    if (!p) { _dummy.scale.setScalar(0); _dummy.updateMatrix(); pingMesh.setMatrixAt(i, _dummy.matrix); continue; }
    const fade = 1 - p.life / p.ttl;
    if (p.fixed) {
      _v.set((p.fixed.x / window.innerWidth) * 2 - 1, -(p.fixed.y / window.innerHeight) * 2 + 1, 0.5).unproject(camera);
      _v.sub(camera.position).normalize();
      const t = (-camera.position.z) / _v.z;
      _v.set(camera.position.x + _v.x * t - mesh.position.x, camera.position.y + _v.y * t - mesh.position.y + p.r * 1.2, 0);
    } else {
      const rr = (1 + p.r * 0.8) * Reff;
      _v.set(Math.cos(p.a) * Math.cos(p.el), Math.sin(p.el), Math.sin(p.a) * Math.cos(p.el)).applyQuaternion(_qRot).multiplyScalar(rr);
    }
    _qSpin.setFromAxisAngle(_axisZ, p.spin * dt); p.q.multiply(_qSpin);
    _dummy.position.copy(_v); _dummy.quaternion.copy(p.q); _dummy.scale.setScalar(p.size * fade);
    _dummy.updateMatrix(); pingMesh.setMatrixAt(i, _dummy.matrix);
    const c = p.white ? C.bone : C.plumSoft;
    pingColArr[i * 3] = c[0] * fade; pingColArr[i * 3 + 1] = c[1] * fade; pingColArr[i * 3 + 2] = c[2] * fade;
  }
  pingMesh.instanceMatrix.needsUpdate = true;
  pingMesh.instanceColor.needsUpdate = true;

  renderer.render(scene, camera);
  requestAnimationFrame(frame);
}
if (renderer) requestAnimationFrame(frame);

/* ═══════════════════════════════════════════════════════════════════════════
   3. SCROLL → SCENE
   ═══════════════════════════════════════════════════════════════════════════ */
const shapeCycle = ["basketball", "tennis", "baseball", "football"];
let cycleTimer = null, cycleIdx = 0;
function startCycle() { stopCycle(); morphTo(shapeCycle[cycleIdx % shapeCycle.length]); cycleTimer = setInterval(() => { cycleIdx++; morphTo(shapeCycle[cycleIdx % shapeCycle.length]); }, 2400); }
function stopCycle() { if (cycleTimer) { clearInterval(cycleTimer); cycleTimer = null; } }

let globeTimer = null;
function startGlobePings() { stopGlobePings(); globeTimer = setInterval(() => { if (!reduceMotion) for (let i = 0; i < 4; i++) spawnPing(); }, 460); }
function stopGlobePings() { if (globeTimer) { clearInterval(globeTimer); globeTimer = null; } }

let pillOverride = false, activeSection = null;
function applyScene(el) {
  stopCycle(); stopGlobePings();
  const shape = el.dataset.shape;
  scene_.hover = el.dataset.hover || "repel";
  scene_.pulse = el.hasAttribute("data-pulse");
  densityTarget = el.hasAttribute("data-dense") ? 0.84 : 1;
  if (shape === "cycle") { if (!pillOverride) startCycle(); }
  else { morphTo(shape); if (el.hasAttribute("data-pings")) startGlobePings(); }
}
const sectionObserver = new IntersectionObserver((entries) => {
  entries.forEach((e) => { if (e.isIntersecting && e.intersectionRatio >= 0.5) { activeSection = e.target; applyScene(e.target); } });
}, { threshold: [0.5] });
document.querySelectorAll("[data-shape]").forEach((s) => sectionObserver.observe(s));

document.querySelectorAll(".next-pill[data-ball]").forEach((pill) => {
  pill.addEventListener("mouseenter", () => { pillOverride = true; stopCycle(); scene_.hover = "repel"; densityTarget = 1; morphTo(pill.dataset.ball); });
  pill.addEventListener("mouseleave", () => { pillOverride = false; if (activeSection && activeSection.dataset.shape === "cycle") startCycle(); });
});

/* ═══════════════════════════════════════════════════════════════════════════
   4. REVEAL ON SCROLL + NAV
   ═══════════════════════════════════════════════════════════════════════════ */
const revealObserver = new IntersectionObserver((entries) => {
  entries.forEach((e) => { if (e.isIntersecting) { e.target.classList.add("in"); revealObserver.unobserve(e.target); } });
}, { threshold: 0.18 });
document.querySelectorAll(".reveal").forEach((el) => revealObserver.observe(el));

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
  el.innerHTML = `<span class="pill-ico ${a.cls}">${a.ico}</span><span class="pill-body"><span class="pill-title">${a.title}</span><span class="pill-sub">${a.sub}</span></span><span class="pill-time">${a.time}</span>`;
  desktop.prepend(el);
  if (a.cls === "goal" && a.ico === "⚽") burstConfetti(0.4);
  while (desktop.children.length > 3) desktop.lastChild.remove();
}
let notchTimer = null;
if (desktop) {
  new IntersectionObserver((entries) => {
    entries.forEach((e) => {
      if (e.isIntersecting && !notchTimer) { dropAlert(); notchTimer = setInterval(dropAlert, reduceMotion ? 4000 : 2600); }
      else if (!e.isIntersecting && notchTimer) { clearInterval(notchTimer); notchTimer = null; }
    });
  }, { threshold: 0.4 }).observe(desktop.closest(".panel"));
}

/* ═══════════════════════════════════════════════════════════════════════════
   6. CELEBRATIONS — counter + tap-to-celebrate
   ═══════════════════════════════════════════════════════════════════════════ */
const counterEl = document.getElementById("count");
let count = 4210338, displayCount = count;
const fmt = (n) => Math.floor(n).toLocaleString("en-US");
if (counterEl) {
  counterEl.textContent = fmt(displayCount);
  setInterval(() => { if (!reduceMotion) count += Math.floor(rand(3, 22)); }, 900);
  (function tickCount() { displayCount += (count - displayCount) * 0.12; counterEl.textContent = fmt(displayCount); requestAnimationFrame(tickCount); })();
}
const celebrateBtn = document.getElementById("celebrate");
if (celebrateBtn) {
  celebrateBtn.addEventListener("click", () => {
    count += Math.floor(rand(80, 260));
    const r = celebrateBtn.getBoundingClientRect();
    burstConfetti(1, { x: r.left + r.width / 2, y: r.top });
    for (let i = 0; i < 16; i++) spawnPing();
  });
}

/* ═══════════════════════════════════════════════════════════════════════════
   7. CONFETTI (2D overlay)
   ═══════════════════════════════════════════════════════════════════════════ */
const conf = document.getElementById("confetti");
const cc = conf.getContext("2d");
let bits = [], confRaf = null, confLast = 0, confDpr = Math.min(window.devicePixelRatio || 1, 2);
const CONF_COLORS = ["#8052ff", "#a585ff", "#ffb829", "#1faa8a", "#ffffff", "#ff3b52"];
function sizeConf() { confDpr = Math.min(window.devicePixelRatio || 1, 2); conf.width = innerWidth * confDpr; conf.height = innerHeight * confDpr; cc.setTransform(confDpr, 0, 0, confDpr, 0, 0); }
window.addEventListener("resize", sizeConf); sizeConf();
function burstConfetti(scale = 1, origin) {
  if (reduceMotion) return;
  const sources = origin ? [{ x: origin.x, y: origin.y, base: -Math.PI / 2, spread: Math.PI }]
    : [{ x: -10, y: innerHeight + 10, base: -1.15, spread: 0.5 }, { x: innerWidth + 10, y: innerHeight + 10, base: -Math.PI + 1.15, spread: 0.5 }];
  for (const s of sources) {
    const n = Math.floor((origin ? 70 : 60) * scale);
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
