import express, { type Express, type NextFunction, type Request, type Response } from "express";
import { z } from "zod";
import { requireSchedulerOidc, requireSession, signSession, verifyGoogleIdToken } from "./auth.js";
import type { CatalogService } from "./catalog.js";
import type { CelebrationAggregator } from "./celebrations.js";
import { env } from "./env.js";
import type { Poller } from "./poller.js";
import { CACHE_CONTROL_LIVE, type R2 } from "./r2.js";
import { FixedWindowRateLimiter } from "./rateLimit.js";
import type { Store } from "./store.js";
import type { Dispatcher } from "./tasks.js";
import type { MatchState, Period } from "./types.js";
import { log } from "./log.js";

const celebrateSchema = z.object({
  fixtureId: z.number().int().positive(),
  teamId: z.string().min(1).max(12), // numeric team id, as a string
  // One batched request per goal; >200 taps in a 5s window is not a human.
  taps: z.number().int().min(1).max(200),
});

// Writes a synthetic matches/{id}.json so the live overlay path can be exercised
// end-to-end without any push. The fields mirror what the poller would produce.
const testEventSchema = z.object({
  fixtureId: z.number().int().default(999999),
  leagueId: z.number().int().default(1),
  rawStatus: z.string().default("2H"),
  minute: z.number().int().nullable().default(73),
  extra: z.number().int().nullable().default(null),
  homeTeamId: z.number().int().default(6), // Brazil
  awayTeamId: z.number().int().default(16), // Mexico
  homeName: z.string().default("Brazil"),
  awayName: z.string().default("Mexico"),
  homeGoals: z.number().int().default(1),
  awayGoals: z.number().int().default(0),
});

export interface Deps {
  store: Store;
  poller: Poller;
  dispatcher: Dispatcher;
  catalog: CatalogService;
  celebrations: CelebrationAggregator;
  r2: R2;
}

function clientIp(req: Request): string {
  const forwarded = req.headers["x-forwarded-for"];
  const values = (Array.isArray(forwarded) ? forwarded : forwarded?.split(",")) ?? [];
  // Google frontends append client IP followed by load balancer IP.
  const value = values.length >= 2 ? values.at(-2) : values.at(-1);
  return value?.trim() || req.socket.remoteAddress || "unknown";
}

function enforceRateLimit(limiter: FixedWindowRateLimiter, key: (req: Request) => string) {
  return (req: Request, res: Response, next: NextFunction): void => {
    if (limiter.allow(key(req))) {
      next();
      return;
    }
    res.status(429).json({ error: "rate limit exceeded" });
  };
}

// Minimal raw-status → (status, period, running) mapping for the synthetic test
// match. Mirrors the provider's derivation for the codes a test would use.
function syntheticPhase(rawStatus: string, minute: number | null): {
  status: MatchState["status"]; period: Period; running: boolean;
} {
  switch (rawStatus) {
    case "1H": return { status: "LIVE", period: "FIRST", running: true };
    case "HT": return { status: "HALF_TIME", period: "HALF", running: false };
    case "2H": return { status: "LIVE", period: "SECOND", running: true };
    case "ET": return {
      status: "LIVE", period: (minute ?? 0) <= 105 ? "EXTRA_FIRST" : "EXTRA_SECOND", running: true,
    };
    case "BT": return { status: "LIVE", period: "EXTRA_BREAK", running: false };
    case "P": return { status: "LIVE", period: "PENALTIES", running: false };
    case "FT": case "AET": case "PEN": return { status: "FINISHED", period: "FINISHED", running: false };
    case "NS": case "TBD": return { status: "SCHEDULED", period: "PRE", running: false };
    default: return { status: "OTHER", period: "OTHER", running: false };
  }
}

/** Cache statuses that prove the edge — not R2 — served the request (§0). */
const HEALTHY_CACHE_STATUS = new Set(["HIT", "REVALIDATED", "STALE", "UPDATING"]);

export interface CacheProbe {
  key: string;
  httpStatus: number;
  cacheStatus: string;
  error?: string;
}

