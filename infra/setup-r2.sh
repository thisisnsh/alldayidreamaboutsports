#!/usr/bin/env bash
# Cloudflare R2 buckets, custom domains, CDN cache rules, Smart Tiered Cache,
# and WAF rate limits.
#
# Bucket creation uses wrangler because it is the most stable R2 bucket create
# surface. The Cloudflare API configures the zone/bucket edge controls.
#
# Required for bucket creation:
#   npx wrangler login
#   Bucket creation intentionally ignores CLOUDFLARE_API_TOKEN so wrangler uses
#   your browser login instead of the narrower setup token.
#
# Required for full Cloudflare API automation:
#   CLOUDFLARE_API_TOKEN  token with R2 edit, Zone Settings Write, Cache Rules
#                         Edit, and WAF/Rulesets edit permissions
#   CLOUDFLARE_ACCOUNT_ID account that owns the R2 buckets
#   CLOUDFLARE_ZONE_ID    zone id for alldayidreamaboutsports.com
#
# Optional limit overrides:
#   R2_ORIGIN_RATE_LIMIT_REQUESTS_PER_10_SECONDS=200
#   RATE_LIMIT_MITIGATION_TIMEOUT_SECONDS=10
set -euo pipefail

API_BASE="https://api.cloudflare.com/client/v4"

R2_ORIGIN_RATE_LIMIT_REQUESTS_PER_10_SECONDS="${R2_ORIGIN_RATE_LIMIT_REQUESTS_PER_10_SECONDS:-200}"
RATE_LIMIT_MITIGATION_TIMEOUT_SECONDS="${RATE_LIMIT_MITIGATION_TIMEOUT_SECONDS:-10}"

SCORES_HOSTS=(
  "scores-staging.alldayidreamaboutsports.com"
  "scores.alldayidreamaboutsports.com"
)
BUCKET_DOMAIN_PAIRS=(
  "alldayidreamaboutsports-staging-scores:scores-staging.alldayidreamaboutsports.com"
  "alldayidreamaboutsports-scores:scores.alldayidreamaboutsports.com"
)

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required tool: $1" >&2
    exit 1
  fi
}

cf_api() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  local response_file status

  response_file="$(mktemp)"
  if [[ -n "$body" ]]; then
    status="$(
      curl -sS -o "$response_file" -w "%{http_code}" "${API_BASE}${path}" \
      --request "$method" \
      --header "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
      --header "Content-Type: application/json" \
      --data "$body"
    )"
  else
    status="$(
      curl -sS -o "$response_file" -w "%{http_code}" "${API_BASE}${path}" \
      --request "$method" \
      --header "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}"
    )"
  fi

  if [[ "$status" =~ ^2 ]]; then
    cat "$response_file"
    rm -f "$response_file"
    return 0
  fi

  echo "Cloudflare API ${method} ${path} returned HTTP ${status}" >&2
  cat "$response_file" >&2
  rm -f "$response_file"
  exit 1
}

wrangler() {
  env -u CLOUDFLARE_API_TOKEN npx wrangler "$@"
}

create_bucket() {
  local bucket="$1"
  local output

  echo "── Ensuring R2 bucket ${bucket}"
  if output="$(wrangler r2 bucket create "$bucket" 2>&1)"; then
    printf '%s\n' "$output"
    return 0
  fi

  if grep -q "already exists, and you own it" <<<"$output"; then
    echo "   Bucket already exists."
    return 0
  fi

  printf '%s\n' "$output" >&2
  return 1
}

cf_get_entrypoint() {
  local phase="$1"
  local body_file status
  body_file="$(mktemp)"
  status="$(
    curl -sS -o "$body_file" -w "%{http_code}" \
      "${API_BASE}/zones/${CLOUDFLARE_ZONE_ID}/rulesets/phases/${phase}/entrypoint" \
      --request GET \
      --header "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}"
  )"
  if [[ "$status" == "200" ]]; then
    cat "$body_file"
    rm -f "$body_file"
    return 0
  fi
  if [[ "$status" == "404" ]]; then
    rm -f "$body_file"
    return 1
  fi
  cat "$body_file" >&2
  rm -f "$body_file"
  echo "Cloudflare API returned HTTP ${status} for ${phase} entrypoint" >&2
  exit 1
}

host_expression() {
  jq -nr '"(http.host in {" + ([$ARGS.positional[] | @json] | join(" ")) + "})"' --args "$@"
}

