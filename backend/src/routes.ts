import express, { type Express, type RequestHandler, type ErrorRequestHandler } from "express";
import { z } from "zod";
import { requireHealthOidc, requireSchedulerOidc } from "./auth.js";
import type { CatalogService } from "./catalog.js";
import { env } from "./env.js";
import { syntheticPhase } from "./phase.js";
import type { Poller } from "./poller.js";
import { toScheduleRow } from "./poller.js";
import { CACHE_CONTROL_LIVE, CACHE_CONTROL_LONG, type R2 } from "./r2.js";
import type { ScheduleService } from "./schedule.js";
import type { Dispatcher, MatchWindow } from "./tasks.js";
import type { MatchState } from "./types.js";
import { log } from "./log.js";

// Writes a synthetic matches/{id}.json so the live overlay path can be exercised
// end-to-end without any push. The fields mirror what the poller would produce.
const testEventSchema = z.object({
  fixtureId: z.number().int().default(999999),
  leagueId: z.number().int().default(140), // La Liga
  season: z.number().int().default(2026),
  rawStatus: z.string().default("2H"),
  minute: z.number().int().nullable().default(73),
  extra: z.number().int().nullable().default(null),
  homeTeamId: z.number().int().default(541), // Real Madrid
  awayTeamId: z.number().int().default(529), // Barcelona
  homeName: z.string().default("Real Madrid"),
  awayName: z.string().default("Barcelona"),
  homeGoals: z.number().int().default(1),
  awayGoals: z.number().int().default(0),
});

export interface Deps {
  poller: Poller;
  dispatcher: Dispatcher;
  window: MatchWindow;
  catalog: CatalogService;
  schedule: ScheduleService;
  r2: R2;
}

/** Cache statuses that prove the edge — not R2 — served the request (§0). */
const HEALTHY_CACHE_STATUS = new Set(["HIT", "REVALIDATED", "STALE", "UPDATING"]);
const RETRYABLE_CACHE_STATUS = new Set(["MISS", "EXPIRED"]);

export interface CacheProbe {
  key: string;
  httpStatus: number;
  cacheStatus: string;
  attempts: string[];
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
  const base = (/^https?:\/\//i.test(scoresDomain) ? scoresDomain : `https://${scoresDomain}`)
    .replace(/\/+$/, "");
  const keys = ["catalog.json", ...fixtureIds.map((id) => `matches/${id}.json`)];
  const probes = await Promise.all(keys.map(async (key): Promise<CacheProbe> => {
    const url = `${base}/${key}`;
    try {
      const probe = async () => {
        const r = await fetchImpl(url, { method: "GET", signal: AbortSignal.timeout(10_000), redirect: "error" });
        const cacheStatus = (r.headers.get("cf-cache-status") ?? "UNKNOWN").toUpperCase();
        await r.body?.cancel(); // headers are sufficient; never buffer an unbounded probe body
        return { httpStatus: r.status, cacheStatus };
      };

      const first = await probe();
      if (RETRYABLE_CACHE_STATUS.has(first.cacheStatus)) {
        const second = await probe();
        return {
          key,
          httpStatus: second.httpStatus,
          cacheStatus: second.cacheStatus,
          attempts: [first.cacheStatus, second.cacheStatus],
        };
      }
      return { key, httpStatus: first.httpStatus, cacheStatus: first.cacheStatus, attempts: [first.cacheStatus] };
    } catch (err) {
      return { key, httpStatus: 0, cacheStatus: "ERROR", attempts: ["ERROR"], error: (err as Error).message };
    }
  }));
  // An edge-cached 404/5xx is still a failure: clients get no data from it.
  const unhealthy = probes.filter((p) => p.httpStatus !== 200 || !HEALTHY_CACHE_STATUS.has(p.cacheStatus));
  return { ok: unhealthy.length === 0, probes, unhealthy };
}

/** Express 4 does not forward rejected handler promises. */
const asyncRoute = (handler: RequestHandler): RequestHandler => (req, res, next) => {
  Promise.resolve().then(() => handler(req, res, next)).catch(next);
};

export function buildApp(
  { poller, dispatcher, window, catalog, schedule, r2 }: Deps,
): Express {
  const app = express();
  app.disable("x-powered-by");
  app.use(express.json({ limit: "16kb" }));

  app.get("/internal/healthz", requireHealthOidc, (_req, res) => res.json({ ok: true }));

  // ── Internal (Cloud Scheduler / operators with the scheduler SA) ─────────

  // Once a minute (Cloud Scheduler): fan the minute out into staggered Cloud
  // Tasks so the cadence is sub-minute without any request sleeping.
  app.post("/internal/dispatch", requireSchedulerOidc, asyncRoute(async (_req, res) => {
    try {
      const result = await dispatcher.dispatch();
      res.json(result);
    } catch (err) {
      log.error("dispatch_failed", err);
      res.status(500).json({ error: "internal server error" });
    }
  }));

  // Single fetch per request (Cloud Tasks worker). Returns immediately so the
  // CPU is billed only for the actual read, not for sleeping between polls.
  app.post("/internal/fetch", requireSchedulerOidc, asyncRoute(async (_req, res) => {
    try {
      const result = await poller.fetchOnce();
      res.json(result);
    } catch (err) {
      log.error("fetch_failed", err);
      res.status(500).json({ error: "internal server error" });
    }
  }));

  // Every 6h: refresh fixtures-{date}.json for today±1. Runs independently of
  // the live tick — the dispatcher gate reads these files to decide whether to
  // open a match window, so they cannot depend on the gated job to write them.
  app.post("/internal/sync-schedule", requireSchedulerOidc, asyncRoute(async (_req, res) => {
    try {
      const result = await schedule.sync();
      res.json(result);
    } catch (err) {
      log.error("sync_schedule_failed", err);
      res.status(500).json({ error: "internal server error" });
    }
  }));

  // Daily: refresh leagues + teams (with logos) from the API → catalog.json.
  app.post("/internal/sync-catalog", requireSchedulerOidc, asyncRoute(async (_req, res) => {
    try {
      const result = await catalog.sync();
      res.json(result);
    } catch (err) {
      log.error("sync_catalog_failed", err);
      res.status(500).json({ error: "internal server error" });
    }
  }));

  // E2E without push: write a synthetic matches/{id}.json so a polling client
  // picks it up and the existing overlay/diff path fires off the file change.
  app.post("/internal/test-event", requireSchedulerOidc, asyncRoute(async (req, res) => {
    // It writes schedule rows too, so it must never touch production data.
    if (!/staging/i.test(env.r2.scoresBucket)) {
      return void res.status(403).json({ error: "test-event is staging-only" });
    }
    const parsed = testEventSchema.safeParse(req.body ?? {});
    if (!parsed.success) return void res.status(400).json({ error: parsed.error.message });
    const d = parsed.data;
    const phase = syntheticPhase(d.rawStatus, d.minute);
    const now = new Date().toISOString();
    const state: MatchState = {
      fixtureId: d.fixtureId,
      leagueId: d.leagueId,
      season: d.season,
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
        yellowCards: 0, redCards: 0, yellowCardEvents: [], redCardEvents: [], goalEvents: [], subs: [],
      },
      away: {
        id: d.awayTeamId, name: d.awayName, goals: d.awayGoals,
        yellowCards: 0, redCards: 0, yellowCardEvents: [], redCardEvents: [], goalEvents: [], subs: [],
      },
      varEvents: [],
    };
    await r2.putJson(`matches/${d.fixtureId}.json`, state, CACHE_CONTROL_LIVE);
    // Clients discover which match files to poll from the schedule, so the
    // fixture needs a row in today's file too — otherwise only a client that
    // already tracks this id ever sees the event.
    const scheduleKey = `fixtures-${now.slice(0, 10)}.json`;
    const schedule = (await r2.getJson<{ matches: MatchState[] }>(scheduleKey)) ?? { matches: [] };
    const matches = schedule.matches.filter((m) => m.fixtureId !== d.fixtureId);
    matches.push(toScheduleRow(state));
    await r2.putJson(scheduleKey, { matches }, CACHE_CONTROL_LONG);
    log.info("test_event_complete", { fixtureId: d.fixtureId, rawStatus: d.rawStatus });
    res.json({ ok: true, fixtureId: d.fixtureId });
  }));

