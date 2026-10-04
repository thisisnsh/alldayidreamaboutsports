# Open-source readiness review

Original baseline reviewed 2026-10-04 at commit `1be14eb`. Remediation verified 2026-10-04.

## Current remediation status

Repository changes are committed separately. Local validation is green, but the
live rollout is not complete. Do not interpret the committed infrastructure
scripts as confirmation that production has changed.

| Finding | Current status |
| --- | --- |
| Dependency advisories | Fixed: clean installs and both full/production backend audits report **0 vulnerabilities**; tester audit also reports 0. |
| Async route crashes | Fixed: errors return safe HTTP 500 responses and the process continues serving. Startup validates required service/storage/CDN configuration. Provider/probe requests have deadlines and refuse redirects. |
| Remote client data | Fixed: streamed byte limits, HTTPS host and redirect policy, bounded decoded image dimensions/cache, and duplicate/oversized catalog rejection. |
| Deployment gating | Fixed in workflows: verification for the same commit precedes deployment credentials; pinned actions, recurring dependency/secret checks, native build CI, and a tracked Swift lockfile are added. Workflows have been linted locally but not run on GitHub yet. |
| License/assets | GPL-3.0-only added for original code and owner-confirmed app icons. Audio, playback, preference, and analytics removed. Security/contributor policies and third-party notices added. |
| CDN cache fragmentation | `infra/secure_scores.py` and setup integration are committed and locally tested. **Not applied live:** available Cloudflare OAuth was expired and lacked WAF write scope. Requires a zone-scoped token and live verification. |
| Broad IAM | Resource-scoped replacement script and setup changes committed. Read-only staging preflight/plan succeeded. **Not applied live:** stage the migration and verify a source deployment before production. |
| Branch/environment protections | Still an account-level task. Current private-plan protection API returned HTTP 403. Configure required checks/reviewers when supported; repository visibility was not changed. |
| R2 operations alerts | Still an account-level task; delivery of live billing/operations alerts has not been verified. |

Final checks: clean backend install, typecheck, **136 tests**, build, full and
production audits; clean tester install/typecheck/audit; Swift remote-data
regressions; unsigned Debug build with locked packages; four infrastructure
unit tests; shell syntax; actionlint; full-history Gitleaks with a narrowly
scoped historical public-key exception. All passed. Signed releases and a
complete native/container dependency advisory scan remain outside this review.

The findings below preserve the original evidence and explain the fixes. Their
old dependency counts and missing-file observations describe the baseline,
not the remediated tree. No anonymous backend-write or authentication bypass,
remote code execution, or genuine committed credential was demonstrated.

## Original findings

### 1. Medium — public query strings fragment the CDN cache (confirmed live)

Location: `infra/setup-r2.sh:193–211`, `241–246`; `backend/src/routes.ts:233–236`.

The cache rule enables caching but does not ignore or reject arbitrary query strings. A small read-only production probe returned:

| Request to the scores host | HTTP | CF-Cache-Status |
| --- | --- | --- |
| `/catalog.json` | 200 | HIT |
| `/catalog.json?readiness-audit=20261004-a` | 200 | MISS |
| Same query again | 200 | HIT |
| `/catalog.json?readiness-audit=20261004-b` | 200 | MISS |

An anonymous requester can continually create cold cache keys for the same object. This undermines the stated cache-only cost assumption and can increase origin traffic. The configured limit is per IP and colo, not a global origin budget; distributed requests remain a concern. The normal catalog health probe can remain healthy during this abuse. The repository still marks the R2 operations alarm as TODO.

Fix: reject unused query strings or configure a shared cache key for these static JSON objects, restrict allowed methods/paths, account for header-based cache variations, and verify origin-operations alerts. Recheck query variants after deployment. No load test was performed, and actual billing impact and live WAF rules were not measured.

