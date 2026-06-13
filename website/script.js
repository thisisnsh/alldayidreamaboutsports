/* ── All Day I Dream About Sports — interactions ────────────────────────── */

const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

function pick(arr) {
  return arr[Math.floor(Math.random() * arr.length)];
}

/* ── Confetti (defined first so anything can trigger it) ─────────────────── */
const canvas = document.getElementById("confetti");
const ctx = canvas.getContext("2d");
let particles = [];
let rafId = null;
let lastFrame = 0;

const CONFETTI_COLORS = ["#ffd166", "#06d6a0", "#118ab2", "#ef476f", "#ffffff", "#ffa400", "#ff5d8f"];
const GRAVITY = 900;

function sizeCanvas() {
  const dpr = window.devicePixelRatio || 1;
  canvas.width = canvas.clientWidth * dpr;
  canvas.height = canvas.clientHeight * dpr;
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
}
window.addEventListener("resize", sizeCanvas);

// Burst from the bottom-left and bottom-right corners of the screen.
function burstConfetti() {
  if (reduceMotion) return;
  sizeCanvas();
  const w = canvas.clientWidth;
  const h = canvas.clientHeight;
  const corners = [
    { x: -10, y: h + 10, dir: 1 },
    { x: w + 10, y: h + 10, dir: -1 },
  ];

  for (const c of corners) {
    for (let i = 0; i < 70; i++) {
      const angle = 1.05 + Math.random() * 0.45; // steep, mostly vertical
      const speed = 620 + Math.random() * 520;
      particles.push({
        x: c.x,
        y: c.y,
        vx: Math.cos(angle) * speed * c.dir,
        vy: -Math.sin(angle) * speed,
        color: pick(CONFETTI_COLORS),
        size: 7 + Math.random() * 8,
        rot: Math.random() * Math.PI,
        spin: (Math.random() - 0.5) * 12,
        life: 0,
        ttl: 2.6 + Math.random() * 1.2,
        delay: Math.random() * 0.25,
      });
    }
  }

  if (!rafId) {
    lastFrame = performance.now();
    rafId = requestAnimationFrame(tick);
  }
}

function tick(now) {
  const dt = Math.min((now - lastFrame) / 1000, 0.05);
  lastFrame = now;
  ctx.clearRect(0, 0, canvas.clientWidth, canvas.clientHeight);

  particles = particles.filter((p) => {
    if (p.delay > 0) { p.delay -= dt; return true; }
    p.life += dt;
    if (p.life > p.ttl) return false;

    p.vy += GRAVITY * dt;
    p.x += p.vx * dt;
    p.y += p.vy * dt;
    p.rot += p.spin * dt;

    const fade = p.life > p.ttl - 1.2 ? Math.max(0, (p.ttl - p.life) / 1.2) : 1;
    ctx.save();
    ctx.globalAlpha = fade;
    ctx.translate(p.x, p.y);
    ctx.rotate(p.rot);
    ctx.fillStyle = p.color;
    ctx.fillRect(-p.size / 2, -p.size / 2, p.size, p.size * 0.6);
    ctx.restore();
    return true;
  });

  if (particles.length > 0) {
    rafId = requestAnimationFrame(tick);
  } else {
    ctx.clearRect(0, 0, canvas.clientWidth, canvas.clientHeight);
    rafId = null;
  }
}

/* ── 1. Notifications + caption drop / hold / float up as one group ──────── */
const notify = document.querySelector(".notify");
const pillIcon = document.getElementById("pill-icon");
const pillTitle = document.getElementById("pill-title");
const pillSub = document.getElementById("pill-sub");
const caption = document.getElementById("caption");

