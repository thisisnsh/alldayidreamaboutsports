# Pre-publication review — 2026-10-07

Initial reviewed revision: `7f022c3`; status rechecked at `494bd80` on the same
date against live GCP, Cloudflare and GitHub. This review covers tracked source,
configuration, local Git history, dependency advisories, the public privacy page, and
read-only GitHub repository settings. The recheck also inspects deployed cloud
configuration and legacy-data counts. Only this report and `TODO.md` were updated;
no application code, dependencies, cloud resources, Git history, or repository
visibility were changed during the recheck.

Recommendation: resolve finding 1, promote the dependency fix already deployed
to staging (finding 2), and make explicit decisions about findings 3–4 before
publishing the existing repository. No exploitable critical/high
application vulnerability or committed private credential was identified in this
review. The dependency advisory below is rated critical by its publisher, but its
documented exploit prerequisites are absent from the reviewed application.

| Finding | Current status |
| --- | --- |
| 1. Privacy/disclosures | Open: telemetry controls and disclosures are unchanged; legacy profiles remain |
| 2. Dependency advisory | Fixed in source and staging; current patch still needs a prod deployment |
| 3. Maintainer email in history | Still present; publication decision remains |
| 4. Historical audio rights | Audio remains recoverable; permission/history decision remains |
| 5. Origin cost exposure | Live guard/cache/rate limits and private IAM verified; global bound and alert delivery unresolved |

Most provisioning tasks in `TODO.md` are already complete. The live status table
below distinguishes deployed controls from the remaining release work.

## 1. Privacy: disclosures do not match the telemetry collected

Priority: high for release transparency; confirmed code/disclosure mismatch.

Evidence:

- `app/Sources/Services/Analytics.swift:140` sends the actual team ID on follow
  and unfollow events. Numeric IDs still identify the selected teams.
- `app/Sources/Services/Analytics.swift:204` sends setting values and mirrors
  them into Firebase user properties; line 231 synchronizes current preferences
  at launch, even when the user has not changed a setting.
- `app/Sources/Services/Analytics.swift:343` also copies event parameters into
  Crashlytics breadcrumbs.
- `app/Sources/AppDelegate.swift:16` configures Firebase and sends launch
  telemetry before onboarding. `app/Sources/Services/AppLog.swift:80` explicitly
  enables crash collection in Staging and Release. No telemetry preference or
  consent gate was found in the app's settings or onboarding.
- `README.md:11` describes the app as anonymous and without per-user behavior.
  `app/README.md:93` gives categorical advice about privacy labels that should
  instead be checked against actual SDK data collection and configuration.

