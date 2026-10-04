# Security review — 2026-10-04

Reviewed repository revision: `6ad3c55`.

Result: one locally reproduced medium-severity availability issue and one low-severity CDN hardening gap. No critical/high-severity exploit was identified in the reviewed code. This is a repository review with isolated local reproductions, not a certification of the deployed services.

## 1. Medium: unvalidated match counters can exhaust or crash the Mac app

Locations:

- `app/Sources/Models/MatchModels.swift:231`: remote goal/card counters decode as unrestricted `Int` values.
- `app/Sources/Services/MatchDiff.swift:115`: goal increments and decrements generate one event per unit of change without a limit.
- `app/Sources/Services/MatchDiff.swift:158`: card processing adds one to the previous count without checking for overflow and then loops to the new count.
- `app/Sources/Services/LiveStore.swift:409`: event generation runs synchronously from the main-actor ingestion path.
- `app/Sources/Services/LiveStore.swift:316`: the remote minute is also added to stoppage time before conversion to `Double`, without validating its range.

**Impact:** a small, valid JSON response can trigger disproportionate CPU/memory use and freeze the UI. Extreme integers can cause a Swift arithmetic trap. The 4 MiB response limit does not constrain the computational work induced by numeric values.

**Exploit prerequisites:** an attacker must influence match JSON on the trusted scores origin, through CDN/bucket write access or a compromised upstream/publishing pipeline. No unauthenticated production write route was found. An accidental malformed upstream score can trigger the same behavior. This is not an arbitrary-internet-client authentication bypass.

**Local evidence:** compiled the actual `MatchModels.swift` and `MatchDiff.swift` with a temporary Foundation-only harness. Only the unrelated kickoff parser was supplied by the harness. No live service was contacted by the reproductions.

1. Decode this previous fixture:

   ```json
   {"fixtureId":1,"leagueId":39,"kickoffISO":"2026-10-04T12:00:00Z","status":"LIVE","minute":1,"home":{"id":1,"name":"A","goals":0,"yellowCards":0,"redCards":0},"away":{"id":2,"name":"B","goals":0,"yellowCards":0,"redCards":0}}
   ```

2. Decode the same JSON with only the home goals changed to `50000`, then call `MatchDiff.diff(prev: previous, next: current)`. Observed: `payload_bytes=228 generated_events=50000`.
3. In a separate isolated process, decode the original JSON with home `yellowCards` set to `9223372036854775807`. Pass that decoded fixture as both previous and current. Observed: process terminated with signal 5 (`SIGTRAP`, Python return code `-5`). The unconditional `kind.before + 1` overflows immediately. This tests the diff function directly; a real polling reproduction needs a subsequent changed response because HTTP 304 skips diffing.

**Recommended fix:** validate nonnegative, domain-appropriate bounds on scores, cards, minutes, stoppage time, and collection sizes before accepting network or persisted fixtures. Independently cap work/events per diff and make arithmetic safe even for programmatically constructed fixtures. Reject invalid snapshots while preserving the last valid state. Add regression tests for extreme integers, negative counts, large positive and negative score deltas, and ordinary match transitions. Validate upstream data before publishing as an additional boundary.

## 2. Low: the CDN path guard does not enforce canonical object names

Location: `infra/secure_scores.py:22`.

The allow condition checks only prefixes, suffixes, and lengths. A local evaluation of those exact predicates accepts all of:

- `/fixtures-aaaaaaaaaa.json`
- `/matches/not-a-number.json`
- `/matches/nested/x.json`
- `/matches/.json`

**Impact:** these malformed paths pass the managed guard, allowing requests for arbitrary nonexistent objects under the permitted shapes. Varying those paths produces distinct default cache keys and can cause origin work. Existing per-IP/per-colocation rate limiting reduces abuse; actual origin traffic, billing impact, and the deployed rule state were not tested. The repository already documents the broader residual risk from distributed traffic and nonexistent numeric match IDs.

**Recommended fix:** enforce numeric match IDs and the intended date format before origin access, using a mechanism supported by the deployed Cloudflare plan. Add predicate tests covering malformed names and nested paths. Strict syntax alone will not prevent requests for nonexistent numeric IDs; retain rate limiting and verify operations/billing alerts, and consider validating published IDs at the edge if stronger protection is required.