ensure_ruleset() {
  local phase="$1"
  local name="$2"
  local description="$3"
  local managed_refs="$4"
  local managed_rules="$5"
  local entrypoint ruleset_id existing_rules preserved_rules payload

  if entrypoint="$(cf_get_entrypoint "$phase")"; then
    ruleset_id="$(jq -r '.result.id' <<<"$entrypoint")"
    existing_rules="$(jq '.result.rules // []' <<<"$entrypoint")"
    preserved_rules="$(
      jq \
        --argjson refs "$managed_refs" \
        '[.[] | select((.ref // "") as $ref | ($refs | index($ref) | not))]' \
        <<<"$existing_rules"
    )"
    payload="$(
      jq -n \
        --arg name "$(jq -r --arg fallback "$name" '.result.name // $fallback' <<<"$entrypoint")" \
        --arg description "$description" \
        --arg phase "$phase" \
        --argjson preserved "$preserved_rules" \
        --argjson managed "$managed_rules" \
        '{
          name: $name,
          description: $description,
          kind: "zone",
          phase: $phase,
          rules: ($preserved + $managed)
        }'
    )"
    echo "── Updating Cloudflare ${phase} entrypoint ruleset ${ruleset_id}"
    cf_api PUT "/zones/${CLOUDFLARE_ZONE_ID}/rulesets/${ruleset_id}" "$payload" >/dev/null
  else
    payload="$(
      jq -n \
        --arg name "$name" \
        --arg description "$description" \
        --arg phase "$phase" \
        --argjson managed "$managed_rules" \
        '{
          name: $name,
          description: $description,
          kind: "zone",
          phase: $phase,
          rules: $managed
        }'
    )"
    echo "── Creating Cloudflare ${phase} entrypoint ruleset"
    cf_api POST "/zones/${CLOUDFLARE_ZONE_ID}/rulesets" "$payload" >/dev/null
  fi
}

cache_rule() {
  local ref="$1"
  local description="$2"
  local expression="$3"

  jq -n \
    --arg ref "$ref" \
    --arg description "$description" \
    --arg expression "$expression" \
    '{
      ref: $ref,
      description: $description,
      expression: $expression,
      action: "set_cache_settings",
      action_parameters: {
        cache: true,
        edge_ttl: { mode: "bypass_by_default" },
        browser_ttl: { mode: "respect_origin" }
      }
    }'
}

rate_limit_rule() {
  local ref="$1"
  local description="$2"
  local expression="$3"
  local requests_per_period="$4"
  local requests_to_origin="${5:-false}"

  jq -n \
    --arg ref "$ref" \
    --arg description "$description" \
    --arg expression "$expression" \
    --argjson requestsPerPeriod "$requests_per_period" \
    --argjson mitigationTimeout "$RATE_LIMIT_MITIGATION_TIMEOUT_SECONDS" \
    --argjson requestsToOrigin "$requests_to_origin" \
    '{
      ref: $ref,
      description: $description,
      expression: $expression,
      action: "block",
      action_parameters: {
        response: {
          status_code: 429,
          content: "rate limited\n",
          content_type: "text/plain"
        }
      },
      ratelimit: {
        characteristics: ["ip.src", "cf.colo.id"],
        period: 10,
        requests_per_period: $requestsPerPeriod,
        mitigation_timeout: $mitigationTimeout
      }
    }
    | if $requestsToOrigin then .ratelimit.requests_to_origin = true else . end'
}

r2_custom_domain_exists() {
  local bucket="$1"
  local domain="$2"

  cf_api GET "/accounts/${CLOUDFLARE_ACCOUNT_ID}/r2/buckets/${bucket}/domains/custom" \
    | jq -e --arg domain "$domain" '.result.domains[]? | select(.domain == $domain)' >/dev/null
}

attach_r2_custom_domain() {
  local bucket="$1"
  local domain="$2"
  local payload

  payload="$(
    jq -n \
      --arg domain "$domain" \
      --arg zoneId "$CLOUDFLARE_ZONE_ID" \
      '{ domain: $domain, enabled: true, zoneId: $zoneId, minTLS: "1.2" }'
  )"
  if r2_custom_domain_exists "$bucket" "$domain"; then
    echo "── Updating R2 custom domain ${domain} → ${bucket}"
    cf_api PUT "/accounts/${CLOUDFLARE_ACCOUNT_ID}/r2/buckets/${bucket}/domains/custom/${domain}" "$payload" >/dev/null
  else
    echo "── Attaching R2 custom domain ${domain} → ${bucket}"
    cf_api POST "/accounts/${CLOUDFLARE_ACCOUNT_ID}/r2/buckets/${bucket}/domains/custom" "$payload" >/dev/null
  fi
}

disable_r2_dev_url() {
  local bucket="$1"

  echo "── Disabling public r2.dev URL on ${bucket}"
  if [[ -n "${CLOUDFLARE_API_TOKEN:-}" && -n "${CLOUDFLARE_ACCOUNT_ID:-}" ]]; then
    local payload
    payload="$(jq -n '{ enabled: false }')"
    cf_api PUT "/accounts/${CLOUDFLARE_ACCOUNT_ID}/r2/buckets/${bucket}/domains/managed" "$payload" >/dev/null
  else
    wrangler r2 bucket dev-url disable "$bucket" || \
      echo "   WARNING: Could not disable r2.dev for ${bucket}; verify it is OFF in the dashboard."
  fi
}

