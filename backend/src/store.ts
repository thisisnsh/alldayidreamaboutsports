import { App, applicationDefault, getApps, initializeApp } from "firebase-admin/app";
import { FieldValue, Firestore, getFirestore } from "firebase-admin/firestore";
import { diffMatch } from "./diff.js";
import type { MatchEvent, MatchState, UserPrefs } from "./types.js";
import { DEFAULT_PREFS } from "./types.js";

export function firebaseApp(): App {
  return getApps()[0] ?? initializeApp({ credential: applicationDefault() });
}

let firestore: Firestore | undefined;

function defaultFirestore(): Firestore {
  if (firestore) return firestore;
  // Provider match states intentionally omit optional fields such as lastGoal.
  // Firestore rejects undefined values unless they are ignored explicitly.
  firestore = getFirestore(firebaseApp());
  firestore.settings({ ignoreUndefinedProperties: true });
  return firestore;
}

const CELEBRATION_SHARDS = 16;

export class Store {
  private readonly db: Firestore;

  constructor(db?: Firestore) {
    this.db = db ?? defaultFirestore();
  }

  /**
   * Transactionally apply a fresh MatchState and return ONLY the events that
   * were not published before — the publish-once guarantee. Retries and
   * concurrent pollers recompute identical deterministic event ids and get [].
   */
  async applyMatchState(next: MatchState): Promise<MatchEvent[]> {
    const ref = this.db.collection("matches").doc(String(next.fixtureId));
    return this.db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      const prev = (snap.data()?.state as MatchState | undefined) ?? null;
      const published: string[] = snap.data()?.publishedEventIds ?? [];
      const events = diffMatch(prev, next).filter((e) => !published.includes(e.eventId));
      tx.set(ref, {
        state: next,
        publishedEventIds: FieldValue.arrayUnion(...[...events.map((e) => e.eventId), "_init"]),
        updatedAt: FieldValue.serverTimestamp(),
      }, { merge: true });
      return events;
    });
  }

  // ── Users ──────────────────────────────────────────────────────────────

  private userRef(sub: string) {
    return this.db.collection("users").doc(sub);
  }

  async upsertUser(
    sub: string,
    profile: { name: string | null; email: string | null; photoURL: string | null },
  ): Promise<UserPrefs> {
    const ref = this.userRef(sub);
    const snap = await ref.get();
    await ref.set(
      {
        ...profile,
        ...(snap.exists ? {} : { prefs: DEFAULT_PREFS, createdAt: FieldValue.serverTimestamp() }),
        updatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true },
    );
    return (snap.data()?.prefs as UserPrefs | undefined) ?? DEFAULT_PREFS;
  }

  async getPrefs(sub: string): Promise<UserPrefs | null> {
    const snap = await this.userRef(sub).get();
    if (!snap.exists) return null;
    return (snap.data()?.prefs as UserPrefs | undefined) ?? DEFAULT_PREFS;
  }

  async putPrefs(sub: string, prefs: UserPrefs): Promise<void> {
    await this.userRef(sub).set(
      { prefs, updatedAt: FieldValue.serverTimestamp() },
      { merge: true },
    );
  }

  async deleteUser(sub: string): Promise<void> {
    await this.userRef(sub).delete();
  }

  // ── Celebrations (sharded counters, cumulative per team per match) ──────

  async addCelebrations(fixtureId: number, counts: Record<string, number>): Promise<void> {
    const shard = Math.floor(Math.random() * CELEBRATION_SHARDS);
    const ref = this.db
      .collection("celebrations")
      .doc(String(fixtureId))
      .collection("shards")
      .doc(String(shard));
    const increments: Record<string, FieldValue> = {};
    for (const [team, n] of Object.entries(counts)) {
      increments[team] = FieldValue.increment(n);
    }
    await ref.set(increments, { merge: true });
    await this.db
      .collection("celebrations")
      .doc(String(fixtureId))
      .set({ updatedAt: FieldValue.serverTimestamp() }, { merge: true });
  }

  async celebrationTotals(fixtureId: number): Promise<Record<string, number>> {
    const shards = await this.db
      .collection("celebrations")
      .doc(String(fixtureId))
      .collection("shards")
      .get();
    const totals: Record<string, number> = {};
    for (const doc of shards.docs) {
      for (const [team, n] of Object.entries(doc.data())) {
        if (typeof n === "number") totals[team] = (totals[team] ?? 0) + n;
      }
    }
    return totals;
  }
}