Cloudflare documents the full URI as part of the [default cache key](https://developers.cloudflare.com/cache/how-to/cache-keys/) and origin operations in [R2 pricing](https://developers.cloudflare.com/r2/pricing/). The cost-abuse assessment is an inference from those behaviors and the checked-in configuration, not a measured live exploit.

## Checks completed

| Check | Result |
| --- | --- |
| `backend`: `npm audit --json` | 0 reported vulnerabilities; production and development dependencies included |
| `tester`: `npm audit --json` | 0 reported vulnerabilities; production and development dependencies included |
| Backend `npm test` | 136 tests passed across 10 files |
| Backend `npm run typecheck` | Passed |
| `python3 -m unittest discover -s infra/test -v` | 4 tests passed |
| `bash app/scripts/test-security.sh` | Passed URL policy, response byte limits, and catalog validation checks |
| `gitleaks git --redact --no-banner --log-level warn` | Exit 0; no findings in the scanned Git history |
| OSV commit queries for all 13 `app/Package.resolved` pins | No matching advisories returned; commit/binary-package coverage is limited |
| Isolated Swift adversarial fixtures | Event amplification and arithmetic trap reproduced |

Also reviewed service OIDC checks, route authorization, redirect handling, image download/decode limits, sandbox entitlements, dependency pins, GitHub deployment trust, and infrastructure permission configuration. Existing OIDC tests exercise signature tampering, wrong issuer/audience/identity, expiry, and deploy-versus-scheduler authorization through the real Google verification library with a local test certificate.

## Scope limits

No production/staging exploit traffic, load test, cloud mutation, or deployment was performed. Actual Cloud Run IAM, Cloudflare rules, R2 token scopes/public access, billing alerts, and GitHub environment protections were not inspected in the live accounts. The initial audit did not include a full Xcode app build; remediation builds are recorded below. No container OS vulnerability scan or audit of bundled third-party binary contents was performed. Empty advisory results and a clean secret scan do not establish absence of vulnerabilities or secrets.

## Remediation prepared locally

Following the review, both findings were addressed in the working tree:

- Fixture decoding now rejects unsafe scores, card counts, times, and collection sizes, including persisted fixtures. Ingestion also validates values constructed without decoding. An invalid old cache clears its bootstrap markers so the app can recover.
- The diff engine validates both snapshots and suppresses bursts exceeding 64 events. Both original exploit cases are regression-tested, alongside ordinary goals, VAR cancellations, cards, substitutions, and shootouts.
- The CDN guard now requires canonical raw paths with numeric IDs and formatted dates, rejecting encoded aliases and nested or malformed paths. Tests evaluate the generated predicate and preserve the existing ruleset safety checks.

Remediation validation: both standalone Swift security suites passed, all seven infrastructure tests passed, and `git diff --check` passed. The unsigned Debug app built successfully with locked dependencies. A second unsigned Debug build, generated from a temporary spec without `DEV_BACKEND`, also passed, compiling real-service ingestion and persisted-cache recovery without launching the app or running release upload scripts. The normal generated project was restored afterward.

These changes require a new app release and application of the Cloudflare guard (`python3 infra/secure_scores.py --apply` with the documented zone credentials). The local predicate tests are not a Cloudflare API validation or a live enforcement test. Existing installed app builds remain vulnerable until updated. The guard still cannot prevent all distributed traffic or requests for syntactically valid nonexistent objects.

## Authorized rollout — 2026-10-04

The Cloudflare guard has now been applied and read back successfully. Production
`catalog.json` returned 200; malformed match/date paths, query variants, and an
Origin header returned 403. Staging canonical access remains restricted (401),
while malformed requests are blocked (403). The existing origin rate limit was
preserved. There had been no custom firewall entrypoint before this rollout.

Backend publication validation was added for older clients, together with an
8 MiB upstream response limit. All 145 backend tests, type checking, build, npm
audit, both Swift security suites, and seven infrastructure tests passed.

Firebase apps/configurations were registered for the current bundle identifier
in both environments. The release build now rejects mismatched Firebase bundle
IDs. Version 1.0.0 build 2 archived successfully and passed signature verification.
App Store upload and backend deployment results will be recorded after completion.