Reference: [Cloudflare cache keys](https://developers.cloudflare.com/cache/how-to/cache-keys/).

### 2. Medium — vulnerable dependency versions remain (confirmed by registry audit)

Location: `backend/package.json:17–29`, `backend/package-lock.json`.

| Scope | npm audit result |
| --- | --- |
| Backend, all dependencies | 10 entries: 2 high, 7 moderate, 1 low |
| Backend, production only | 5 moderate entries; no high/critical |
| Tester | 0 entries |

These are affected dependency entries, not ten independently reachable exploits. The five production entries are `uuid@9.0.1` and its dependency chains (`gaxios`, `google-gax`, `retry-request`, `teeny-request`). The UUID advisory concerns v3/v5/v6 functions with supplied buffers. The inspected consumers use v4; no application-controlled path to the affected functions was found.

Development dependencies include `vitest@3.2.6`/`@vitest/mocker`, `postcss@8.5.15`, `nanoid@3.3.12`, and an esbuild version beneath Vite. The high ratings are development dependencies; the Dockerfile prunes them from the runtime image. The Vitest advisory requires particular development-server exposure, which the configured `vitest run` command does not establish.

Fix: update the affected chains and Vitest to patched releases, regenerate the lockfile, rerun tests and both production/full audits, and add recurring dependency checks. Do not blindly force major upgrades. The baseline review made no dependency changes; the subsequent fixes are recorded above.

References: [UUID advisory](https://github.com/advisories/GHSA-w5hq-g745-h8pq), [Vitest advisory and exposure conditions](https://github.com/advisories/GHSA-82fw-gwwq-j7x9). Full audit output was retained locally at `/tmp/adiass-backend-audit.json` and `/tmp/adiass-prod-audit.json`.

### 3. Medium — authenticated async route failures can terminate the process (reproduced locally)

Location: `backend/src/routes.ts:164–206`, `213–242`.

These two async handlers lack the try/catch used by the other operational routes. Under the installed Express 4 and Node 24, a rejected handler promise is not forwarded automatically to error middleware.

Two isolated loopback reproductions exited with status 1:

- `/internal/test-event`: simulated R2 write failure in a staging bucket.
- `/internal/cache-health`: missing `SCORES_DOMAIN`, despite successful service-authentication startup validation. This case used the real MatchWindow with an empty schedule.

Authentication was explicitly stubbed for the local fault-injection harness. This demonstrates failure handling, not an authentication bypass. Normal MatchWindow storage errors are caught internally; those errors alone were not shown to crash the health route. The staging mutation route is disabled for production bucket names.

Fix: wrap every async handler and forward errors to a central error handler, or adopt Express 5 with appropriate compatibility tests. Validate all required operational configuration at startup. Add explicit outbound request deadlines. Add regression tests for rejected storage operations and missing configuration.

Reference: [Express error handling](https://expressjs.com/en/guide/error-handling/).

### 4. Medium — deployment is independent of verification; cloud permissions are broad

Location: `.github/workflows/backend-deploy.yml:3–6,21–39`; `infra/setup-gcp.sh:44–46,131–133`.

The deployment workflow can deploy main without waiting for backend CI; it contains no test gate. GitHub's live environment configuration restricts both environments to main but has no required-reviewer rule. Branch protection/ruleset inspection returned HTTP 403 with a plan limitation, so those protections could not be verified. The CI workflow also uses mutable action tags, and no committed automated dependency or secret scanning workflow exists.

Live production IAM confirms project-wide Secret Manager access for runtime, and project-wide storage administration and service-account impersonation capability via `serviceAccountUser` for deployment. These increase impact if an authorized deployment or runtime is compromised. They do not give arbitrary public contributors deployment access: live federation correctly restricts immutable repository/owner IDs, main, the exact workflow, and the prod environment.

Fix: make deployment depend on successful checks for the same commit; configure protected main and a production approval policy appropriate to the maintainer model; pin CI actions; scope secret, storage, and service-account access to required resources. Enable security reporting and scanning when publishing.

### 5. Release blocker — license and public contribution/security documentation are missing

No tracked LICENSE, SECURITY.md, CONTRIBUTING.md, or third-party notice/provenance document was found. Publishing a repository alone does not supply an open-source license. Choose the code license deliberately, document a private vulnerability-reporting channel, and verify redistribution rights/attribution for bundled artwork/audio and dependency notices. This review did not establish asset provenance and makes no infringement finding.

The contributor setup also embeds the owner's Apple team, bundle ID, cloud projects, and production CDN defaults. These identifiers are not secrets, but fork configuration should be documented. Debug builds make a production catalog request. The Swift dependency lockfile lives inside a gitignored generated Xcode project, so a fresh clone does not preserve the exact reviewed Swift dependency resolution.

Reference: [GitHub licensing guidance](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/licensing-a-repository).

## Additional hardening

- `app/Sources/Services/AppSession.swift:228–230` constructs a dictionary requiring unique remote league IDs. Duplicate IDs cause a Swift fatal error; the dictionary failure was reproduced in isolation. Validate/deduplicate catalog IDs. Exploitation requires influencing the trusted catalog, rather than simply sending a request to the app.
- `app/Sources/Services/ScoresService.swift:21` and `app/Sources/Overlay/TeamLogoStore.swift:116–118` buffer remote responses without application-level size limits. Logo URLs have no application-level scheme/host allowlist or redirect restrictions. Bound JSON/image sizes and decoded dimensions and constrain logo destinations. No arbitrary file exfiltration or code execution was demonstrated.
- Add macOS build verification and meaningful tests for remote-data validation to CI. Preserve reproducible Swift dependency resolution outside the ignored generated project.

## Original baseline verification completed

- Clean tracked-source export: backend `npm ci --ignore-scripts`, typecheck, all **130 tests**, and build passed. The install intentionally disabled lifecycle scripts. The existing local installation also passed typecheck, all tests, and build.
- Tester typecheck passed; registry audit returned no known vulnerabilities.
- Clean tracked-source export: XcodeGen and unsigned Debug `xcodebuild` succeeded without private Firebase plists. Signed Staging/Release archives and interactive behavior were not tested.
- Gitleaks scanned **220 commits** across all locally available refs. The only two history alerts were old `SUPublicEDKey` public verification keys, not private signing keys. Separate backend/app source scans found no secrets. Remote-only refs, GitHub artifacts, cloud logs, and every ignored local file were not scanned.
- Authentication tests exercise real Google-library signature, issuer, audience, expiry, verified-email, and identity checks with a local test certificate. Every registered backend route rejects missing credentials; retired public routes return 404.
- Live production Cloud Run IAM lists only scheduler/deploy service accounts as service-level invokers. An unauthenticated health request returned **403**. Inspected project IAM showed no public binding.
- Live production workload identity federation restricts repository/owner IDs, main, the deployment workflow, and prod environment.
- Production catalog caching and query fragmentation were checked with a handful of GET requests. An initial Python client received 403; curl returned the repeatable results documented above. No access controls were bypassed.
- Static review confirmed app sandbox/hardened-runtime settings, HTTPS scores configuration, no remote executable updater, and a non-root production container.

## Remaining rollout

1. With a Cloudflare token limited to Zone WAF Edit, review/apply the scores guard
   and verify canonical GET/HEAD requests succeed while query/header variants
   are blocked before origin. See `infra/README.md`.
2. Review/apply the IAM plan to staging, verify a source deployment with the
   deploy identity, then apply and verify production. No live IAM grants have
   been changed by this remediation.
3. Push/review the commits and verify GitHub workflow runs. Enable main branch
   protections and the desired production review requirement on a supporting
   plan or when publishing. Publishing was not part of this change.
4. Verify Cloudflare R2 operations/billing alert delivery, r2.dev exposure, and
   effective storage credential scope. The local code cannot establish these
   account settings.

No production deploy, cloud-rule mutation, GitHub setting change, or repository
visibility change was performed. The repository fixes, licensing, audio removal,
and infrastructure plans are complete; live operational verification remains.
