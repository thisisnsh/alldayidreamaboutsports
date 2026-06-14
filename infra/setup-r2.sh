#!/usr/bin/env bash
# Cloudflare R2 buckets + custom domains. Requires wrangler authenticated
# (`npx wrangler login`) against the alldayidreamaboutsports.com account.
set -euo pipefail

# public scores buckets: fixtures-*.json, celebrate/*.json, catalog.json, config.json
npx wrangler r2 bucket create alldayidreamaboutsports-staging-scores || true
npx wrangler r2 bucket create alldayidreamaboutsports-scores || true
# downloads bucket: app DMGs + appcast.xml (Sparkle feed)
npx wrangler r2 bucket create alldayidreamaboutsports-downloads || true

cat <<'EOF'
✅ Buckets ready. Finish in the Cloudflare dashboard (one-time):

1. Add scores custom domains:
   - alldayidreamaboutsports-staging-scores → scores-staging.alldayidreamaboutsports.com
   - alldayidreamaboutsports-scores → scores.alldayidreamaboutsports.com
2. R2 → alldayidreamaboutsports-downloads → Settings → Custom Domains → download.alldayidreamaboutsports.com
   (Custom domains route through Cloudflare's CDN: zero egress, cache enabled.)
3. Cache rules (Rules → Cache Rules):
   - Match hostname: scores-staging.alldayidreamaboutsports.com or scores.alldayidreamaboutsports.com
   - Cache eligibility: Eligible for cache
   - Edge TTL: Use cache-control header if present, bypass cache if not
   - Browser TTL: Respect origin
   JSON is not cached by default, so this rule is required. Clients use only
   these custom domains; disable the buckets' public r2.dev URLs.
   Backend objects carry their own cache-control TTLs: fixtures-*=10s,
   celebrate/*=2s, catalog.json=1d. Manually uploaded config.json
   is only cached when uploaded with cache-control metadata.
4. R2 API token (Object Read & Write, all three buckets) →
   - each environment's backend secrets: r2-access-key-id / r2-secret-access-key / r2-endpoint
     (endpoint: https://<ACCOUNT_ID>.r2.cloudflarestorage.com)
   - local release env vars: R2_ENDPOINT / AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
     (R2 credentials are not GitHub secrets)
5. The website is hosted from the separate public GitHub Pages repo documented
   in infra/README.md, not from this repository or Cloudflare Pages.
EOF
