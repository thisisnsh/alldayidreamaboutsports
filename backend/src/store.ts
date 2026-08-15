import { App, applicationDefault, getApps, initializeApp } from "firebase-admin/app";
import { FieldValue, Firestore, getFirestore } from "firebase-admin/firestore";

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

// Firestore's soft ceiling is ~1 sustained write/sec/document. At 1M concurrent
// users, 16 shards put ~1.25 writes/sec on each; 64 keeps every shard well under.
const CELEBRATION_SHARDS = 64;

export class Store {
  private readonly db: Firestore;

  constructor(db?: Firestore) {
    this.db = db ?? defaultFirestore();
  }

  // ── Users ──────────────────────────────────────────────────────────────

  private userRef(sub: string) {
    return this.db.collection("users").doc(sub);
  }

  async upsertUser(
    sub: string,
    profile: { name: string | null; email: string | null; photoURL: string | null },
  ): Promise<void> {
    const ref = this.userRef(sub);
    const snap = await ref.get();
    await ref.set(
      {
        ...profile,
        ...(snap.exists ? {} : { createdAt: FieldValue.serverTimestamp() }),
        updatedAt: FieldValue.serverTimestamp(),
      },
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