const alerts = [
  {
    icon: "⚽",
    title: "Goal — Messi 108'",
    sub: "🇦🇷 Argentina 3–2 France 🇫🇷",
    caption: "Live match alerts, right below your notch — for the teams you care about.",
    celebrate: true,
  },
  {
    icon: "🟨",
    title: "Yellow Card — Gonzalo Montiel 116'",
    sub: "",
    caption: "Get notified about every other moment in the match, too.",
    celebrate: false,
  },
  {
    icon: "🏁",
    title: "Full-time — Argentina Won",
    sub: "🇦🇷 Argentina 3–3 France 🇫🇷 · 4–2 pens",
    caption: "From kickoff to the final whistle, never miss how it ends.",
    celebrate: false,
  },
  {
    icon: "🎉",
    title: "4.2M celebrations for Argentina this match",
    sub: "",
    caption: "Celebrate every goal live, together with other fans of your team.",
    celebrate: true,
  },
];

// Timing (ms)
const DROP_MS = 500;   // drop-in animation
const HOLD_MS = 3000;  // stay on screen
const LIFT_MS = 350;   // float-up animation
const GAP_MS = 450;    // empty pause before the next one drops

// Flatten alerts into an alternating sequence: pill, its caption, pill, ...
const frames = [];
alerts.forEach((a) => {
  frames.push({ kind: "pill", icon: a.icon, title: a.title, sub: a.sub, celebrate: a.celebrate });
  frames.push({ kind: "caption", text: a.caption });
});

let frameIndex = 0;

function renderFrame(f) {
  if (f.kind === "pill") {
    caption.hidden = true;
    pill.hidden = false;
    pillIcon.textContent = f.icon;
    pillTitle.textContent = f.title;
    pillSub.textContent = f.sub;
  } else {
    pill.hidden = true;
    caption.hidden = false;
    caption.textContent = f.text;
  }
}

function runCycle() {
  const f = frames[frameIndex % frames.length];
  frameIndex++;

  // Swap content while the group is hidden (no crossfade overlap).
  renderFrame(f);

  notify.classList.remove("lift");
  void notify.offsetWidth; // restart animation
  notify.classList.add("drop");
  if (f.celebrate) burstConfetti();

  setTimeout(() => {
    notify.classList.remove("drop");
    void notify.offsetWidth;
    notify.classList.add("lift");
    setTimeout(runCycle, LIFT_MS + GAP_MS);
  }, DROP_MS + HOLD_MS);
}

if (reduceMotion) {
  notify.style.opacity = "1";
  renderFrame(frames[0]);
  if (frames[0].celebrate) burstConfetti();
  setInterval(() => {
    frameIndex++;
    const f = frames[frameIndex % frames.length];
    renderFrame(f);
    if (f.celebrate) burstConfetti();
  }, DROP_MS + HOLD_MS + LIFT_MS + GAP_MS);
} else {
  runCycle();
}

/* ── 2. Title: only "Sports" restyles, every second ─────────────────────── */
const flexWord = document.getElementById("flexword");

const caseClasses = ["case-upper", "case-lower", "case-title"];
const fontClasses = ["font-sans", "font-serif", "font-display", "font-cursive"];
const accentClasses = ["is-italic", "is-bold", "is-thin", "is-underline"];
const ALL_CLASSES = [...caseClasses, ...fontClasses, ...accentClasses];

function applyRandomStyle(w) {
  w.classList.remove(...ALL_CLASSES);
  const styles = [pick(caseClasses), pick(fontClasses)];
  // Cursive reads best on its own; otherwise add 0–2 random accents.
  if (!styles.includes("font-cursive")) {
    const accents = [...accentClasses].sort(() => Math.random() - 0.5);
    const count = Math.floor(Math.random() * 3); // 0, 1, or 2
    for (let i = 0; i < count; i++) styles.push(accents[i]);
  }
  w.classList.add(...styles);
}

function startTitle() {
  applyRandomStyle(flexWord);
  if (!reduceMotion) {
    setInterval(() => applyRandomStyle(flexWord), 1000);
  }
}

if (document.fonts && document.fonts.ready) {
  document.fonts.ready.then(startTitle);
} else {
  window.addEventListener("load", startTitle);
}

/* ── 3. Confetti on download click ──────────────────────────────────────── */
document.getElementById("download").addEventListener("click", () => burstConfetti());
