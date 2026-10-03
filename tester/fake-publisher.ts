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
 * Fake fixtures default to ids from 900001 up, but what makes an id "fake" is the
 * seed manifest (`fake-manifest.json` in the bucket), not the number: real
 * API-Football ids run past 900001 too (e.g. 1565179), so only ids this tool
 * seeded are ever mutated, deleted or pruned. They use real league/team ids so
 * catalog logos still resolve.
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
import { toScheduleRow, utcPollRange } from "../backend/src/poller.js";
import { CACHE_CONTROL_LIVE, CACHE_CONTROL_LONG, R2 } from "../backend/src/r2.js";
import type { CardEvent, MatchState, TeamScore } from "../backend/src/types.js";

/** Default first id for `seed`. Real fixtures can share this range — the
 * manifest, not the id, is what marks a fixture as fake. */
const DEFAULT_FIXTURE_START = 900001;

/** Every fixture id `seed` wrote, so `clear` and the mutators touch only those. */
const MANIFEST_KEY = "fake-manifest.json";

interface Manifest {
  fixtureIds: number[];
}

async function loadManifest(r2: R2): Promise<Set<number>> {
  const file = await r2.getJson<Manifest>(MANIFEST_KEY);
  return new Set(file?.fixtureIds ?? []);
}

async function saveManifest(r2: R2, ids: Set<number>): Promise<void> {
  await r2.putJson(MANIFEST_KEY, { fixtureIds: [...ids].sort((a, b) => a - b) }, "no-store");
}

async function assertSeeded(r2: R2, fixtureId: number): Promise<void> {
  if (!(await loadManifest(r2)).has(fixtureId)) {
    throw new Error(`--fixture ${fixtureId} was not seeded by this tool (not in ${MANIFEST_KEY})`);
  }
}

// A league the app actually follows, so a seeded fixture is a fan match for
// someone testing with the default club picks. League 1 (the World Cup) is
// archived and never polled, so seeding into it would publish into a void.
const REAL_LEAGUE_ID = 140; // API-Football: La Liga
/** Seasons come from catalog.json in production; a fake fixture just needs one. */
const REAL_SEASON = 2026;
const REAL_TEAMS = [
  { id: 541, name: "Real Madrid" },
  { id: 529, name: "Barcelona" },
  { id: 530, name: "Atletico Madrid" },
  { id: 536, name: "Sevilla" },
  { id: 532, name: "Valencia" },
  { id: 548, name: "Real Sociedad" },
  { id: 543, name: "Real Betis" },
];

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

function utcDay(offset: number, base = new Date()): string {
  const day = Date.UTC(base.getUTCFullYear(), base.getUTCMonth(), base.getUTCDate());
  return new Date(day + offset * 86_400_000).toISOString().slice(0, 10);
}

