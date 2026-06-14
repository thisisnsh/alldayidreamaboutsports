import express, { type Express, type NextFunction, type Request, type Response } from "express";
import { z } from "zod";
import { requireSchedulerOidc, requireSession, signSession, verifyGoogleIdToken } from "./auth.js";
import type { CatalogService } from "./catalog.js";
import type { CelebrationAggregator } from "./celebrations.js";
import type { Fcm } from "./fcm.js";
import type { Poller } from "./poller.js";
import { FixedWindowRateLimiter } from "./rateLimit.js";
import type { Store } from "./store.js";
import type { Dispatcher } from "./tasks.js";
import type { MatchEvent, UserPrefs } from "./types.js";

const prefsSchema = z.object({
  fanOf: z.record(
    z.string().max(32), // game, e.g. "football"
    // leagueId -> team ids (as strings); ids can be a single digit, e.g. "6".
    z.record(z.string().max(16), z.array(z.string().min(1).max(12)).max(64)),
  ),
  settings: z
    .object({
      launchAtLogin: z.boolean().optional(),
      theme: z.enum(["system", "light", "dark"]).optional(),
      notifications: z.record(z.string().max(32), z.boolean()).optional(),
    })
    .passthrough(),
});

const celebrateSchema = z.object({
  fixtureId: z.number().int().positive(),
  teamId: z.string().min(1).max(12), // numeric team id, as a string
  // One batched request per goal; >200 taps in a 5s window is not a human.
  taps: z.number().int().min(1).max(200),
});

const testEventSchema = z.object({
  type: z.enum([
    "KICKOFF",
    "GOAL",
    "GOAL_CANCELLED",
    "YELLOW_CARD",
    "RED_CARD",
    "HALF_TIME",
    "EXTRA_TIME",
    "PENALTY_KICK",
    "PENALTY_SHOOTOUT",
    "FULL_TIME",
  ]),
  fixtureId: z.number().int().default(999999),
  leagueId: z.number().int().default(1),
  homeTeamId: z.number().int().default(6), // Brazil
  awayTeamId: z.number().int().default(16), // Mexico
  homeName: z.string().default("Brazil"),
  awayName: z.string().default("Mexico"),
  homeGoals: z.number().int().default(1),
  awayGoals: z.number().int().default(0),
  teamId: z.number().int().optional(),
  player: z.string().optional(),
  minute: z.number().int().optional(),
});

export interface Deps {
  store: Store;
  fcm: Fcm;
  poller: Poller;
  dispatcher: Dispatcher;
  catalog: CatalogService;
  celebrations: CelebrationAggregator;
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

export function buildApp({ store, fcm, poller, dispatcher, catalog, celebrations }: Deps): Express {
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
      const prefs = await store.upsertUser(user.sub, {
        name: user.name,
        email: user.email,
        photoURL: user.photoURL,
      });
      res.json({ token: await signSession(user), profile: user, prefs });
    } catch (err) {
      res.status(401).json({ error: `sign-in failed: ${(err as Error).message}` });
    }
  });

  const requireRateLimitedSession = [
    requireSession,
    enforceRateLimit(sessionRateLimiter, (req) => req.user!.sub),
  ];

  app.get("/me/prefs", requireRateLimitedSession, async (req: Request, res: Response) => {
    const prefs = await store.getPrefs(req.user!.sub);
    if (!prefs) return void res.status(404).json({ error: "no such user" });
    res.json({ prefs });
  });

  app.put("/me/prefs", requireRateLimitedSession, async (req: Request, res: Response) => {
    const parsed = prefsSchema.safeParse(req.body);
    if (!parsed.success) return void res.status(400).json({ error: parsed.error.message });
    await store.putPrefs(req.user!.sub, parsed.data as UserPrefs);
    res.json({ ok: true });
  });

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
      console.error("dispatch failed", err);
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
      console.error("fetch failed", err);
      res.status(500).json({ error: (err as Error).message });
    }
  });

  // Daily: refresh leagues + teams (with logos) from the API → catalog.json.
  app.post("/internal/sync-catalog", requireSchedulerOidc, async (_req, res) => {
    try {
      const result = await catalog.sync();
      res.json(result);
    } catch (err) {
      console.error("sync-catalog failed", err);
      res.status(500).json({ error: (err as Error).message });
    }
  });

  app.post("/internal/test-event", requireSchedulerOidc, async (req, res) => {
    const parsed = testEventSchema.safeParse(req.body ?? {});
    if (!parsed.success) return void res.status(400).json({ error: parsed.error.message });
    const d = parsed.data;
    const event: MatchEvent = {
      ...d,
      eventId: `test:${d.fixtureId}:${d.type}:${Date.now()}`,
      player: d.player ?? null,
      minute: d.minute ?? null,
    };
    await fcm.publishEvent(event);
    res.json({ ok: true, eventId: event.eventId });
  });

  return app;
}