configure_cloudflare_zone() {
  local scores_expression cache_refs cache_rules rate_refs rate_rules

  : "${CLOUDFLARE_API_TOKEN:?set CLOUDFLARE_API_TOKEN for Cloudflare API setup}"
  : "${CLOUDFLARE_ACCOUNT_ID:?set CLOUDFLARE_ACCOUNT_ID for R2 custom-domain setup}"
  : "${CLOUDFLARE_ZONE_ID:?set CLOUDFLARE_ZONE_ID for zone cache/rate-limit setup}"
  require_tool curl
  require_tool jq

  for pair in "${BUCKET_DOMAIN_PAIRS[@]}"; do
    attach_r2_custom_domain "${pair%%:*}" "${pair#*:}"
  done

  scores_expression="$(host_expression "${SCORES_HOSTS[@]}")"

  cache_refs='["allday_scores_cache_settings"]'
  cache_rules="$(
    jq -s '.' \
      <(cache_rule \
        "allday_scores_cache_settings" \
        "Cache scores R2 JSON only when objects carry Cache-Control" \
        "$scores_expression")
  )"
  ensure_ruleset \
    "http_request_cache_settings" \
    "R2 custom domain cache settings" \
    "Cache settings for R2 custom domains" \
    "$cache_refs" \
    "$cache_rules"

  echo "── Enabling Tiered Cache"
  cf_api PATCH "/zones/${CLOUDFLARE_ZONE_ID}/argo/tiered_caching" '{"value":"on"}' >/dev/null
  echo "── Enabling Smart Tiered Cache topology"
  cf_api PATCH "/zones/${CLOUDFLARE_ZONE_ID}/cache/tiered_cache_smart_topology_enable" '{"value":"on"}' >/dev/null

  rate_refs='["allday_r2_origin_rate_limit"]'
  rate_rules="$(
    jq -s '.' \
      <(rate_limit_rule \
        "allday_r2_origin_rate_limit" \
        "Rate limit R2 origin reads for scores per IP/colo" \
        "$scores_expression" \
        "$R2_ORIGIN_RATE_LIMIT_REQUESTS_PER_10_SECONDS" \
        true)
  )"
  ensure_ruleset \
    "http_ratelimit" \
    "R2 custom domain rate limits" \
    "Rate limits for R2 custom domains" \
    "$rate_refs" \
    "$rate_rules"
}

require_tool npx

# public scores buckets: fixtures-*.json, matches/*.json, catalog.json
create_bucket alldayidreamaboutsports-staging-scores
create_bucket alldayidreamaboutsports-scores

for pair in "${BUCKET_DOMAIN_PAIRS[@]}"; do
  disable_r2_dev_url "${pair%%:*}"
done

if [[ -n "${CLOUDFLARE_API_TOKEN:-}" || -n "${CLOUDFLARE_ACCOUNT_ID:-}" || -n "${CLOUDFLARE_ZONE_ID:-}" ]]; then
  configure_cloudflare_zone
  python3 "$(dirname "$0")/secure_scores.py" --apply
  cat <<EOF
✅ Cloudflare R2/CDN setup complete.

Configured:
- R2 buckets
- R2 custom domains
- r2.dev disabled
- Cache Rules for scores hostnames
- Tiered Cache + Smart Tiered Cache topology
- WAF rate limits for scores hostnames

Rate limits:
- R2 origin reads: ${R2_ORIGIN_RATE_LIMIT_REQUESTS_PER_10_SECONDS}/10s per IP + colo across scores hosts, origin requests only
- mitigation timeout: ${RATE_LIMIT_MITIGATION_TIMEOUT_SECONDS}s

Verify after objects are uploaded:
  curl -sS -D - -o /dev/null https://scores-staging.alldayidreamaboutsports.com/catalog.json | grep -iE '^(cache-control|cf-cache-status):'
EOF
else
  cat <<'EOF'
✅ Buckets ready and r2.dev public URLs disabled.

Cloudflare API setup skipped because CLOUDFLARE_API_TOKEN,
CLOUDFLARE_ACCOUNT_ID, and CLOUDFLARE_ZONE_ID were not provided.

Run this script again with those variables to create the R2 custom domains,
cache rules, Smart Tiered Cache settings, and WAF rate limits:

  CLOUDFLARE_API_TOKEN=<token> \
  CLOUDFLARE_ACCOUNT_ID=<account-id> \
  CLOUDFLARE_ZONE_ID=<zone-id> \
  ./infra/setup-r2.sh
EOF
fi
