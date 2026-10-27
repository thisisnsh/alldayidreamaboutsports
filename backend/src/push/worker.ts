import { CloudTasksClient } from "@google-cloud/tasks";
import type { Config } from "./config.js";
import type { CDN } from "./cdn.js";
import type { Store } from "./store.js";
import { classify, type Sender } from "./apns.js";

export class Worker {
  constructor(private config: Config, private cdn: CDN, private store: Store, private sender: Sender,
    private tasks = new CloudTasksClient()) {}

  async dispatch(now = Date.now()) {
    const matches = await this.cdn.window(now);
    const ids: number[] = [];
    for (const match of matches) if (await this.store.hasSubscribers(match, now)) ids.push(match.fixtureId);
    if (!ids.length && !await this.store.hasWork()) return { enqueued: 0 };
    const parent = this.tasks.queuePath(this.config.GCP_PROJECT_ID, this.config.TASKS_LOCATION, this.config.TASKS_QUEUE);
    const minute = Math.floor(now / 60_000);
    const count = 60 / this.config.POLL_SECONDS;
    await Promise.all(Array.from({ length: count }, async (_, i) => {
      const scheduledAt = minute * 60_000 + i * this.config.POLL_SECONDS * 1000;
      try {
        await this.tasks.createTask({ parent, task: {
          name: `${parent}/tasks/tick-${minute}-${i}`, scheduleTime: { seconds: Math.floor(scheduledAt / 1000) },
          dispatchDeadline: { seconds: 120 },
          httpRequest: { httpMethod: "POST", url: `${this.config.SERVICE_URL}/internal/tick`,
            headers: { "Content-Type": "application/json" }, body: Buffer.from(JSON.stringify({ ids, scheduledAt })).toString("base64"),
            oidcToken: { serviceAccountEmail: this.config.INVOKER_EMAIL, audience: this.config.SERVICE_URL } },
        } });
      } catch (e) { if ((e as { code?: number }).code !== 6) throw e; }
    }));
    return { enqueued: count, matches: ids.length };
  }
  async tick(ids: number[], scheduledAt: number, now = Date.now()) {
    // Don't replay old queued polls after downtime. Durable pending deliveries have their own deadlines.
    if (now - scheduledAt > 60_000 || scheduledAt - now > 10_000) return { skipped: "old-task" };
    const owner = await this.store.lease(now); if (!owner) return { skipped: "overlap" };
    const deadline = Date.now() + 80_000;
    let sent = 0;
    try {
      for (let i = 0; i < ids.length && Date.now() < deadline - 20_000; i += 4) {
        await Promise.all(ids.slice(i, i + 4).map(async id => {
          try {
            const match = await this.cdn.match(id);
            if (match && Date.now() < deadline - 20_000) await this.store.observe(match, Date.now(), owner);
          } catch { console.error(JSON.stringify({ event: "cdn_poll_failed", fixtureId: id })); }
        }));
      }
      // Alternate fanout and sending so a popular match doesn't starve delivery behind a large job.
      for (let round = 0; round < 20 && Date.now() < deadline - 10_000; round++) {
        let work = false;
        for (let p = 0; p < 10 && Date.now() < deadline - 10_000; p++) {
          if (!await this.store.fanoutPage(owner)) break;
          work = true;
        }
        const pending = await this.store.pending(Date.now(), 50);
        if (!work && !pending.length) break;
        for (let p = 0; p < pending.length && Date.now() < deadline - 10_000; p += 10) {
          await Promise.all(pending.slice(p, p + 10).map(async delivery => {
            if (delivery.expiresAt <= Date.now() || !await this.store.stillSubscribed(delivery, Date.now())) {
              await this.store.complete(delivery, "done", "expired-or-unsubscribed"); return;
            }
            const result = await this.sender.send(delivery);
            const disposition = classify(result);
            if (disposition === "ok") {
              await this.store.complete(delivery, "done"); sent++;
            } else if (disposition === "invalid-token") {
              await this.store.removeToken(delivery); await this.store.complete(delivery, "done", "invalid-token");
            } else if (disposition === "retry") {
              await this.store.retry(delivery, Math.min(60, Math.max(result.retryAfter ?? 0, 2 ** Math.min(delivery.attempts + 1, 6))));
            } else {
              await this.store.complete(delivery, "failed", result.reason ?? String(result.status));
              // No tokens, JWTs, payloads, or private keys in logs.
              console.error(JSON.stringify({ event: "apns_rejected", status: result.status, reason: result.reason, kind: delivery.kind }));
            }
          }));
        }
      }
      return { sent, dryRun: this.config.DRY_RUN === "true" };
    } finally { await this.store.release(owner); }
  }
}
