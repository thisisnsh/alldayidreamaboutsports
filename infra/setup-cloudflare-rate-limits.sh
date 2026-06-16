#!/usr/bin/env bash
# Cloudflare WAF rate limiting for the R2 custom domains.
#
# Requires:
#   CLOUDFLARE_API_TOKEN  token with Zone WAF Write or Zone Rulesets Write
#   CLOUDFLARE_ZONE_ID    zone id for alldayidreamaboutsports.com
#
# Optional overrides:
#   SCORES_RATE_LIMIT_REQUESTS_PER_MINUTE=600
#   SCORES_ORIGIN_RATE_LIMIT_REQUESTS_PER_MINUTE=120
#   DOWNLOAD_RATE_LIMIT_REQUESTS_PER_MINUTE=120
#   RATE_LIMIT_MITIGATION_TIMEOUT_SECONDS=60
set -euo pipefail

: "${CLOUDFLARE_API_TOKEN:?set CLOUDFLARE_API_TOKEN}"
: "${CLOUDFLARE_ZONE_ID:?set CLOUDFLARE_ZONE_ID}"

API_BASE="https://api.cloudflare.com/client/v4"
PHASE="http_ratelimit"

SCORES_RATE_LIMIT_REQUESTS_PER_MINUTE="${SCORES_RATE_LIMIT_REQUESTS_PER_MINUTE:-600}"
SCORES_ORIGIN_RATE_LIMIT_REQUESTS_PER_MINUTE="${SCORES_ORIGIN_RATE_LIMIT_REQUESTS_PER_MINUTE:-120}"
DOWNLOAD_RATE_LIMIT_REQUESTS_PER_MINUTE="${DOWNLOAD_RATE_LIMIT_REQUESTS_PER_MINUTE:-120}"
RATE_LIMIT_MITIGATION_TIMEOUT_SECONDS="${RATE_LIMIT_MITIGATION_TIMEOUT_SECONDS:-60}"

SCORES_HOSTS=(
  "scores-staging.alldayidreamaboutsports.com"
  "scores.alldayidreamaboutsports.com"
)
DOWNLOAD_HOSTS=(
  "download-staging.alldayidreamaboutsports.com"
  "download.alldayidreamaboutsports.com"
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
  if [[ -n "$body" ]]; then
    curl -fsS "${API_BASE}${path}" \
      --request "$method" \
      --header "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
      --header "Content-Type: application/json" \
      --data "$body"
  else
    curl -fsS "${API_BASE}${path}" \
      --request "$method" \
      --header "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}"
  fi
}

cf_get_entrypoint() {
  local body_file status
  body_file="$(mktemp)"
  status="$(
    curl -sS -o "$body_file" -w "%{http_code}" \
      "${API_BASE}/zones/${CLOUDFLARE_ZONE_ID}/rulesets/phases/${PHASE}/entrypoint" \
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
  echo "Cloudflare API returned HTTP ${status}" >&2
  exit 1
}

host_expression() {
  jq -nr --args "$@" '"(http.host in {" + ([$ARGS.positional[] | @json] | join(" ")) + "})"'
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
        period: 60,
        requests_per_period: $requestsPerPeriod,
        mitigation_timeout: $mitigationTimeout
      }
    }
    | if $requestsToOrigin then .ratelimit.requests_to_origin = true else . end'
}

require_tool curl
require_tool jq

scores_expression="$(host_expression "${SCORES_HOSTS[@]}")"
downloads_expression="$(host_expression "${DOWNLOAD_HOSTS[@]}")"

managed_rules="$(
  jq -s '.' \
    <(rate_limit_rule \
      "allday_scores_cdn_rate_limit" \
      "Rate limit scores CDN requests per IP/colo" \
      "$scores_expression" \
      "$SCORES_RATE_LIMIT_REQUESTS_PER_MINUTE") \
    <(rate_limit_rule \
      "allday_scores_r2_origin_rate_limit" \
      "Rate limit scores R2 origin reads per IP/colo" \
      "$scores_expression" \
      "$SCORES_ORIGIN_RATE_LIMIT_REQUESTS_PER_MINUTE" \
      true) \
    <(rate_limit_rule \
      "allday_downloads_cdn_rate_limit" \
      "Rate limit downloads CDN requests per IP/colo" \
      "$downloads_expression" \
      "$DOWNLOAD_RATE_LIMIT_REQUESTS_PER_MINUTE")
)"

if entrypoint="$(cf_get_entrypoint)"; then
  ruleset_id="$(jq -r '.result.id' <<<"$entrypoint")"
  existing_rules="$(jq '.result.rules // []' <<<"$entrypoint")"
  preserved_rules="$(
    jq \
      --argjson refs '["allday_scores_cdn_rate_limit", "allday_scores_r2_origin_rate_limit", "allday_downloads_cdn_rate_limit"]' \
      '[.[] | select((.ref // "") as $ref | ($refs | index($ref) | not))]' \
      <<<"$existing_rules"
  )"
  payload="$(
    jq -n \
      --arg name "$(jq -r '.result.name // "R2 custom domain rate limits"' <<<"$entrypoint")" \
      --arg description "Rate limits for R2 custom domains" \
      --arg phase "$PHASE" \
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
  echo "── Updating Cloudflare ${PHASE} entrypoint ruleset ${ruleset_id}"
  cf_api PUT "/zones/${CLOUDFLARE_ZONE_ID}/rulesets/${ruleset_id}" "$payload" >/dev/null
else
  payload="$(
    jq -n \
      --arg phase "$PHASE" \
      --argjson managed "$managed_rules" \
      '{
        name: "R2 custom domain rate limits",
        description: "Rate limits for R2 custom domains",
        kind: "zone",
        phase: $phase,
        rules: $managed
      }'
  )"
  echo "── Creating Cloudflare ${PHASE} entrypoint ruleset"
  cf_api POST "/zones/${CLOUDFLARE_ZONE_ID}/rulesets" "$payload" >/dev/null
fi

cat <<EOF
✅ Cloudflare R2 custom-domain rate limits applied.

Rules:
- scores CDN: ${SCORES_RATE_LIMIT_REQUESTS_PER_MINUTE}/minute per IP + colo
- scores R2 origin reads: ${SCORES_ORIGIN_RATE_LIMIT_REQUESTS_PER_MINUTE}/minute per IP + colo, counting origin requests only
- downloads CDN: ${DOWNLOAD_RATE_LIMIT_REQUESTS_PER_MINUTE}/minute per IP + colo
- mitigation timeout: ${RATE_LIMIT_MITIGATION_TIMEOUT_SECONDS}s
EOF
