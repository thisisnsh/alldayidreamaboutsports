/**
 * Staging-only fake event publisher.
 *
 * Seeds fake matches in arbitrary states into the STAGING scores bucket and
 * mutates them (advance state, score goals, bump celebration tallies) by writing
 * directly to R2 via the S3 SDK — reusing the deployed `R2` class and cache
 * constants so every object carries the §0 Cache-Control. This exercises the full
 * live overlay / celebration UI end-to-end without API-Football or the Cloud
 * Scheduler/Tasks pipeline.
 *
 * Fake fixtures use a reserved id range (900001+) so they never collide with real
 * WC matches and are trivial to purge with `clear`.
 *
 *   npm run fake -- seed --count 3 --state LIVE
 *   npm run fake -- advance --fixture 900001 --status HT
 *   npm run fake -- goal --fixture 900001 --team home
 *   npm run fake -- celebrate --fixture 900001 --team 910001 --count 50
 *   npm run fake -- clear
 */
import {
  DeleteObjectCommand,
  ListObjectsV2Command,
  S3Client,
} from "@aws-sdk/client-s3";
import { env } from "../backend/src/env.js";
import { syntheticPhase } from "../backend/src/phase.js";
import { CACHE_CONTROL_LIVE, CACHE_CONTROL_LONG, R2 } from "../backend/src/r2.js";
import type { CardEvent, MatchState, TeamScore } from "../backend/src/types.js";

/** Fake fixtures live at/above this id so they never collide with real matches. */
const RESERVED_ID_MIN = 900001;
const isFakeId = (id: number) => id >= RESERVED_ID_MIN;

/** Friendly state name → API-Football raw short code + a sensible default minute. */
const STATE_TO_RAW: Record<string, { raw: string; minute: number | null }> = {
  SCHEDULED: { raw: "NS", minute: null },
  LIVE: { raw: "2H", minute: 60 },
  HT: { raw: "HT", minute: 45 },
  FINISHED: { raw: "FT", minute: null },
};

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

function today(): string {
  return new Date().toISOString().slice(0, 10);
}

function fixturesKey(date = today()): string {
  return `fixtures-${date}.json`;
}

function makeTeam(id: number, name: string): TeamScore {
  return {
    id,
    name,
    goals: 0,
    yellowCards: 0,
    redCards: 0,
    yellowCardEvents: [],
    redCardEvents: [],
    goalEvents: [],
  };
}

/** Refuses to run unless the target bucket is clearly a staging bucket. */
function assertStaging(): void {
  const bucket = env.r2.scoresBucket;
  if (!/staging/i.test(bucket)) {
    throw new Error(
      `Refusing to run: R2_BUCKET_SCORES="${bucket}" does not contain "staging". ` +
        `This tool only writes to staging buckets.`,
    );
  }
}

function rawS3(): S3Client {
  return new S3Client({
    region: "auto",
    endpoint: env.r2.endpoint,
    credentials: {
      accessKeyId: env.r2.accessKeyId,
      secretAccessKey: env.r2.secretAccessKey,
    },
  });
}

interface FixturesFile {
  matches: MatchState[];
}

/** Splice a fresh set of fake matches into today's fixtures file (long TTL). */
async function mergeFixtures(r2: R2, fakes: MatchState[]): Promise<void> {
  const key = fixturesKey();
  const current = (await r2.getJson<FixturesFile>(key)) ?? { matches: [] };
  const byId = new Map<number, MatchState>();
  for (const m of current.matches) if (!isFakeId(m.fixtureId)) byId.set(m.fixtureId, m);
  for (const m of fakes) byId.set(m.fixtureId, m);
  await r2.putJson(key, { matches: [...byId.values()] }, CACHE_CONTROL_LONG);
}

/** Replace one fake match inside today's fixtures file so its snapshot stays in sync. */
async function upsertFixture(r2: R2, match: MatchState): Promise<void> {
  const key = fixturesKey();
  const current = (await r2.getJson<FixturesFile>(key)) ?? { matches: [] };
  const matches = current.matches.filter((m) => m.fixtureId !== match.fixtureId);
  matches.push(match);
  await r2.putJson(key, { matches }, CACHE_CONTROL_LONG);
}

