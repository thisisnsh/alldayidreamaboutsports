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
  seam: [0, 0, 0],
};

/* ═══════════════════════════════════════════════════════════════════════════
   1. SHAPE MATH  — every particle keeps a fixed identity (a fibonacci-sphere
   direction); a shape just decides its target position, colour & visibility.
   ═══════════════════════════════════════════════════════════════════════════ */
const N = window.innerWidth < 760 ? 3800 : 6800;

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

// truncated-icosahedron panels, taken straight from the reference soccer-ball
// geometry: 60 vertices + 32 faces. Faces 0–11 are pentagons (small → white),
// faces 12–31 are hexagons (big → purple). Each panel's centre is the
// normalised centroid of its own vertices, so the tiling — and which face is a
// hexagon vs a pentagon — matches the reference exactly.
const norm3 = (a, b, c) => { const l = Math.hypot(a, b, c); return [a / l, b / l, c / l]; };
const tD = (1 + Math.sqrt(5)) / 2;                 // golden ratio (reference's "d")
const tB = 1, tC = 2, tE = 3 * tD, tF = 1 + 2 * tD, tG = 2 + tD, tH = 2 * tD;
const TI_VERTS = [
  [0, tB, tE], [0, tB, -tE], [0, -tB, tE], [0, -tB, -tE],
  [tB, tE, 0], [tB, -tE, 0], [-tB, tE, 0], [-tB, -tE, 0],
  [tE, 0, tB], [-tE, 0, tB], [tE, 0, -tB], [-tE, 0, -tB],
  [tC, tF, tD], [tC, tF, -tD], [tC, -tF, tD], [-tC, tF, tD],
  [tC, -tF, -tD], [-tC, tF, -tD], [-tC, -tF, tD], [-tC, -tF, -tD],
  [tF, tD, tC], [tF, -tD, tC], [-tF, tD, tC], [tF, tD, -tC],
  [-tF, -tD, tC], [tF, -tD, -tC], [-tF, tD, -tC], [-tF, -tD, -tC],
  [tD, tC, tF], [-tD, tC, tF], [tD, tC, -tF], [tD, -tC, tF],
  [-tD, tC, -tF], [-tD, -tC, tF], [tD, -tC, -tF], [-tD, -tC, -tF],
  [tB, tG, tH], [tB, tG, -tH], [tB, -tG, tH], [-tB, tG, tH],
  [tB, -tG, -tH], [-tB, tG, -tH], [-tB, -tG, tH], [-tB, -tG, -tH],
  [tG, tH, tB], [tG, -tH, tB], [-tG, tH, tB], [tG, tH, -tB],
  [-tG, -tH, tB], [tG, -tH, -tB], [-tG, tH, -tB], [-tG, -tH, -tB],
  [tH, tB, tG], [-tH, tB, tG], [tH, tB, -tG], [tH, -tB, tG],
  [-tH, tB, -tG], [-tH, -tB, tG], [tH, -tB, -tG], [-tH, -tB, -tG],
];
const TI_FACES = [
  [0, 28, 36, 39, 29], [1, 32, 41, 37, 30], [2, 33, 42, 38, 31], [3, 34, 40, 43, 35],
  [4, 12, 44, 47, 13], [5, 16, 49, 45, 14], [6, 17, 50, 46, 15], [7, 18, 48, 51, 19],
  [8, 20, 52, 55, 21], [9, 24, 57, 53, 22], [10, 25, 58, 54, 23], [11, 26, 56, 59, 27],
  [0, 2, 31, 55, 52, 28], [0, 29, 53, 57, 33, 2], [1, 3, 35, 59, 56, 32], [1, 30, 54, 58, 34, 3],
  [4, 6, 15, 39, 36, 12], [4, 13, 37, 41, 17, 6], [5, 7, 19, 43, 40, 16], [5, 14, 38, 42, 18, 7],
  [8, 10, 23, 47, 44, 20], [8, 21, 45, 49, 25, 10], [9, 11, 27, 51, 48, 24], [9, 22, 46, 50, 26, 11],
  [12, 36, 28, 52, 20, 44], [13, 47, 23, 54, 30, 37], [14, 45, 21, 55, 31, 38], [15, 46, 22, 53, 29, 39],
  [16, 40, 34, 58, 25, 49], [17, 41, 32, 56, 26, 50], [18, 42, 33, 57, 24, 48], [19, 51, 27, 59, 35, 43],
];
const panels = TI_FACES.map((face, idx) => {
  let cx = 0, cy = 0, cz = 0;
  for (const v of face) { cx += TI_VERTS[v][0]; cy += TI_VERTS[v][1]; cz += TI_VERTS[v][2]; }
  return { c: norm3(cx, cy, cz), pent: idx < 12 ? 1 : 0 };   // first 12 faces are pentagons
});

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
  if (d1 - d2 < 0.024) { o.c = C.seam; o.v = 0; }         // thin invisible seam → crisp hex edges
  else if (pent) { o.c = C.bone; o.v = 1; }               // pentagon (small) → white
  else { o.c = C.plum; o.v = 1; }                         // hexagon (big) → purple
}

