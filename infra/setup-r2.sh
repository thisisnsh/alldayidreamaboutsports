#!/usr/bin/env bash
# Cloudflare R2 buckets + custom domains. Requires wrangler authenticated
# (`npx wrangler login`) against the alldayidreamaboutsports.com account.
#
# This script also runs the §0 "users hit cache, NEVER R2" enforcement checks
# (see infra/README.md and the polling-cdn plan). The catastrophe it guards
# against: clients reaching R2 directly or the edge cache breaking turns ~26
# cached reads/s into ~200,000 R2 reads/s. The checks below are the tripwires.
set -euo pipefail

# public scores buckets: fixtures-*.json, matches/*.json, celebrate/*.json, catalog.json, config.json
npx wrangler r2 bucket create alldayidreamaboutsports-staging-scores || true
npx wrangler r2 bucket create alldayidreamaboutsports-scores || true
# downloads buckets: app DMGs + appcast.xml (Sparkle feed). Staging gets its
# own so test releases never reach production's auto-update feed.
npx wrangler r2 bucket create alldayidreamaboutsports-staging-downloads || true
npx wrangler r2 bucket create alldayidreamaboutsports-downloads || true

# ── §0 (a) Disable every bucket's public r2.dev URL ──────────────────────────
# r2.dev is the bucket's managed public endpoint. It bypasses the zone Cache
# Rules entirely, so every r2.dev GET is an uncached origin read — exactly the
# failure §0 forbids. Clients must use only the scores.* custom domains, which
# sit behind the CDN. wrangler exposes this toggle, so script it.
#
# NOTE: r2.dev access is OFF by default on new buckets; this is idempotent and
# also re-disables a bucket someone enabled by hand. Re-run any time.
for bucket in \
  alldayidreamaboutsports-staging-scores \
  alldayidreamaboutsports-scores \
  alldayidreamaboutsports-staging-downloads \
  alldayidreamaboutsports-downloads; do
  echo "── Disabling public r2.dev URL on ${bucket}"
  npx wrangler r2 bucket dev-url disable "$bucket" || \
    echo "   ⚠️  Could not disable r2.dev for ${bucket}; verify it is OFF in the dashboard (R2 → ${bucket} → Settings → Public access → r2.dev)."
done

cat <<'EOF'
✅ Buckets ready and r2.dev public URLs disabled.

The remaining steps enforce the §0 cache-only invariant. Steps the current
tooling can script are run above; the rest are explicit manual checklist items
(wrangler/CF API don't expose them) — do NOT skip them, they are load-bearing.

1. Add scores custom domains (R2 → bucket → Settings → Custom Domains):
   - alldayidreamaboutsports-staging-scores → scores-staging.alldayidreamaboutsports.com
   - alldayidreamaboutsports-scores → scores.alldayidreamaboutsports.com
   - alldayidreamaboutsports-staging-downloads → download-staging.alldayidreamaboutsports.com
   - alldayidreamaboutsports-downloads → download.alldayidreamaboutsports.com
   (Custom domains route through Cloudflare's CDN: zero egress, cache enabled.)

2. ☑ §0 (d) Cache rule on BOTH scores hostnames (Rules → Cache Rules).
   JSON is NOT cached by Cloudflare by default — without this rule every app
   request reaches R2 and incurs a Class B op. This rule is load-bearing.
   Create one rule per hostname (or one rule matching both):
   - Match hostname: scores-staging.alldayidreamaboutsports.com
                 AND scores.alldayidreamaboutsports.com
   - Cache eligibility: Eligible for cache
   - Edge TTL: Use cache-control header if present, bypass cache if not
   - Browser TTL: Respect origin
   Verify after deploy with the probe in step 5 (cf-cache-status must reach
   HIT/REVALIDATED steady-state on both hosts).

3. ☑ §0 (e) Smart Tiered Caching ON — MANDATORY (per zone: Caching → Tiered
   Cache → enable "Smart Tiered Caching"). This is the difference between ~26
   R2 reads/s and ~600/s, and it absorbs the per-TTL expiry stampede by funneling
   ~300 edge data centers through ~13 regional upper tiers. Not optional.

4. ☑ §0 (b)(c) Cache-Control on every object, correct TTLs.
   The cache rule above uses cache-control if present and BYPASSES cache if not,
   so one header-less object = an origin pull on every request. The backend's R2
   write path is unit-asserted to always set Cache-Control (r2.test.ts), but any
   manual upload must carry it too. Required values (plan §3):
     matches/*.json      public, max-age=5, stale-while-revalidate=25  (live)
     celebrate/*.json    public, max-age=5, stale-while-revalidate=25  (live)
     fixtures-*.json     public, max-age=43200   (12h; 5s+SWR for dates
                         containing an eligible/live match)
     catalog.json        public, max-age=43200   (12h)
     config.json         set cache-control on manual upload (e.g. the kill-switch
                         backup), or it falls through to the BYPASS branch.
   Spot-check a live object actually carries the header:
     curl -sI https://scores-staging.alldayidreamaboutsports.com/catalog.json \
       | grep -i '^cache-control:'

5. ☑ §0 monitoring — cf-cache-status probe.
   /internal/cache-health (Cloud Scheduler every 5 min, set up by setup-gcp.sh)
   GETs a warm file + each live matches/{id}.json and asserts cf-cache-status is
   HIT/REVALIDATED steady-state. A lone MISS at a 5s boundary is normal;
   sustained MISS/BYPASS/DYNAMIC means the cache is broken (treat as sev-1).
   Manual one-off check of the header:
     curl -sI https://scores-staging.alldayidreamaboutsports.com/catalog.json \
       | grep -i '^cf-cache-status:'

6. R2 API token (Object Read & Write, all four buckets) →
   - each environment's backend secrets: r2-access-key-id / r2-secret-access-key / r2-endpoint
     (endpoint: https://<ACCOUNT_ID>.r2.cloudflarestorage.com)
   - local release env vars: R2_ENDPOINT / AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
     (R2 credentials are not GitHub secrets)

7. The website is hosted from the separate public GitHub Pages repo documented
   in infra/README.md, not from this repository or Cloudflare Pages.
EOF
