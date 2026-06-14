import express, { type Express } from "express";
import { z } from "zod";
import { requireSchedulerOidc, requireSession, signSession, verifyGoogleIdToken } from "./auth.js";
import type { CatalogService } from "./catalog.js";
import type { CelebrationAggregator } from "./celebrations.js";
import type { Fcm } from "./fcm.js";
import type { Poller } from "./poller.js";
import { FixedWindowRateLimiter } from "./rateLimit.js";
import type { Store } from "./store.js";
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
    "FULL_TIME",
    "PENALTY_SHOOTOUT",
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
  catalog: CatalogService;
  celebrations: CelebrationAggregator;
}

export function buildApp({ store, fcm, poller, catalog, celebrations }: Deps): Express {
  const app = express();
  const celebrationRateLimiter = new FixedWindowRateLimiter(60, 60_000);
  app.use(express.json({ limit: "16kb" }));

  app.get("/healthz", (_req, res) => res.json({ ok: true }));

  app.post("/auth/signin", async (req, res) => {
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

  app.get("/me/prefs", requireSession, async (req, res) => {
    const prefs = await store.getPrefs(req.user!.sub);
    if (!prefs) return void res.status(404).json({ error: "no such user" });
    res.json({ prefs });
  });

  app.put("/me/prefs", requireSession, async (req, res) => {
    const parsed = prefsSchema.safeParse(req.body);
    if (!parsed.success) return void res.status(400).json({ error: parsed.error.message });
    await store.putPrefs(req.user!.sub, parsed.data as UserPrefs);
    res.json({ ok: true });
  });

  app.post("/celebrate", requireSession, (req, res) => {
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

  app.delete("/me", requireSession, async (req, res) => {
    await store.deleteUser(req.user!.sub);
    res.json({ ok: true });
  });

  // ── Internal (Cloud Scheduler / operators with the scheduler SA) ─────────

  app.post("/internal/poll", requireSchedulerOidc, async (_req, res) => {
    try {
      const result = await poller.tick();
      res.json(result);
    } catch (err) {
      console.error("poll failed", err);
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