// Globe: triangles fall only on the continents (sampled from the equirectangular
// mask, see loadMask), each a purple/white speckle. Until the image decodes the
// mask is all-zero, so we fall back to the airy body — the first scroll is never
// an empty sphere.
const speckle = (i) => (por[i] < 0.46 ? C.plum : por[i] < 0.7 ? C.plumSoft : C.bone);
function shapeGlobe(i, o) {
  o.x = dirs[i * 3]; o.y = dirs[i * 3 + 1]; o.z = dirs[i * 3 + 2];
  o.v = maskReady.globe ? mask.globe[i] : body(i);
  o.c = speckle(i);
}
// Basketball: the panels are painted purple/white and the seams are left empty
// (like the soccer ball's gaps) so the ball reads without rendering any black
// lines. Seam layout matches the reference texture: a centre ring, two vertical
// great-circle seams (u = .25/.75), and wavy top/bottom seams from a sin² wobble.
function shapeBasketball(i, o) {
  const y = dirs[i * 3 + 1];
  o.x = dirs[i * 3]; o.y = y; o.z = dirs[i * 3 + 2];
  const u = 1 - (Math.atan2(o.z, o.x) + Math.PI) / (2 * Math.PI);
  const v = 0.5 - Math.asin(y) / Math.PI;          // 0 = north pole, 1 = south
  const s = Math.sin(Math.PI * 2 * u), wob = 0.13 * s * s;
  const top = 0.22 + wob, bot = 0.78 - wob;
  const onSeam =
    Math.abs(v - 0.5) < 0.022 || Math.abs(v - top) < 0.022 || Math.abs(v - bot) < 0.022 ||
    Math.min(Math.abs(u - 0.25), Math.abs(u - 0.75), Math.abs(u - 1.25), Math.abs(u + 0.25)) < 0.016;
  if (onSeam) { o.c = C.seam; o.v = 0; return; }   // seam → empty gap (like the soccer ball)
  o.v = 1;                                         // every panel particle shows → solid, crisp panels
  const purple = v < top || (v >= 0.5 && v < bot);
  o.c = purple ? C.plum : C.bone;
}
const SHAPES = { soccer: shapeSoccer, globe: shapeGlobe, basketball: shapeBasketball };

/* Per-instance live state */
const lx = new Float32Array(N), ly = new Float32Array(N), lz = new Float32Array(N);   // current unit pos
const txp = new Float32Array(N), typ = new Float32Array(N), tzp = new Float32Array(N); // target
const cr = new Float32Array(N), cg = new Float32Array(N), cb = new Float32Array(N);
const tcr = new Float32Array(N), tcg = new Float32Array(N), tcb = new Float32Array(N);
const vis = new Float32Array(N), tvis = new Float32Array(N);
const seedOff = new Float32Array(N);
for (let i = 0; i < N; i++) seedOff[i] = Math.random() * Math.PI * 2;

// Stable per-particle porosity. The soccer ball shows only ~36% of its
// particles (the rest fall on invisible seams) — that's what makes it airy.
// Every other shape hides the same fraction of its "body" so they all read
// with the same light density. Lines/seams stay solid on top of this.
const por = new Float32Array(N);
for (let i = 0; i < N; i++) por[i] = Math.random();
const GAP = 0.64;
const body = (i) => (por[i] > GAP ? 1 : 0);