export interface CacheHealthResult {
  ok: boolean;
  probes: CacheProbe[];
  unhealthy: CacheProbe[];
}

/**
 * GETs a warm file (`catalog.json`) + each live `matches/{id}.json` on the
 * scores hostname and reads `cf-cache-status`. Steady-state must be served by
 * the edge (HIT/REVALIDATED/STALE/UPDATING); sustained MISS/BYPASS/DYNAMIC means
 * users would reach R2 directly — the §0 catastrophe. Pure (takes `fetchImpl`)
 * so it's unit-testable without the OIDC-guarded route.
 */
export async function probeCacheHealth(
  scoresDomain: string,
  fixtureIds: number[],
  fetchImpl: typeof fetch = fetch,
): Promise<CacheHealthResult> {
  const base = scoresDomain.replace(/\/+$/, "");
  const keys = ["catalog.json", ...fixtureIds.map((id) => `matches/${id}.json`)];
  const probes = await Promise.all(keys.map(async (key): Promise<CacheProbe> => {
    const url = `${base}/${key}`;
    try {
      const r = await fetchImpl(url, { method: "GET", cache: "no-store" as RequestCache });
      const cacheStatus = (r.headers.get("cf-cache-status") ?? "UNKNOWN").toUpperCase();
      await r.arrayBuffer().catch(() => undefined); // drain so the socket is reusable
      return { key, httpStatus: r.status, cacheStatus };
    } catch (err) {
      return { key, httpStatus: 0, cacheStatus: "ERROR", error: (err as Error).message };
    }
  }));
  const unhealthy = probes.filter((p) => !HEALTHY_CACHE_STATUS.has(p.cacheStatus));
  return { ok: unhealthy.length === 0, probes, unhealthy };
}