async function loadMatch(r2: R2, fixtureId: number): Promise<MatchState> {
  const state = await r2.getJson<MatchState>(`matches/${fixtureId}.json`);
  if (!state) throw new Error(`matches/${fixtureId}.json not found — seed it first`);
  return state;
}

// ── Subcommands ───────────────────────────────────────────────────────────────

async function seed(r2: R2, args: Map<string, string>): Promise<void> {
  const count = Number(args.get("count") ?? 3);
  const states = (args.get("state") ?? "LIVE")
    .split(",")
    .map((s) => s.trim().toUpperCase());
  for (const s of states) {
    if (!STATE_TO_RAW[s]) {
      throw new Error(`Unknown --state "${s}". Use ${Object.keys(STATE_TO_RAW).join("|")}.`);
    }
  }

  const now = new Date().toISOString();
  const fakes: MatchState[] = [];
  for (let i = 0; i < count; i++) {
    const fixtureId = RESERVED_ID_MIN + i;
    const stateName = states[i % states.length]!;
    const { raw, minute } = STATE_TO_RAW[stateName]!;
    const phase = syntheticPhase(raw, minute);
    const homeId = 910000 + i;
    const awayId = 920000 + i;
    const state: MatchState = {
      fixtureId,
      leagueId: env.leagueId,
      season: env.season,
      round: "Test - Group Z",
      kickoffISO: now,
      secondHalfStartISO: null,
      status: phase.status,
      rawStatus: raw,
      minute,
      extra: null,
      period: phase.period,
      running: phase.running,
      home: makeTeam(homeId, `Test Home ${i + 1}`),
      away: makeTeam(awayId, `Test Away ${i + 1}`),
    };
    fakes.push(state);
    await r2.putJson(`matches/${fixtureId}.json`, state, CACHE_CONTROL_LIVE);
    await r2.putJson(`celebrate/${fixtureId}.json`, { totals: {} }, CACHE_CONTROL_LIVE);
    console.log(`seeded matches/${fixtureId}.json (${stateName}) + celebrate/${fixtureId}.json`);
  }
  await mergeFixtures(r2, fakes);
  console.log(`merged ${fakes.length} fake match(es) into ${fixturesKey()}`);
}

async function advance(r2: R2, args: Map<string, string>): Promise<void> {
  const fixtureId = Number(args.get("fixture"));
  const raw = args.get("status");
  if (!fixtureId || !raw) throw new Error("advance needs --fixture ID --status <rawStatus>");
  if (!isFakeId(fixtureId)) throw new Error(`--fixture ${fixtureId} is not in the reserved fake range`);

  const match = await loadMatch(r2, fixtureId);
  const minute = args.has("minute") ? Number(args.get("minute")) : match.minute;
  const phase = syntheticPhase(raw, minute);
  match.rawStatus = raw;
  match.minute = minute;
  match.status = phase.status;
  match.period = phase.period;
  match.running = phase.running;

  await r2.putJson(`matches/${fixtureId}.json`, match, CACHE_CONTROL_LIVE);
  await upsertFixture(r2, match);
  console.log(`advanced ${fixtureId} → ${raw} (status=${match.status}, minute=${minute ?? "-"})`);
}

async function goal(r2: R2, args: Map<string, string>): Promise<void> {
  const fixtureId = Number(args.get("fixture"));
  const side = args.get("team");
  if (!fixtureId || (side !== "home" && side !== "away")) {
    throw new Error("goal needs --fixture ID --team <home|away>");
  }
  if (!isFakeId(fixtureId)) throw new Error(`--fixture ${fixtureId} is not in the reserved fake range`);

  const match = await loadMatch(r2, fixtureId);
  const team = match[side];
  team.goals += 1;
  const event: CardEvent = { player: `Fake Scorer ${team.goals}`, minute: match.minute, extra: match.extra };
  team.goalEvents.push(event);
  match.lastGoal = { teamId: team.id, player: event.player, minute: event.minute, extra: event.extra };
  await r2.putJson(`matches/${fixtureId}.json`, match, CACHE_CONTROL_LIVE);
  await upsertFixture(r2, match);

  // Realistic goal → celebration: bump the scoring side's tally.
  const bump = Number(args.get("count") ?? 1);
  const key = `celebrate/${fixtureId}.json`;
  const file = (await r2.getJson<{ totals: Record<string, number> }>(key)) ?? { totals: {} };
  const teamKey = String(team.id);
  file.totals[teamKey] = (file.totals[teamKey] ?? 0) + bump;
  await r2.putJson(key, file, CACHE_CONTROL_LIVE);

  console.log(
    `goal: ${side} (${team.name}) now ${team.goals}; celebrate[${teamKey}] += ${bump} → ${file.totals[teamKey]}`,
  );
}

