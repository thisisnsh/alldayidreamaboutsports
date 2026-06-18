# tester/ — staging-only dev tooling

Two scripts for exercising the §0 edge path and the live overlay/celebration UI
against **staging**, without API-Football or the Cloud Scheduler/Tasks pipeline:

- **`loadtest.ts`** — fires N virtual clients at the staging scores CDN and reports
  latency + `cf-cache-status` distribution (proves the edge, not R2, serves files).
- **`fake-publisher.ts`** — seeds/mutates fake matches and celebration tallies by
  writing directly to the staging R2 bucket via the S3 SDK.

These reuse the deployed `R2` class, cache constants, and types from `backend/src/`
(one-way import; deployed code never imports from `tester/`).

> ⚠️ **Staging only — never production.**
> - The publisher **refuses to run** unless `R2_BUCKET_SCORES` contains `staging`.
> - Fake fixtures use a reserved id range (`900001+`) so they can never collide
>   with real World Cup matches and are trivially purged with `clear`.
> - Fake fixtures keep the reserved fixture ids, but use real API-Football ids for
>   the World Cup league (`1`) and teams such as France (`2`), Brazil (`6`),
>   England (`10`), Argentina (`26`), and Portugal (`27`).
> - Always point `R2_*` and `SCORES_DOMAIN` at the **staging** environment. Double-
>   check `.staging.env` before running. Do not put production credentials here.

## Setup

```sh
cd tester
npm install
cp .staging.env.example .staging.env   # then fill in staging values (see below)
```

Create `tester/.staging.env` (gitignored) with the **staging** values, pulled from
GCP Secret Manager / the Cloudflare R2 dashboard for the staging environment:

```sh
R2_ENDPOINT=https://<account-id>.r2.cloudflarestorage.com
R2_ACCESS_KEY_ID=<staging access key>
R2_SECRET_ACCESS_KEY=<staging secret>
R2_BUCKET_SCORES=<staging scores bucket>   # MUST contain "staging"
SCORES_DOMAIN=https://<staging scores hostname>
```

The npm scripts load this file via Node's native `--env-file=.staging.env`.

## Test steps

Run everything from `tester/`. A typical end-to-end pass:

1. **Typecheck** (after any change):

   ```sh
   npm run typecheck
   ```

2. **Seed fake matches** into the staging bucket:

   ```sh
   npm run fake -- seed --count 3 --state LIVE
   ```

   Copy-paste seed for 10 fake fixtures across yesterday/today/tomorrow UTC, all
   using real World Cup league/team ids and a fixed UTC kickoff time:

   ```sh
   npm run fake -- clear && npm run fake -- seed --count 10 --days -1,0,1 --time 18:00 --spacing-minutes 120 --state SCHEDULED,LIVE,HT,FINISHED
   ```

   Mix states across the seeded matches if you like:

   ```sh
   npm run fake -- seed --count 3 --state SCHEDULED,LIVE,HT
   ```

   Verify the fakes appear on the CDN and carry the live Cache-Control:

   ```sh
   curl -i https://<staging-scores-domain>/fixtures-$(date -u -v-1d +%F).json
   curl -i https://<staging-scores-domain>/fixtures-$(date -u +%F).json
   curl -i https://<staging-scores-domain>/fixtures-$(date -u -v+1d +%F).json
   curl -i https://<staging-scores-domain>/matches/900001.json   # expect cache-control: ...max-age=5...
   ```

3. **Score a goal** (bumps the match score and the scoring side's tally):

   ```sh
   npm run fake -- goal --fixture 900001 --team home
   curl -s https://<staging-scores-domain>/celebrate/900001.json   # total bumped
   ```

4. **Bump a celebration tally** directly:

   ```sh
   npm run fake -- celebrate --fixture 900001 --team 2 --count 50
   ```

5. **Advance a match's state** (e.g. into half-time, then full-time):

   ```sh
   npm run fake -- advance --fixture 900001 --status HT
   npm run fake -- advance --fixture 900001 --status FT
   ```

6. *(Optional)* Launch the macOS app pointed at **staging** and watch a fake LIVE
   match, the goal overlay, and the celebration tally update from the commands above.

7. **Load test** the CDN (read-only, public GETs):

   ```sh
   npm run loadtest -- --fixtures 900001,900002,900003,900004,900005,900006,900007,900008,900009,900010 --clients 200 --duration 60
   ```

   Expect low p99 latency and a `cf-cache-status` histogram dominated by
   HIT/REVALIDATED — the §0 verdict should be ~100% healthy. A high
   MISS/BYPASS/DYNAMIC share flags a broken cache rule.

8. **Clean up** — remove all fakes from R2 and from the fixtures files:

   ```sh
   npm run fake -- clear
   ```

## `fake` subcommands

| Command | Flags | Effect |
| --- | --- | --- |
| `seed` | `--count N` `--state SCHEDULED\|LIVE\|HT\|FINISHED[,...]` `[--days -1,0,1]` `[--time HH:MM]` `[--spacing-minutes N]` `[--fixture-start ID]` | Write N `matches/{id}.json` + `celebrate/{id}.json`, ensure `fixtures-{today±1 UTC}.json` exists, and merge schedule rows into the matching UTC fixture files |
| `advance` | `--fixture ID` `--status <rawStatus>` `[--minute N]` | Re-derive phase from a raw status and write the match back |
| `goal` | `--fixture ID` `--team <home\|away>` `[--count N]` | Increment that side's goals + bump its celebration tally (default +1) |
| `celebrate` | `--fixture ID` `--team <teamId>` `--count N` | Add N to a team's celebration total |
| `clear` | — | Delete all reserved-range fake objects and prune them from `fixtures-*.json` |

## `loadtest` flags

| Flag | Default | Meaning |
| --- | --- | --- |
| `--base` | `SCORES_DOMAIN` | Scores hostname to hit |
| `--fixtures` | `900001,900002,900003` | Comma-separated fixture ids to poll |
| `--clients` | `50` | Concurrent virtual clients |
| `--duration` | `30` | Seconds to run |
| `--interval` | `5000` | Poll cadence per client (ms), mirrors the live TTL |
