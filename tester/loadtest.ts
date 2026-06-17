/**
 * Staging-only CDN load generator.
 *
 * Spawns N virtual clients that poll the public scores hostname exactly like the
 * real app (GET matches/{id}.json + celebrate/{id}.json every ~5s, plus today's
 * fixtures file + catalog.json). It records latency and `cf-cache-status` per
 * response and reports a §0 verdict: in steady state ~100% of responses must be
 * served by the edge (HIT/REVALIDATED/STALE/UPDATING). A high MISS/BYPASS/DYNAMIC
 * share means clients are reaching R2 directly — a broken cache rule.
 *
 * Read-only: GETs are public, so no credentials are used here. Run against the
 * STAGING scores domain only.
 *
 *   npm run loadtest -- --fixtures 900001,900002 --clients 200 --duration 60
 */
import { env } from "../backend/src/env.js";

/** Cache statuses that prove the edge — not R2 — served the request (§0). */
const HEALTHY_CACHE_STATUS = new Set(["HIT", "REVALIDATED", "STALE", "UPDATING"]);

interface Sample {
  key: string;
  httpStatus: number;
  latencyMs: number;
  cacheStatus: string;
  ok: boolean;
}

function parseArgs(argv: string[]): Map<string, string> {
  const args = new Map<string, string>();
  for (let i = 0; i < argv.length; i++) {
    const token = argv[i];
    if (!token?.startsWith("--")) continue;
    const name = token.slice(2);
    const next = argv[i + 1];
    if (next && !next.startsWith("--")) {
      args.set(name, next);
      i++;
    } else {
      args.set(name, "true");
    }
  }
  return args;
}

function normalizeBase(domain: string): string {
  return (/^https?:\/\//i.test(domain) ? domain : `https://${domain}`).replace(/\/+$/, "");
}

function percentile(sorted: number[], p: number): number {
  if (sorted.length === 0) return 0;
  const idx = Math.min(sorted.length - 1, Math.ceil((p / 100) * sorted.length) - 1);
  return sorted[Math.max(0, idx)] ?? 0;
}

async function probe(url: string, key: string): Promise<Sample> {
  const started = performance.now();
  try {
    const r = await fetch(url, { method: "GET" });
    const cacheStatus = (r.headers.get("cf-cache-status") ?? "UNKNOWN").toUpperCase();
    await r.arrayBuffer().catch(() => undefined); // drain so the socket is reusable
    return {
      key,
      httpStatus: r.status,
      latencyMs: performance.now() - started,
      cacheStatus,
      ok: r.ok,
    };
  } catch (err) {
    return {
      key,
      httpStatus: 0,
      latencyMs: performance.now() - started,
      cacheStatus: "ERROR",
      ok: false,
    };
  }
}

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));

  const base = normalizeBase(args.get("base") ?? env.scoresDomain);
  const fixtureIds = (args.get("fixtures") ?? "900001,900002,900003")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
  const clients = Number(args.get("clients") ?? 50);
  const durationSec = Number(args.get("duration") ?? 30);
  const intervalMs = Number(args.get("interval") ?? 5000);

  const today = new Date().toISOString().slice(0, 10);
  const keys = [
    "catalog.json",
    `fixtures-${today}.json`,
    ...fixtureIds.flatMap((id) => [`matches/${id}.json`, `celebrate/${id}.json`]),
  ];

  console.log(
    `Load test → ${base}\n` +
      `  keys/client: ${keys.length} (${keys.join(", ")})\n` +
      `  clients: ${clients}  duration: ${durationSec}s  interval: ${intervalMs}ms\n`,
  );

  const samples: Sample[] = [];
  const deadline = performance.now() + durationSec * 1000;

  const client = async (): Promise<void> => {
    while (performance.now() < deadline) {
      const round = await Promise.all(keys.map((key) => probe(`${base}/${key}`, key)));
      samples.push(...round);
      const elapsed = round.reduce((max, s) => Math.max(max, s.latencyMs), 0);
      await sleep(Math.max(0, intervalMs - elapsed));
    }
  };

  const startedAt = performance.now();
  await Promise.all(Array.from({ length: clients }, () => client()));
  const wallSec = (performance.now() - startedAt) / 1000;

  // ── Report ────────────────────────────────────────────────────────────────
  const latencies = samples.map((s) => s.latencyMs).sort((a, b) => a - b);
  const histogram = new Map<string, number>();
  let healthy = 0;
  let errors = 0;
  for (const s of samples) {
    histogram.set(s.cacheStatus, (histogram.get(s.cacheStatus) ?? 0) + 1);
    if (HEALTHY_CACHE_STATUS.has(s.cacheStatus)) healthy++;
    if (!s.ok) errors++;
  }
  const total = samples.length;
  const healthyShare = total > 0 ? (healthy / total) * 100 : 0;

  console.log("Summary");
  console.table({
    requests: total,
    rps: Number((total / wallSec).toFixed(1)),
    errors,
    "latency p50 (ms)": Number(percentile(latencies, 50).toFixed(1)),
    "latency p90 (ms)": Number(percentile(latencies, 90).toFixed(1)),
    "latency p99 (ms)": Number(percentile(latencies, 99).toFixed(1)),
    "latency max (ms)": Number((latencies.at(-1) ?? 0).toFixed(1)),
  });

  console.log("\ncf-cache-status histogram");
  console.table(
    Object.fromEntries(
      [...histogram.entries()]
        .sort((a, b) => b[1] - a[1])
        .map(([status, count]) => [
          status,
          { count, share: `${((count / total) * 100).toFixed(1)}%` },
        ]),
    ),
  );

  const verdict = healthyShare >= 99 ? "PASS" : healthyShare >= 90 ? "WARN" : "FAIL";
  console.log(
    `\n§0 verdict: ${verdict} — ${healthyShare.toFixed(1)}% of responses served by the edge ` +
      `(${healthy}/${total} HIT/REVALIDATED/STALE/UPDATING)`,
  );
  if (verdict === "FAIL") process.exitCode = 1;
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