  // §0 enforcement probe (Cloud Scheduler every 5 min): GET a warm file +
  // each live matches/{id}.json on the scores hostname and read `cf-cache-status`.
  // Steady-state must be HIT/REVALIDATED (a lone MISS at a 5s boundary is fine);
  // sustained MISS/BYPASS/DYNAMIC means the cache is broken → users would hit R2.
  app.post("/internal/cache-health", requireSchedulerOidc, asyncRoute(async (req, res) => {
    const body = z.object({ fixtureIds: z.array(z.number().int()).max(64).default([]) })
      .safeParse(req.body ?? {});
    if (!body.success) return void res.status(400).json({ error: body.error.message });

    // Outside a match window the per-match files are stale by design and the
    // edge has no reason to hold them, so probing them would page us about a
    // Wednesday. The warm file (catalog.json) is still probed year-round —
    // a cache regression must be caught even when no football is on.
    const windowOpen = await window.isOpen();
    // The scheduler job sends no ids, so sample the in-play matches from the
    // schedule itself — the live files are what §0 is really about.
    const requested = body.data.fixtureIds.length > 0
      ? body.data.fixtureIds
      : windowOpen ? (await window.inPlayFixtureIds()).slice(0, 64) : [];
    const fixtureIds = windowOpen ? requested : [];
    if (!windowOpen && body.data.fixtureIds.length > 0) {
      log.info("cache_health_matches_skipped", { requested: body.data.fixtureIds.length });
    }

    const result = await probeCacheHealth(env.scoresDomain, fixtureIds);
    // R2 Class B (read) ops baseline check: no per-request metric is available
    // from this process (it needs CF/R2 analytics), so the dedicated Class B
    // alarm lives in infra. TODO(infra): wire the R2 Class B ops alarm (§0).
    if (!result.ok) {
      log.error("cache_health_degraded", new Error("non-cache reads detected"), { ...result, windowOpen });
      return void res.status(503).json({ ...result, windowOpen });
    }
    log.info("cache_health_ok", { probed: result.probes.length, windowOpen });
    res.json({ ...result, windowOpen });
  }));

  const handleError: ErrorRequestHandler = (error, req, res, next) => {
    if (res.headersSent) return next(error);
    const status = error?.type === "entity.too.large" ? 413
      : error?.type === "entity.parse.failed" ? 400 : 500;
    if (status === 500) log.error("request_failed", error, { path: req.path });
    res.status(status).json({ error: status === 500 ? "internal server error" : "invalid request body" });
  };
  app.use(handleError);
  return app;
}