// Globe land/ocean mask: a particle is "on" where the equirectangular image is
// dark (a continent). Fills once the image decodes; until then the globe falls
// back to the airy body so the first scroll is never an empty sphere.
const mask = { globe: new Float32Array(N) };
const maskReady = { globe: false };
function loadMask(src, key, W, H, thresh) {
  const img = new Image();
  img.onload = () => {
    const cv = document.createElement("canvas"); cv.width = W; cv.height = H;
    const cx = cv.getContext("2d", { willReadFrequently: true });
    cx.drawImage(img, 0, 0, W, H);
    const px = cx.getImageData(0, 0, W, H).data, arr = mask[key];
    for (let i = 0; i < N; i++) {
      const lat = Math.asin(dirs[i * 3 + 1]);
      const lon = Math.atan2(dirs[i * 3 + 2], dirs[i * 3]);
      const u = 1 - (lon + Math.PI) / (2 * Math.PI);    // flip so it reads east-west
      const v = 0.5 - lat / Math.PI;                    // north pole → top row
      const sx = Math.min(W - 1, Math.max(0, (u * W) | 0));
      const sy = Math.min(H - 1, Math.max(0, (v * H) | 0));
      arr[i] = px[(sy * W + sx) * 4] < thresh ? 1 : 0;  // dark pixel = land
    }
    maskReady[key] = true;
    if (currentShape === key) setTargets(key);
  };
  img.src = src;
}
loadMask("assets/earth-mask.jpg", "globe", 1000, 500, 110);

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
// Shapes change by simply re-pointing every particle at its new target; the
// per-frame ease (staggered per particle, see frame()) glides each triangle
// across so the figure rearranges in place — no expand-and-collapse burst.
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

