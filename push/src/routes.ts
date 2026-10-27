import express from "express";
import { z } from "zod";
import { registrationSchema, hash } from "./model.js";
import type { Config } from "./config.js";
import type { Store } from "./store.js";
import type { Worker } from "./worker.js";

export interface Dependencies {
  store: Pick<Store, "register" | "registrationBudget">;
  worker: Pick<Worker, "dispatch" | "tick">;
  verifyOidc(token: string): Promise<{ email?: string; email_verified?: boolean }>;
  verifyAppCheck(token: string): Promise<{ appId: string }>;
}
export function createApp(config: Config, deps: Dependencies) {
  const app = express();
  app.disable("x-powered-by");
  app.use(express.json({ limit: "32kb" }));
  app.get("/health", (_req, res) => res.json({ ok: true, dryRun: config.DRY_RUN === "true" }));
  app.use("/internal", async (req, res, next) => {
    try {
      const token = req.get("Authorization")?.match(/^Bearer (\S+)$/)?.[1];
      if (!token) { res.sendStatus(401); return; }
      const p = await deps.verifyOidc(token);
      if (p.email !== config.INVOKER_EMAIL || p.email_verified !== true) { res.sendStatus(403); return; }
      next();
    } catch { res.sendStatus(401); }
  });
  app.post("/internal/dispatch", async (_req, res) => { res.json(await deps.worker.dispatch()); });
  app.post("/internal/tick", async (req, res) => {
    const body = z.object({ ids: z.array(z.number().int().positive()).max(512), scheduledAt: z.number().int() }).parse(req.body);
    res.json(await deps.worker.tick(body.ids, body.scheduledAt));
  });
  app.put("/v1/installation", async (req, res) => {
    const proof = req.get("X-Firebase-AppCheck");
    const secret = req.get("Authorization")?.match(/^Bearer ([a-f0-9]{64})$/)?.[1];
    if (!proof || !secret) { res.sendStatus(401); return; }
    try {
      const claims = await deps.verifyAppCheck(proof);
      if (!config.FIREBASE_APP_IDS.split(",").includes(claims.appId)) { res.sendStatus(403); return; }
    } catch { res.sendStatus(401); return; }
    const registration = registrationSchema.parse(req.body);
    await deps.store.registrationBudget(hash(proof), Date.now());
    await deps.store.register(hash(secret), registration, Date.now());
    res.json({ registered: true, remoteDeliveryEnabled: config.DRY_RUN === "false" });
  });
  app.use((error: unknown, _req: express.Request, res: express.Response, _next: express.NextFunction) => {
    if (error instanceof z.ZodError || (error as { type?: string })?.type === "entity.parse.failed") {
      res.status(400).json({ error: "invalid request" }); return;
    }
    if ((error as { type?: string })?.type === "entity.too.large") { res.sendStatus(413); return; }
    if (error instanceof Error && error.message === "registration-rate-limit") { res.sendStatus(429); return; }
    console.error(JSON.stringify({ event: "request_failed" }));
    res.sendStatus(503);
  });
  return app;
}