The [live privacy policy](https://alldayidreamaboutsports.com/privacy/), retrieved
on the review date, is dated August 2026. It still describes Google sign-in,
Firestore profiles, and worldwide celebration counts, all removed from the
current architecture. It describes team/settings telemetry as aggregate counts
while the code sends individual choices and preference values. Its deletion
instructions address a profile, rather than the current telemetry identifiers.

An app-instance identifier permits events to be associated with one installation;
absence of a login or advertising identifier does not make this aggregate-only
collection. This is a technical transparency finding, not a determination of
which jurisdictions require consent. See Google's [Analytics collection
documentation](https://support.google.com/firebase/answer/6318039?hl=en) and
[Crashlytics data handling](https://firebase.google.com/support/privacy).

Remediation: either minimize telemetry to match the intended promises, or describe
the collected fields, installation identifiers, processors, retention, and user
controls accurately. Add a collection preference and apply it before the first
event; consider separate controls for diagnostics and product analytics. Gate
both Analytics and Crashlytics breadcrumbs so disabling one does not still send
the same event parameters through the other. Reassess App Store disclosures using
[Firebase's disclosure guidance](https://firebase.google.com/docs/ios/app-store-data-collection).
The website is maintained in a separate repository. Verify the disposition of any
legacy profile data before asserting it has been deleted; the initial review did not
inspect production user records.

Recheck: the code and the live August 2026 policy still exhibit the mismatch.
Firestore aggregate queries count **2 staging and 6 production `users`
documents**; no individual document fields were retrieved. Both databases have
deny-all client rules, but those rules do not delete stored profiles. The legacy
celebration cleanup is complete in both environments and does not include user
profiles. Decide and document their retention/deletion separately.

## 2. Dependency: patched in source/staging; production deployment pending

Status: fixed in source and staging; production promotion pending.
Priority: medium maintenance/deployment follow-up; no reachable exploit established.

At the initial reviewed revision, `backend/package-lock.json:3223` locked
`proxy-addr` to `2.0.7`, pulled in by Express. The initial `npm audit --json`
reported one critical vulnerability:
[GHSA-jqcg-44mw-7w3h / CVE-2026-90711](https://github.com/advisories/GHSA-jqcg-44mw-7w3h).
The patched version is `2.0.8`.

The advisory concerns overly broad trust matching for certain IPv6 proxy subnet
configurations, allowing forged forwarded client IPs. The reviewed backend does
not enable Express `trust proxy`, use `req.ip`/`req.ips` for access control, or rely
on IP-based application authentication. Its operational routes authenticate
Google OIDC identities. Therefore the advisory's critical rating should not be
presented as a demonstrated authentication bypass in this project.

Nevertheless, `.github/workflows/backend-ci.yml:28` runs
`npm audit --audit-level=low`, and deployment requires that reusable workflow to
pass. That initial lockfile failed the gate. The clean audit recorded in
`SECURITY_REVIEW.md` describes an earlier date, not the current dependency state.

Completed: commit `8ff7928` updates the lockfile to `proxy-addr` **2.0.8**.
The current backend and tester audits report zero vulnerabilities. Backend tests
(145 across 11 files) and both TypeScript checks pass. Staging subsequently
deployed the dependency upgrades at `b2de0e3` in
[successful run 37683243582](https://github.com/thisisnsh/alldayidreamaboutsports/actions/runs/37683243582).

Remaining: production's latest ready revision is `alldayidreamaboutsports-backend-00011-t4c`,
updated Oct 5. Its corresponding
[successful deployment run 37249424022](https://github.com/thisisnsh/alldayidreamaboutsports/actions/runs/37249424022)
used `1971b58`, whose lockfile still has `proxy-addr` 2.0.7. Deployment evidence
therefore indicates prod has not received the patch; the image's installed
packages were not independently scanned. Deploy the current verified backend
to prod after staging verification and repeat the private health smoke test.

## 3. Maintainer privacy: commit history contains a personal email address

Priority: publication decision; exposure is confirmed, undesirability is unknown.

The Git author metadata contains the maintainer's full name and a personal Gmail
address, distinct from the project's published support address. The literal
address is intentionally not copied into this report. Publishing this repository
with its current history exposes that metadata regardless of the contents of the
latest working tree or future GitHub email settings.

Local inspection:

```sh
git log --all --format='%an <%ae>' | sort -u
```

Remediation: decide whether that disclosure is acceptable before changing
visibility. If it is not, prepare a sanitized public history or a fresh public
snapshot and use a GitHub noreply identity for future commits. Rewriting shared
history requires coordination; this review did not perform it.

## 4. Historical asset: removed audio would still be published

Priority: unresolved redistribution-rights check, not a confirmed infringement.

`THIRD_PARTY_NOTICES.md:7` records removal of the confetti audio. The 68,316-byte
`app/Resources/confetti-pop.mp3` remains recoverable from commit `e754dac` and
the parent of removal commit `f943c2f`:

```sh
git cat-file -s f943c2f^:app/Resources/confetti-pop.mp3
```

The notices explicitly confirm icon ownership, but do not establish provenance
or redistribution permission for this historical audio. Removing a file in a new
commit does not remove its earlier version from the history being published.

Remediation: establish and document permission for publishing the original audio
file, including any required attribution, or omit it from the public history.
No claim is made here that the maintainer lacks permission. The removed
`.bdfl/workspace.json` was also inspected and contained only empty workspace
state, not a credential or conversation transcript.

## 5. Cost abuse: public R2 origin work has no global spending bound

Follow-up requested by the maintainer: medium residual architecture risk;
confirmed configuration gap, not a measured production billing exploit.

`infra/secure_scores.py` checks path spelling, not whether an object exists.
Evaluating its actual generated predicate locally accepted
`/matches/9999999999999999.json`, `/fixtures-9999-12-31.json`, and even the
calendar-invalid `/fixtures-2026-02-31.json`. Distinct accepted object paths can
cause cold origin lookups rather than sharing one cached response.

`infra/setup-r2.sh:26` defaults to 200 origin requests per 10 seconds.
At line 235 the counter keys are `ip.src` and `cf.colo.id`: the allowance is
per IP/location, not a global bucket quota. Distributed traffic can therefore
multiply the aggregate allowance. Cloudflare documents these
[rate-limiting semantics](https://developers.cloudflare.com/waf/rate-limiting-rules/parameters/).
Cache hits, tiered caching, the path/header guard, and existing rate limits
substantially reduce exposure, but do not establish a maximum monthly bill.

R2 Standard Class B operations cost $0.36 per million beyond the applicable
free allowance; bandwidth egress is free. Thus 100 million additional billable
Class B operations correspond to $36, and one billion to $360. These are unit
cost illustrations, not a demonstrated achievable attack rate. This review did
not measure the billing treatment of the candidate nonexistent-object requests.
See [R2 pricing](https://developers.cloudflare.com/r2/pricing/).

The cache-health route checks selected known files. It can remain healthy while
unrelated object lookups create origin traffic. The R2 operations alarm is still
marked TODO in `backend/src/routes.ts:242`; account-side alerts may exist but
were not verified. A manual emergency-stop runbook is not automatic enforcement.

GCP is better isolated from anonymous users: the deployment enables Cloud Run
IAM checks and disallows unauthenticated invocation, the app reads R2 directly,
and operational routes additionally verify the scheduler's OIDC identity.
No anonymous route to enqueue jobs, invoke provider polling, or write objects
was identified. The configured 50-instance limit is nevertheless not a dollar
cap; authorized-account compromise, accidental IAM changes, or internal job
failures remain separate cost risks. The live recheck confirms private invocation
and the resource-scoped grants in both projects; see the table below.

Recommended controls: verify live origin limits, disabled alternate public
bucket URLs, and IAM; restrict origin lookups to a bounded set of published
objects/current schedule dates where practical; add account-level operations
monitoring and an automatic origin-access cutoff with an explicit acceptable
outage policy. Do not add a metered per-request proxy without also budgeting its
own request costs. Right-size Cloud Run concurrency/scaling after measuring the
scheduled workload. Ordinary billing alerts are warnings, not spending caps:
see [Google's budget guidance](https://docs.cloud.google.com/billing/docs/how-to/budgets).

Live recheck: both scores buckets have `r2.dev` disabled. The enabled zone rate
limit is exactly **200 origin requests / 10 seconds / IP + colo**, across both
scores and both download hosts. Cache Rules, Tiered Cache, Smart Tiered Cache
and the canonical scores guard are enabled. Production `/catalog.json` returns
200/HIT, while query-string and Origin-header variants return 403. Staging's
custom domain is disabled, so a successful staging canonical/cache smoke test
remains pending. Its query/Origin variants are blocked by the guard.

The available Cloudflare tokens receive 403 from notification policy/history
APIs, so alert existence and delivery remain **unverified**, not confirmed
absent. No automatic global cutoff was found in the inspected repository or
zone rules; account-wide automation was not audited. Cloud Run's live service
and revision limits are both 50, with request concurrency 80.

## Live status recheck — 2026-10-07

| Item | Evidence / current state |
| --- | --- |
| Domain | Registered at Hostinger; active Cloudflare zone and delegated Cloudflare nameservers |
| API-Football | Both configured keys return an active Ultra subscription and a 75,000/day allowance |
| GCP provisioning | Both projects active; Cloud Run, task queue, four scheduler jobs, runtime/deploy/scheduler accounts and exact environment-specific WIF configured |
| Firebase app configs | Active registrations for `com.thisisnsh.alldaysports` in both projects; local plist app/project IDs match |
| Backend secrets | All four latest versions enabled in both projects; R2 reads and provider status requests succeed |
| Private invocation | Each service grants invocation only to its scheduler/deploy accounts; fresh anonymous requests return 403; latest successful deployments include authenticated health smoke tests |
| Scoped IAM rollout | Runtime access on the four named secrets; deploy impersonation on runtime/default build accounts; source-bucket grants present; legacy project-wide grants absent in both projects |
| Legacy celebrations | No Firestore celebration documents, no R2 `celebrate/` objects, no obsolete celebration Remote Config parameters and no obsolete runtime database/Admin grants in either environment |
| Legacy profiles | Aggregate counts: staging 2, prod 6 `users` documents; both databases deny all client reads/writes; record fields not inspected |
| R2 exposure and credentials | Both scores domains configured; every existing bucket has `r2.dev` disabled; each backend's credentials access its own scores bucket and receive 403 on the other three existing buckets |
| Production operation | All four jobs enabled; current catalog and fixture files exist; production CDN serves cached JSON |
| Staging test readiness | Scores domain disabled; dispatch/catalog/cache-health jobs paused; schedule job enabled; June 18 catalog lacks Cache-Control and needs refreshing before CDN testing |
| GitHub environments | Both have required secrets/vars and `main` restrictions; prod has no reviewer rule |
| GitHub publication/security | App/backend repository still private; Dependabot alerts disabled; private reporting returns 404; branch protection/rulesets return a GitHub-plan 403 |
| Website | Pages built, custom domain verified, homepage/privacy HTTPS requests return 200; HTTPS enforcement false, certificate state `dns_changed`, plain HTTP returns 200 without a redirect |
| Download retirement | Both download buckets still exist; prod download domain enabled; website still links to direct downloads and uses promo media from that hostname |
| Multi-display feature | Already implemented via `SettingsPage` / `OverlayDisplayTarget` and used by overlays; physical display testing not verified |

Authenticated health was established from successful CI runs rather than a new
local impersonation call: the current user lacks Token Creator permission on
the deploy accounts. IAM was read directly and anonymous health was reprobed.
Staging's latest deployment is Oct 7 at `b2de0e3`; prod's is Oct 5 at `1971b58`.

Fresh local checks: **145 backend tests passed across 11 files**, backend/tester
TypeScript checks passed, and both npm audits reported **zero vulnerabilities**.
The initial security/Swift/secret-scan results below were not all rerun.

Unverified account steps include Apple membership/App ID capabilities, App Store
Connect/TestFlight/review status, Cloudflare notification delivery and exact
token policy metadata. Known-bucket access isolation was tested using read-only
HEAD requests; no credential write test was performed. DNS record APIs were
also denied: public apex answers are Cloudflare proxy addresses, so the intended
GitHub Pages origin records still need account-side confirmation. GCP billing
linkage/budgets were not inspected because the Cloud Billing API is disabled in
these projects; no APIs or permissions were changed to obtain access.

Before deleting download resources, migrate the website's download links and
media. Before a live staging app test, enable the intended CDN access, resume
the relevant jobs and refresh its catalog. Manual goal delivery, timing,
emergency-stop recovery, notch/external-screen behavior and peak-day provider
quota remain unverified; a deployed backend does not establish those checks.

## Initial verification and limits — revision `7f022c3`

| Check | Result |
| --- | --- |
| Backend tests | 145 passed across 11 files |
| Backend and tester TypeScript checks | Passed |
| Standalone Swift security suites | Both passed |
| Infrastructure tests | 7 passed; Python emitted temporary-file cleanup warnings |
| Backend npm audit | Initially 1 critical advisory; now fixed in source/staging as described above |
| Tester npm audit | No reported vulnerabilities |
| Gitleaks from repository root with `--log-opts=--all` | No findings; 264 non-merge commits scanned, 266 reachable commits in repository |
| Commit-message secret scan | No findings |
| OSV commit queries for all 13 Swift pins | No matching advisories; limited coverage of binary dependencies |
| GitHub visibility | Still private |
| GitHub deployment environments | Both restrict deployments to the `main` branch |

The root Gitleaks configuration allows historical Sparkle public verification
keys. A scan run from the backend directory without that root configuration
flagged those keys; they are public verification material, not signing secrets.

Reviewed safeguards include Google token verification and identity separation,
private Cloud Run configuration, exact deployment federation claims, restricted
remote URL/redirect hosts, response and image limits, score validation, bounded
match diffs, deny-all Firestore rules, and the canonical CDN path guard. The CDN
guard still permits syntactically valid nonexistent object IDs; distributed
origin-cost abuse is an existing documented residual risk, not a newly reproduced
bypass.

GitHub returned a plan-related 403 for branch protection/rulesets, so their state
could not be verified through those endpoints. Private vulnerability reporting
returned 404 while the repository is private. Recheck required CI checks and
enable private vulnerability reporting when making the repository public, so
the reporting method advertised in `SECURITY.md` is available.

No full signed app build, container OS scan, third-party binary inspection,
comprehensive license audit, exhaustive IAM/token-policy audit, telemetry
packet capture, load test, or live exploit was performed. Clean scans and passing
tests do not establish the absence of all vulnerabilities.