function pollRangeDates(now = new Date()): string[] {
  const range = utcPollRange(now);
  return [range.from, today(), range.to];
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

function parseDayOffsets(value: string): number[] {
  const offsets = value
    .split(",")
    .map((s) => Number(s.trim()))
    .filter((n) => Number.isInteger(n));
  if (offsets.length === 0) throw new Error("--days must include comma-separated integer offsets, e.g. -1,0,1");
  return offsets;
}

function kickoffFor(index: number, dayOffsets: number[], time: string, spacingMinutes: number): string {
  if (!/^\d{2}:\d{2}$/.test(time)) throw new Error('--time must be UTC "HH:MM", e.g. 18:00');
  const [hours, minutes] = time.split(":").map(Number);
  if (hours === undefined || minutes === undefined || hours > 23 || minutes > 59) {
    throw new Error('--time must be UTC "HH:MM", e.g. 18:00');
  }
  const dayOffset = dayOffsets[index % dayOffsets.length]!;
  const matchesEarlierOnSameDay = Math.floor(index / dayOffsets.length);
  const started = Date.UTC(
    new Date().getUTCFullYear(),
    new Date().getUTCMonth(),
    new Date().getUTCDate() + dayOffset,
    hours,
    minutes + matchesEarlierOnSameDay * spacingMinutes,
  );
  return new Date(started).toISOString();
}

function teamPair(index: number): { home: TeamScore; away: TeamScore } {
  const home = REAL_TEAMS[index % REAL_TEAMS.length]!;
  const away = REAL_TEAMS[(index + 1) % REAL_TEAMS.length]!;
  return {
    home: makeTeam(home.id, home.name),
    away: makeTeam(away.id, away.name),
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

async function ensurePollRangeFixtureFiles(r2: R2): Promise<void> {
  for (const date of pollRangeDates()) {
    const key = fixturesKey(date);
    const current = (await r2.getJson<FixturesFile>(key)) ?? { matches: [] };
    await r2.putJson(key, current, CACHE_CONTROL_LONG);
  }
}

/** Splice a fresh set of fake matches into the UTC fixture files (long TTL). */
async function mergeFixtures(r2: R2, fakes: MatchState[], seeded: Set<number>): Promise<void> {
  await ensurePollRangeFixtureFiles(r2);
  const dates = new Set([...pollRangeDates(), ...fakes.map((m) => m.kickoffISO.slice(0, 10))]);
  for (const date of dates) {
    const key = fixturesKey(date);
    const current = (await r2.getJson<FixturesFile>(key)) ?? { matches: [] };
    const byId = new Map<number, MatchState>();
    // Drop only rows this tool seeded (earlier runs + this one); real rows stay.
    for (const m of current.matches) if (!seeded.has(m.fixtureId)) byId.set(m.fixtureId, m);
    for (const m of fakes.filter((m) => m.kickoffISO.slice(0, 10) === date)) {
      byId.set(m.fixtureId, toScheduleRow(m));
    }
    await r2.putJson(key, { matches: [...byId.values()] }, CACHE_CONTROL_LONG);
  }
}

/** Replace one fake match inside its UTC fixtures file so its schedule row stays in sync. */
async function upsertFixture(r2: R2, match: MatchState): Promise<void> {
  await ensurePollRangeFixtureFiles(r2);
  const date = match.kickoffISO.slice(0, 10);
  const key = fixturesKey(date);
  const current = (await r2.getJson<FixturesFile>(key)) ?? { matches: [] };
  const matches = current.matches.filter((m) => m.fixtureId !== match.fixtureId);
  matches.push(toScheduleRow(match));
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
  const fixtureStart = Number(args.get("fixture-start") ?? DEFAULT_FIXTURE_START);
  const dayOffsets = parseDayOffsets(args.get("days") ?? "0");
  const kickoffTime = args.get("time") ?? "18:00";
  const spacingMinutes = Number(args.get("spacing-minutes") ?? 120);
  if (!Number.isInteger(count) || count < 1) throw new Error("--count must be a positive integer");
  if (!Number.isInteger(fixtureStart) || fixtureStart < 1) {
    throw new Error("--fixture-start must be a positive integer");
  }
  if (!Number.isFinite(spacingMinutes) || spacingMinutes < 0) {
    throw new Error("--spacing-minutes must be a non-negative number");
  }
  const states = (args.get("state") ?? "LIVE")
    .split(",")
    .map((s) => s.trim().toUpperCase());
  for (const s of states) {
    if (!STATE_TO_RAW[s]) {
      throw new Error(`Unknown --state "${s}". Use ${Object.keys(STATE_TO_RAW).join("|")}.`);
    }
  }

  // Never overwrite a match file this tool didn't write: refuse an id that
  // already exists in the bucket unless the manifest says it's ours.
  const seeded = await loadManifest(r2);
  for (let i = 0; i < count; i++) {
    const fixtureId = fixtureStart + i;
    if (!seeded.has(fixtureId) && (await r2.getJson(`matches/${fixtureId}.json`))) {
      throw new Error(`matches/${fixtureId}.json already exists and was not seeded by this tool — pick another --fixture-start`);
    }
  }
  // Record the ids before writing anything, so a half-finished seed is still clearable.
  for (let i = 0; i < count; i++) seeded.add(fixtureStart + i);
  await saveManifest(r2, seeded);

  const fakes: MatchState[] = [];
  for (let i = 0; i < count; i++) {
    const fixtureId = fixtureStart + i;
    const stateName = states[i % states.length]!;
    const { raw, minute } = STATE_TO_RAW[stateName]!;
    const phase = syntheticPhase(raw, minute);
    const { home, away } = teamPair(i);
    const state: MatchState = {
      fixtureId,
      leagueId: REAL_LEAGUE_ID,
      season: REAL_SEASON,
      round: `Test - ${utcDay(dayOffsets[i % dayOffsets.length]!)} ${Math.floor(i / dayOffsets.length) + 1}`,
      kickoffISO: kickoffFor(i, dayOffsets, kickoffTime, spacingMinutes),
      secondHalfStartISO: null,
      status: phase.status,
      rawStatus: raw,
      minute,
      extra: null,
      period: phase.period,
      running: phase.running,
      home,
      away,
    };
    fakes.push(state);
    await r2.putJson(`matches/${fixtureId}.json`, state, CACHE_CONTROL_LIVE);
    await r2.putJson(`celebrate/${fixtureId}.json`, { totals: {} }, CACHE_CONTROL_LIVE);
    console.log(
      `seeded matches/${fixtureId}.json (${stateName}, ${state.kickoffISO}, ` +
        `${home.name} ${home.id} vs ${away.name} ${away.id}) + celebrate/${fixtureId}.json`,
    );
  }
  await mergeFixtures(r2, fakes, seeded);
  console.log(`merged ${fakes.length} fake match(es) into UTC fixture files`);
}

async function advance(r2: R2, args: Map<string, string>): Promise<void> {
  const fixtureId = Number(args.get("fixture"));
  const raw = args.get("status");
  if (!fixtureId || !raw) throw new Error("advance needs --fixture ID --status <rawStatus>");
  await assertSeeded(r2, fixtureId);

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
  await assertSeeded(r2, fixtureId);

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
  await assertSeeded(r2, fixtureId);

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

  // Delete the matches/ + celebrate/ objects of manifest ids only.
  const seeded = await loadManifest(r2);
  const objectKeys: string[] = [];
  for (const prefix of ["matches/", "celebrate/"]) {
    for (const key of await listKeys(s3, prefix)) {
      const id = Number(key.replace(prefix, "").replace(/\.json$/, ""));
      if (seeded.has(id)) objectKeys.push(key);
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
    const kept = file.matches.filter((m) => !seeded.has(m.fixtureId));
    if (kept.length !== file.matches.length) {
      await r2.putJson(key, { matches: kept }, CACHE_CONTROL_LONG);
      console.log(`pruned ${file.matches.length - kept.length} fake(s) from ${key}`);
    }
  }
  await saveManifest(r2, new Set());
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
          "  seed      --count N --state SCHEDULED|LIVE|HT|FINISHED[,...] [--days -1,0,1] [--time HH:MM] [--spacing-minutes N] [--fixture-start ID]\n" +
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