async function celebrate(r2: R2, args: Map<string, string>): Promise<void> {
  const fixtureId = Number(args.get("fixture"));
  const teamId = args.get("team");
  const count = Number(args.get("count") ?? 1);
  if (!fixtureId || !teamId) throw new Error("celebrate needs --fixture ID --team <teamId> --count N");
  if (!isFakeId(fixtureId)) throw new Error(`--fixture ${fixtureId} is not in the reserved fake range`);

  const key = `celebrate/${fixtureId}.json`;
  const file = (await r2.getJson<{ totals: Record<string, number> }>(key)) ?? { totals: {} };
  file.totals[teamId] = (file.totals[teamId] ?? 0) + count;
  await r2.putJson(key, file, CACHE_CONTROL_LIVE);
  console.log(`celebrate[${teamId}] += ${count} → ${file.totals[teamId]} (fixture ${fixtureId})`);
}

/** Paginate an S3 prefix, returning every key. */
async function listKeys(s3: S3Client, prefix: string): Promise<string[]> {
  const bucket = env.r2.scoresBucket;
  const keys: string[] = [];
  let token: string | undefined;
  do {
    const res = await s3.send(
      new ListObjectsV2Command({ Bucket: bucket, Prefix: prefix, ContinuationToken: token }),
    );
    for (const obj of res.Contents ?? []) if (obj.Key) keys.push(obj.Key);
    token = res.IsTruncated ? res.NextContinuationToken : undefined;
  } while (token);
  return keys;
}

async function clear(r2: R2): Promise<void> {
  const s3 = rawS3();
  const bucket = env.r2.scoresBucket;

  // Delete reserved-range matches/ + celebrate/ objects.
  const objectKeys: string[] = [];
  for (const prefix of ["matches/", "celebrate/"]) {
    for (const key of await listKeys(s3, prefix)) {
      const id = Number(key.replace(prefix, "").replace(/\.json$/, ""));
      if (isFakeId(id)) objectKeys.push(key);
    }
  }
  for (const key of objectKeys) {
    await s3.send(new DeleteObjectCommand({ Bucket: bucket, Key: key }));
    console.log(`deleted ${key}`);
  }

  // Remove fakes from every fixtures-*.json file.
  for (const key of await listKeys(s3, "fixtures-")) {
    const file = await r2.getJson<FixturesFile>(key);
    if (!file) continue;
    const kept = file.matches.filter((m) => !isFakeId(m.fixtureId));
    if (kept.length !== file.matches.length) {
      await r2.putJson(key, { matches: kept }, CACHE_CONTROL_LONG);
      console.log(`pruned ${file.matches.length - kept.length} fake(s) from ${key}`);
    }
  }
  console.log(`cleared ${objectKeys.length} fake object(s)`);
}

async function main(): Promise<void> {
  assertStaging();
  const [command, ...rest] = process.argv.slice(2);
  const args = parseArgs(rest);
  const r2 = new R2();

  switch (command) {
    case "seed": return void (await seed(r2, args));
    case "advance": return void (await advance(r2, args));
    case "goal": return void (await goal(r2, args));
    case "celebrate": return void (await celebrate(r2, args));
    case "clear": return void (await clear(r2));
    default:
      console.error(
        "usage: npm run fake -- <seed|advance|goal|celebrate|clear> [flags]\n" +
          "  seed      --count N --state SCHEDULED|LIVE|HT|FINISHED[,...]\n" +
          "  advance   --fixture ID --status <1H|HT|2H|ET|FT|...> [--minute N]\n" +
          "  goal      --fixture ID --team <home|away> [--count N]\n" +
          "  celebrate --fixture ID --team <teamId> --count N\n" +
          "  clear",
      );
      process.exit(1);
  }
}

main().catch((err) => {
  console.error(err instanceof Error ? err.message : err);
  process.exit(1);
});