// Per-instance orientation: align each tetra's +Y to its radial direction so the
// facets lie on the sphere as a coherent shell (not scattered confetti), with a
// random twist in the tangent plane for organic variety.
const qBase = [];
{
  const _up = new THREE.Vector3(0, 1, 0), _dir = new THREE.Vector3(), _tw = new THREE.Quaternion();
  for (let i = 0; i < N; i++) {
    _dir.set(dirs[i * 3], dirs[i * 3 + 1], dirs[i * 3 + 2]).normalize();
    const q = new THREE.Quaternion().setFromUnitVectors(_up, _dir);
    _tw.setFromAxisAngle(_up, rand(0, 6.28));
    q.multiply(_tw);
    qBase.push(q);
  }
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
  // On mobile the ball spans the full viewport width and is anchored low, so a
  // little of it is cropped off the bottom and the copy sits above it.
  if (mobile) {
    const halfH = Math.tan(((40 * Math.PI) / 180) / 2) * 6.6;  // visible half-height at z=0
    R = halfH * (w / h);                                       // width = 100%
    triSize = R * 0.023;
    mesh.position.set(0, -halfH + 0.85 * R, 0);                // crop ~15% off the bottom
  }
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
  // Only beat once the ball has fully settled into its smallest (dense) scale —
  // never while it's still shrinking in.
  const settled = Math.abs(density - densityTarget) < 0.004;
  let pulse = 1;
  if (scene_.pulse && settled && !reduceMotion) {
    const ph = (now % 1500) / 1500;                       // heartbeat every 1.5s
    pulse = 1 + 0.085 * (Math.exp(-7 * ph) + 0.55 * Math.exp(-7 * Math.abs(ph - 0.22)));
  }
  const breathe = reduceMotion ? 0 : Math.sin(now / 2600) * 0.012;
  const Reff = R * density * pulse * (1 + breathe);
  const magR = Reff * 0.6, magR2 = magR * magR;

  _e.set(pitch, yaw, 0); _qRot.setFromEuler(_e);
  if (magOn) updateMouseWorld();

  for (let i = 0; i < N; i++) {
    // Stagger the ease per particle so a morph reads as a flowing rearrangement
    // (some triangles slide ahead, some lag) rather than a uniform snap.
    const ei = EASE * (0.55 + 0.9 * por[i]);
    lx[i] += (txp[i] - lx[i]) * ei;
    ly[i] += (typ[i] - ly[i]) * ei;
    lz[i] += (tzp[i] - lz[i]) * ei;

    _v.set(lx[i], ly[i], lz[i]).applyQuaternion(_qRot).multiplyScalar(Reff);

    if (magOn) {
      const dx = _v.x - mlx, dy = _v.y - mly;
      const d2 = dx * dx + dy * dy;
      if (d2 < magR2) {
        const dist = Math.sqrt(d2) || 1e-4, f = 1 - dist / magR;
        const press = f * f;
        if (scene_.hover === "attract") {            // gentle pull toward the cursor
          _v.x -= dx * press * 0.3; _v.y -= dy * press * 0.3;
          _v.z -= press * Reff * 0.22;
        } else {                                     // pressed-in dent: barely part, push back
          _v.x += (dx / dist) * press * Reff * 0.12;
          _v.y += (dy / dist) * press * Reff * 0.12;
          _v.z -= press * Reff * 0.42;
        }
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
    // depth dimming: far side (back of the sphere) is darker so it reads behind
    // the front and the two don't visually merge.
    const dz = _v.z / Reff;                              // ~ -1 (back) .. +1 (front)
    const lum = 0.3 + 0.7 * Math.min(1, Math.max(0, dz * 0.5 + 0.5));
    colArr[i * 3] = cr[i] * lum; colArr[i * 3 + 1] = cg[i] * lum; colArr[i * 3 + 2] = cb[i] * lum;
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
let globeTimer = null;
function startGlobePings() { stopGlobePings(); globeTimer = setInterval(() => { if (!reduceMotion) for (let i = 0; i < 4; i++) spawnPing(); }, 460); }
function stopGlobePings() { if (globeTimer) { clearInterval(globeTimer); globeTimer = null; } }

let activeSection = null;
function applyScene(el) {
  stopGlobePings();
  scene_.hover = el.dataset.hover || "repel";
  scene_.pulse = el.hasAttribute("data-pulse");
  densityTarget = el.hasAttribute("data-dense") ? 0.72 : 1;
  morphTo(el.dataset.shape);
  if (el.hasAttribute("data-pings")) startGlobePings();
}
// Fire when a section crosses the vertical centre of the viewport — i.e. once it
// has come half way up the screen — rather than as soon as 50% of its area shows
// (which triggers too early for the short, text-light sections on mobile).
const sectionObserver = new IntersectionObserver((entries) => {
  entries.forEach((e) => { if (e.isIntersecting) { activeSection = e.target; applyScene(e.target); } });
}, { rootMargin: "-50% 0px -50% 0px", threshold: 0 });
document.querySelectorAll("[data-shape]").forEach((s) => sectionObserver.observe(s));

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

// Mobile hamburger — toggle the dropdown menu, close on link tap
const navToggle = document.querySelector(".nav-toggle");
if (navToggle) {
  const setMenu = (open) => {
    nav.classList.toggle("menu-open", open);
    navToggle.setAttribute("aria-expanded", open ? "true" : "false");
  };
  navToggle.addEventListener("click", () => setMenu(!nav.classList.contains("menu-open")));
  nav.querySelectorAll(".nav-links a").forEach((a) =>
    a.addEventListener("click", () => setMenu(false))
  );
}

/* ═══════════════════════════════════════════════════════════════════════════
   5. NOTCH DROPS — live alert demo
   ═══════════════════════════════════════════════════════════════════════════ */
const desktop = document.getElementById("desktop");
// The full Argentina v France final, in order — primary line + secondary line,
// with a colour dot keyed to the legend chips above.
const ALERTS = [
  { cls: "fixture", title: "World Cup 2022 Final", sub: "🇦🇷 Argentina vs France 🇫🇷", time: "0'" },
  { cls: "goal", title: "Goal · Lionel Messi", sub: "🇦🇷 Argentina 1–0 France 🇫🇷 · Penalty", time: "23'" },
  { cls: "goal", title: "Goal · Ángel Di María", sub: "🇦🇷 Argentina 2–0 France 🇫🇷", time: "36'" },
  { cls: "yellow", title: "Yellow · Enzo Fernández", sub: "🇦🇷 Argentina", time: "45+7" },
  { cls: "full", title: "Half time", sub: "🇦🇷 Argentina 2–0 France 🇫🇷", time: "HT" },
  { cls: "yellow", title: "Yellow · Adrien Rabiot", sub: "🇫🇷 France", time: "55'" },
  { cls: "goal", title: "Goal · Kylian Mbappé", sub: "🇦🇷 Argentina 2–1 France 🇫🇷 · Penalty", time: "80'" },
  { cls: "goal", title: "Goal · Kylian Mbappé", sub: "🇦🇷 Argentina 2–2 France 🇫🇷", time: "81'" },
  { cls: "yellow", title: "Yellow · Marcus Thuram", sub: "🇫🇷 France", time: "87'" },
  { cls: "yellow", title: "Yellow · Olivier Giroud", sub: "🇫🇷 France", time: "90+5" },
  { cls: "yellow", title: "Yellow · Marcos Acuña", sub: "🇦🇷 Argentina", time: "90+8" },
  { cls: "full", title: "Full time", sub: "🇦🇷 Argentina 2–2 France 🇫🇷", time: "FT" },
  { cls: "fixture", title: "Extra time begins", sub: "🇦🇷 Argentina 2–2 France 🇫🇷", time: "91'" },
  { cls: "goal", title: "Goal · Lionel Messi", sub: "🇦🇷 Argentina 3–2 France 🇫🇷", time: "108'" },
  { cls: "yellow", title: "Yellow · Leandro Paredes", sub: "🇦🇷 Argentina", time: "114'" },
  { cls: "yellow", title: "Yellow · Gonzalo Montiel", sub: "🇦🇷 Argentina", time: "116'" },
  { cls: "goal", title: "Goal · Kylian Mbappé", sub: "🇦🇷 Argentina 3–3 France 🇫🇷 · Penalty", time: "118'" },
  { cls: "full", title: "Extra time ends", sub: "🇦🇷 Argentina 3–3 France 🇫🇷", time: "120+3" },
  { cls: "pen", title: "Penalty · Messi scores", sub: "🇦🇷 Argentina · Shootout", time: "PSO 1" },
  { cls: "pen", title: "Penalty · Mbappé scores", sub: "🇫🇷 France · Shootout", time: "PSO 1" },
  { cls: "pen", title: "Penalty · Dybala scores", sub: "🇦🇷 Argentina · Shootout", time: "PSO 2" },
  { cls: "red", title: "Penalty · Coman saved", sub: "🇫🇷 France · Shootout", time: "PSO 2" },
  { cls: "pen", title: "Penalty · Paredes scores", sub: "🇦🇷 Argentina · Shootout", time: "PSO 3" },
  { cls: "red", title: "Penalty · Tchouaméni misses", sub: "🇫🇷 France · Shootout", time: "PSO 3" },
  { cls: "pen", title: "Penalty · Montiel scores", sub: "🇦🇷 Argentina · Shootout", time: "PSO 4" },
  { cls: "pen", title: "Penalty · Kolo Muani scores", sub: "🇫🇷 France · Shootout", time: "PSO 4" },
  { cls: "yellow", title: "Yellow · Emiliano Martínez", sub: "🇦🇷 Argentina", time: "120+6" },
  { cls: "full", title: "Argentina win", sub: "🇦🇷 Argentina 4–2 France 🇫🇷 · Penalties", time: "FT" },
];
let alertIdx = 0;
function dropAlert() {
  if (!desktop) return;
  const a = ALERTS[alertIdx % ALERTS.length]; alertIdx++;
  const el = document.createElement("div");
  el.className = "pill drop";
  el.innerHTML = `<span class="pill-dot ${a.cls}"></span><span class="pill-body"><span class="pill-title">${a.title}</span><span class="pill-sub">${a.sub}</span></span><span class="pill-time">${a.time}</span>`;
  desktop.prepend(el);
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
   6. CONFETTI (2D overlay)
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
