#!/usr/bin/env bash
# Cloudflare R2 buckets + custom domains. Requires wrangler authenticated
# (`npx wrangler login`) against the alldayidreamaboutsports.com account.
set -euo pipefail

# scores bucket: live.json, fixtures-*.json, celebrate/*.json, config.json, teams.json
npx wrangler r2 bucket create alldayidreamaboutsports-scores || true
# downloads bucket: app zips + appcast.xml (Sparkle feed)
npx wrangler r2 bucket create alldayidreamaboutsports-downloads || true

cat <<'EOF'
✅ Buckets ready. Finish in the Cloudflare dashboard (one-time):

1. R2 → alldayidreamaboutsports-scores → Settings → Custom Domains → scores.alldayidreamaboutsports.com
2. R2 → alldayidreamaboutsports-downloads → Settings → Custom Domains → download.alldayidreamaboutsports.com
   (Custom domains route through Cloudflare's CDN: zero egress, cache enabled.)
3. Cache rules (Rules → Cache Rules):
   - scores.../live.json + celebrate/*  → Edge TTL: respect origin (objects are
     uploaded with cache-control; live.json=20s, celebrate=2s, fixtures=1h)
4. R2 API token (Object Read & Write, both buckets) →
   - backend secrets: r2-access-key-id / r2-secret-access-key / r2-endpoint
     (endpoint: https://<ACCOUNT_ID>.r2.cloudflarestorage.com)
   - GitHub secrets: R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY / R2_ENDPOINT
5. Website is hosted on GitHub Pages (see .github/workflows/web-deploy.yml),
   NOT Cloudflare Pages. DNS: apex A records → GitHub Pages IPs (185.199.108.153
   /109/110/111) or CNAME flattening to thisisnsh.github.io.
EOF