export function buildApp({ store, poller, dispatcher, catalog, celebrations, r2 }: Deps): Express {
  const app = express();
  const signInRateLimiter = new FixedWindowRateLimiter(10, 60_000);
  const sessionRateLimiter = new FixedWindowRateLimiter(120, 60_000);
  const celebrationRateLimiter = new FixedWindowRateLimiter(60, 60_000);
  app.use(express.json({ limit: "16kb" }));

  // Cloud Run reserves the exact /healthz path; the trailing slash reaches the app.
  app.get("/healthz/", (_req, res) => res.json({ ok: true }));

  app.post("/auth/signin", enforceRateLimit(signInRateLimiter, clientIp), async (req, res) => {
    try {
      const idToken = z.object({ idToken: z.string().min(10) }).parse(req.body).idToken;
      const user = await verifyGoogleIdToken(idToken);
      await store.upsertUser(user.sub, {
        name: user.name,
        email: user.email,
        photoURL: user.photoURL,
      });
      res.json({ token: await signSession(user), profile: user });
    } catch (err) {
      res.status(401).json({ error: `sign-in failed: ${(err as Error).message}` });
    }
  });

  const requireRateLimitedSession = [
    requireSession,
    enforceRateLimit(sessionRateLimiter, (req) => req.user!.sub),
  ];

  app.post("/celebrate", requireRateLimitedSession, (req: Request, res: Response) => {
    if (!celebrationRateLimiter.allow(req.user!.sub)) {
      res.status(429).json({ error: "celebration rate limit exceeded" });
      return;
    }
    const parsed = celebrateSchema.safeParse(req.body);
    if (!parsed.success) return void res.status(400).json({ error: parsed.error.message });
    const { fixtureId, teamId, taps } = parsed.data;
    celebrations.add(fixtureId, teamId, taps); // in-memory; flushed on interval
    res.json({ ok: true });
  });

  app.delete("/me", requireRateLimitedSession, async (req: Request, res: Response) => {
    await store.deleteUser(req.user!.sub);
    res.json({ ok: true });
  });

  // ── Internal (Cloud Scheduler / operators with the scheduler SA) ─────────

  // Once a minute (Cloud Scheduler): fan the minute out into staggered Cloud
  // Tasks so the cadence is sub-minute without any request sleeping.
  app.post("/internal/dispatch", requireSchedulerOidc, async (_req, res) => {
    try {
      const result = await dispatcher.dispatch();
      res.json(result);
    } catch (err) {
      log.error("dispatch_failed", err);
      res.status(500).json({ error: (err as Error).message });
    }
  });

  // Single fetch per request (Cloud Tasks worker). Returns immediately so the
  // CPU is billed only for the actual read, not for sleeping between polls.
  app.post("/internal/fetch", requireSchedulerOidc, async (_req, res) => {
    try {
      const result = await poller.fetchOnce();
      res.json(result);
    } catch (err) {
      log.error("fetch_failed", err);
      res.status(500).json({ error: (err as Error).message });
    }
  });

  // Daily: refresh leagues + teams (with logos) from the API → catalog.json.
  app.post("/internal/sync-catalog", requireSchedulerOidc, async (_req, res) => {
    try {
      const result = await catalog.sync();
      res.json(result);
    } catch (err) {
      log.error("sync_catalog_failed", err);
      res.status(500).json({ error: (err as Error).message });
    }
  });

  // E2E without push: write a synthetic matches/{id}.json so a polling client
  // picks it up and the existing overlay/diff path fires off the file change.
  app.post("/internal/test-event", requireSchedulerOidc, async (req, res) => {
    const parsed = testEventSchema.safeParse(req.body ?? {});
    if (!parsed.success) return void res.status(400).json({ error: parsed.error.message });
    const d = parsed.data;
    const phase = syntheticPhase(d.rawStatus, d.minute);
    const now = new Date().toISOString();
    const state: MatchState = {
      fixtureId: d.fixtureId,
      leagueId: d.leagueId,
      season: env.season,
      kickoffISO: now,
      secondHalfStartISO: null,
      status: phase.status,
      rawStatus: d.rawStatus,
      minute: d.minute,
      extra: d.extra,
      period: phase.period,
      running: phase.running,
      home: {
        id: d.homeTeamId, name: d.homeName, goals: d.homeGoals,
        yellowCards: 0, redCards: 0, yellowCardEvents: [], redCardEvents: [], goalEvents: [],
      },
      away: {
        id: d.awayTeamId, name: d.awayName, goals: d.awayGoals,
        yellowCards: 0, redCards: 0, yellowCardEvents: [], redCardEvents: [], goalEvents: [],
      },
    };
    await r2.putJson(`matches/${d.fixtureId}.json`, state, CACHE_CONTROL_LIVE);
    log.info("test_event_complete", { fixtureId: d.fixtureId, rawStatus: d.rawStatus });
    res.json({ ok: true, fixtureId: d.fixtureId });
  });

  // §0 enforcement probe (Cloud Scheduler every 5 min): GET a warm file +
  // each live matches/{id}.json on the scores hostname and read `cf-cache-status`.
  // Steady-state must be HIT/REVALIDATED (a lone MISS at a 5s boundary is fine);
  // sustained MISS/BYPASS/DYNAMIC means the cache is broken → users would hit R2.
  app.post("/internal/cache-health", requireSchedulerOidc, async (req, res) => {
    const body = z.object({ fixtureIds: z.array(z.number().int()).max(64).default([]) })
      .safeParse(req.body ?? {});
    if (!body.success) return void res.status(400).json({ error: body.error.message });

    const result = await probeCacheHealth(env.scoresDomain, body.data.fixtureIds);
    // R2 Class B (read) ops baseline check: no per-request metric is available
    // from this process (it needs CF/R2 analytics), so the dedicated Class B
    // alarm lives in infra. TODO(infra): wire the R2 Class B ops alarm (§0).
    if (!result.ok) {
      log.error("cache_health_degraded", new Error("non-cache reads detected"), { ...result });
      return void res.status(503).json(result);
    }
    log.info("cache_health_ok", { probed: result.probes.length });
    res.json(result);
  });

  return app;
}
