import { randomUUID } from "node:crypto";
import { Timestamp, type Firestore } from "firebase-admin/firestore";
import { plan } from "./planner.js";
import { isTerminal, topicsFor, topicsForMatch, type Delivery, type Installation, type Match, type MatchRecord, type Registration } from "./model.js";

interface Transition { previous: MatchRecord | null; match: Match; at: number; cursor: string | null }
type Pending = Delivery & { status: "pending" | "done" | "failed"; deleteAfter: Timestamp };
export class Store {
  constructor(readonly db: Firestore) {}
  async registrationBudget(proofHash: string, now: number) {
    const ref = this.db.collection("registrationBudgets").doc(proofHash);
    await this.db.runTransaction(async tx => {
      const old = await tx.get(ref);
      const bucket = Math.floor(now / 60_000);
      const count = old.get("bucket") === bucket ? Number(old.get("count")) : 0;
      if (count >= 30) throw new Error("registration-rate-limit");
      tx.set(ref, { bucket, count: count + 1, deleteAfter: Timestamp.fromMillis(now + 86_400_000) });
    });
  }
  async register(id: string, r: Registration, now: number): Promise<void> {
    const ref = this.db.collection("installations").doc(id);
    await this.db.runTransaction(async tx => {
      const existing = await tx.get(ref);
      const old = existing.data() as Installation | undefined;
      // Idempotent sync/heartbeats do not reset the event subscription start time.
      const changed = !old || JSON.stringify({ ...r, teamIds: [...r.teamIds].sort(), eventTypes: [...r.eventTypes].sort() })
        !== JSON.stringify({ deviceToken: old.deviceToken, teamIds: [...old.teamIds].sort(), eventTypes: [...old.eventTypes].sort(), alertsEnabled: old.alertsEnabled, activities: old.activities });
      if (old && now - (existing.get("lastRegistrationAt") as number) < 2000) throw new Error("registration-rate-limit");
      const alertKey = (value: Registration) => JSON.stringify({ deviceToken: value.deviceToken,
        alertsEnabled: value.alertsEnabled, teamIds: [...value.teamIds].sort(), eventTypes: [...value.eventTypes].sort() });
      const alertsSince = !old || alertKey(r) !== alertKey(old) ? now : (old.alertsSince ?? old.updatedAt);
      if (topicsFor(r).length === 0) { tx.delete(ref); return; }
      tx.set(ref, { ...r, id, topics: topicsFor(r), updatedAt: changed ? now : old!.updatedAt, alertsSince,
        lastRegistrationAt: now, expiresAt: now + 30 * 86_400_000, deleteAfter: Timestamp.fromMillis(now + 30 * 86_400_000) });
    });
  }
  async hasSubscribers(m: Match, now: number) {
    const seen = await this.db.collection("matches").doc(String(m.fixtureId)).get();
    if (seen.get("snapshot.status") === "FINISHED") return false;
    const rows = await this.db.collection("installations").where("topics", "array-contains-any", topicsForMatch(m))
      .where("expiresAt", ">", now).limit(1).get();
    return !rows.empty;
  }
  async hasWork() {
    const [jobs, deliveries] = await Promise.all([
      this.db.collection("transitions").limit(1).get(),
      this.db.collection("deliveries").where("status", "==", "pending").limit(1).get(),
    ]);
    return !jobs.empty || !deliveries.empty;
  }
  async lease(now: number): Promise<string | null> {
    const ref = this.db.collection("control").doc("tick"); const owner = randomUUID();
    return this.db.runTransaction(async tx => {
      const old = await tx.get(ref);
      if (old.exists && Number(old.get("until")) > now) return null;
      tx.set(ref, { owner, until: now + 110_000 }); return owner;
    });
  }
  async release(owner: string) {
    const ref = this.db.collection("control").doc("tick");
    await this.db.runTransaction(async tx => { const old = await tx.get(ref); if (old.get("owner") === owner) tx.delete(ref); });
  }
  /** Atomic state + fanout job: no event disappears between observation and delivery. */
  async observe(raw: Match, now: number, owner?: string) {
    const ref = this.db.collection("matches").doc(String(raw.fixtureId));
    await this.db.runTransaction(async tx => {
      if (owner) {
        const lease = await tx.get(this.db.collection("control").doc("tick"));
        if (lease.get("owner") !== owner || Number(lease.get("until")) <= Date.now()) return;
      }
      const doc = await tx.get(ref); const previous = doc.data() as MatchRecord | undefined;
      const result = plan(previous, raw, [], now); if (!result) return;
      const changed = !previous || JSON.stringify(previous.snapshot) !== JSON.stringify(result.record.snapshot);
      if (changed || result.record.heartbeatAt !== previous?.heartbeatAt) {
        tx.create(this.db.collection("transitions").doc(`${raw.fixtureId}-${result.record.revision}`), {
          previous: previous ?? null, match: raw, at: now, cursor: null,
          deleteAfter: Timestamp.fromMillis(now + 86_400_000),
        });
      }
      tx.set(ref, { ...result.record, deleteAfter: Timestamp.fromMillis(now + 2 * 86_400_000) });
    });
  }
  /** A bounded page and its cursor commit together. Retrying never fans out the same page twice. */
  async fanoutPage(owner?: string): Promise<boolean> {
    const jobs = await this.db.collection("transitions").orderBy("at").limit(1).get();
    const job = jobs.docs[0]; if (!job) return false;
    const data = job.data() as Transition;
    // Preserve final ActivityKit endings through a temporary outage. Any ordinary
    // alerts in this job still carry their original two-minute delivery deadline.
    if (Date.now() - data.at > (isTerminal(data.match) ? 3_600_000 : 120_000)) { await job.ref.delete(); return true; }
    let query = this.db.collection("installations").where("topics", "array-contains-any", topicsForMatch(data.match)).orderBy("__name__");
    if (data.cursor) query = query.startAfter(data.cursor);
    const page = await query.limit(5).get();
    const result = plan(data.previous ?? undefined, data.match, page.docs.map(d => d.data() as Installation), data.at);
    await this.db.runTransaction(async tx => {
      if (owner) {
        const lease = await tx.get(this.db.collection("control").doc("tick"));
        if (lease.get("owner") !== owner || Number(lease.get("until")) <= Date.now()) return;
      }
      const current = await tx.get(job.ref);
      if (!current.exists || current.get("cursor") !== data.cursor) return;
      for (const delivery of result?.deliveries ?? []) {
        tx.set(this.db.collection("deliveries").doc(delivery.id), {
          ...delivery, status: "pending", deleteAfter: Timestamp.fromMillis(delivery.expiresAt + 86_400_000),
        });
      }
      if (page.size < 5) tx.delete(job.ref);
      else tx.update(job.ref, { cursor: page.docs.at(-1)!.id });
    });
    return true;
  }
  async pending(now: number, count = 100): Promise<Delivery[]> {
    const rows = await this.db.collection("deliveries").where("status", "==", "pending")
      .where("nextAttempt", "<=", now).orderBy("nextAttempt").limit(count).get();
    return rows.docs.map(doc => doc.data() as Pending);
  }
  async stillSubscribed(d: Delivery, now: number): Promise<boolean> {
    const snapshot = await this.db.collection("installations").doc(d.installationId).get();
    const sub = snapshot.data() as Installation | undefined;
    if (!sub || sub.expiresAt <= now) return false;
    if (d.kind === "liveactivity") return sub.activities.some(a => a.token === d.token && a.fixtureId === d.fixtureId);
    if (!sub.alertsEnabled || sub.deviceToken !== d.token || !sub.eventTypes.some(type => type === d.payload.eventType)) return false;
    const match = await this.db.collection("matches").doc(String(d.fixtureId)).get();
    return match.exists && this.follows(sub, match.get("snapshot") as Match);
  }
  private follows(s: Installation, m: Match) { return s.teamIds.includes(m.home.id) || s.teamIds.includes(m.away.id); }
  async complete(d: Delivery, status: "done" | "failed", reason?: string) {
    await this.updateIfCurrent(d, { status, ...(reason ? { reason } : {}) });
  }
  async retry(d: Delivery, seconds: number) {
    await this.updateIfCurrent(d, { attempts: d.attempts + 1, nextAttempt: Date.now() + seconds * 1000 });
  }
  private async updateIfCurrent(d: Delivery, fields: Record<string, unknown>) {
    const ref = this.db.collection("deliveries").doc(d.id);
    await this.db.runTransaction(async tx => {
      const current = await tx.get(ref);
      // A later score can replace an in-flight Live Activity update; never acknowledge that newer version.
      if (current.get("version") === d.version) tx.update(ref, fields);
    });
  }
  async removeToken(d: Delivery) {
    const ref = this.db.collection("installations").doc(d.installationId);
    await this.db.runTransaction(async tx => {
      const old = await tx.get(ref); if (!old.exists) return;
      const sub = old.data() as Installation;
      if (d.kind === "alert" && sub.deviceToken === d.token) sub.deviceToken = null;
      if (d.kind === "liveactivity") sub.activities = sub.activities.filter(a => a.token !== d.token);
      tx.update(ref, { deviceToken: sub.deviceToken, activities: sub.activities, topics: topicsFor(sub) });
    });
  }
}
