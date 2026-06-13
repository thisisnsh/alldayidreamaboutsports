/* ── All Day I Dream About Sports — interactions ────────────────────────── */

const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

/* ── 1. Notifications dropping from the notch ───────────────────────────── */
const pill = document.getElementById("pill");
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
    celebrate: false,
  },
  {
    icon: "🎉",
    title: "4.2M celebrations for Argentina this match",
    sub: "",
    caption: "Celebrate every goal live, together with other fans of your team.",
    celebrate: true,
  },
  {
    icon: "🟨",
    title: "Yellow Card — Gonzalo Montiel 116'",
    sub: "",
    caption: "Get notified about every other moment in the match, too.",
    celebrate: false,
  },
];

let alertIndex = 0;

function renderAlert(a) {
  pillIcon.textContent = a.icon;
  pillTitle.textContent = a.title;
  pillSub.textContent = a.sub;
  caption.textContent = a.caption;
  if (a.celebrate) burstConfetti();
}

function showNextAlert() {
  const a = alerts[alertIndex % alerts.length];
  alertIndex++;

  if (reduceMotion) {
    renderAlert(a);
    return;
  }

  // Float the current pill up, then drop the next one in.
  pill.classList.remove("drop");
  pill.classList.add("lift");
  caption.style.opacity = "0";

  setTimeout(() => {
    renderAlert(a);
    pill.classList.remove("lift");
    pill.classList.add("drop");
    caption.style.opacity = "1";
  }, 320);
}

// First alert is already in the markup; animate it in, then cycle.
if (!reduceMotion) pill.classList.add("drop");
if (alerts[0].celebrate) burstConfetti();
alertIndex = 1;
setInterval(showNextAlert, 3600);

/* ── 2. Title: every word gets a random style every 2s ──────────────────── */
const words = Array.from(document.querySelectorAll("#title .word"));

const caseClasses = ["case-upper", "case-lower", "case-title"];
const fontClasses = ["font-sans", "font-serif", "font-display", "font-cursive"];
const accentClasses = ["is-italic", "is-bold", "is-thin", "is-underline"];
const ALL_CLASSES = [...caseClasses, ...fontClasses, ...accentClasses];

function pick(arr) {
  return arr[Math.floor(Math.random() * arr.length)];
}

function randomStyleFor(word) {
  word.classList.remove(...ALL_CLASSES);

  const styles = [pick(caseClasses), pick(fontClasses)];

  // A random subset of accents (0–2), cursive looks best left plain.
  if (!word.classList.contains("font-cursive")) {
    const accents = [...accentClasses].sort(() => Math.random() - 0.5);
    const count = Math.floor(Math.random() * 3); // 0, 1, or 2
    for (let i = 0; i < count; i++) styles.push(accents[i]);
  }

  word.classList.add(...styles);
}

function shuffleTitle() {
  words.forEach((w) => {
    w.style.opacity = "0.55";
    setTimeout(() => {
      randomStyleFor(w);
      w.style.opacity = "1";
    }, 90);
  });
}

shuffleTitle();
if (!reduceMotion) setInterval(shuffleTitle, 2000);

/* ── 3. Confetti (mirrors the app's celebration burst) ──────────────────── */
const canvas = document.getElementById("confetti");
const ctx = canvas.getContext("2d");
let particles = [];
let rafId = null;
let lastFrame = 0;

const CONFETTI_COLORS = ["#ffd166", "#06d6a0", "#118ab2", "#ef476f", "#ffffff", "#ffa400", "#ff5d8f"];
const GRAVITY = 900; // px/s², a bit stronger than native for a snappier web burst

function sizeCanvas() {
  const dpr = window.devicePixelRatio || 1;
  canvas.width = canvas.clientWidth * dpr;
  canvas.height = canvas.clientHeight * dpr;
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
}
window.addEventListener("resize", sizeCanvas);

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

document.getElementById("download").addEventListener("click", () => burstConfetti());
