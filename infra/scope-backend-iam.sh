#!/usr/bin/env bash
# Grant resource-scoped replacements before removing legacy project-wide grants.
# Default is read-only planning; --apply performs the printed changes.
set -euo pipefail
PROJECT_ID="${1:?usage: scope-backend-iam.sh <project> <region> [--plan|--apply]}"
REGION="${2:?usage: scope-backend-iam.sh <project> <region> [--plan|--apply]}"
MODE="${3:---plan}"
case "$MODE" in --plan|--apply) ;; *) echo "Invalid mode" >&2; exit 1 ;; esac
RUNTIME_SA="sports-runtime@${PROJECT_ID}.iam.gserviceaccount.com"
DEPLOY_SA="sports-deploy@${PROJECT_ID}.iam.gserviceaccount.com"
BUILD_SA=$(gcloud builds get-default-service-account --project "$PROJECT_ID" --region "$REGION")
BUILD_SA="${BUILD_SA##*/}"
[[ "$BUILD_SA" == *@*.gserviceaccount.com ]] || { echo "Cannot resolve build identity" >&2; exit 1; }
SOURCE_BUCKET="gs://run-sources-${PROJECT_ID}-${REGION}"
POLICY=$(gcloud projects get-iam-policy "$PROJECT_ID" --format=json)

run() {
  if [[ "$MODE" == --apply ]]; then "$@" >/dev/null
  else printf '%q ' "$@"; printf '\n'; fi
}

# Preflight every required secret and account before any mutation.
for secret in api-football-key r2-access-key-id r2-secret-access-key r2-endpoint; do
  gcloud secrets describe "$secret" --project "$PROJECT_ID" >/dev/null
done
for identity in "$RUNTIME_SA" "$DEPLOY_SA" "$BUILD_SA"; do
  gcloud iam service-accounts describe "$identity" --project "$PROJECT_ID" >/dev/null
done
# setup-gcp.sh creates the source bucket before invoking this script.
gcloud storage buckets describe "$SOURCE_BUCKET" >/dev/null

for secret in api-football-key r2-access-key-id r2-secret-access-key r2-endpoint; do
  run gcloud secrets add-iam-policy-binding "$secret" --project "$PROJECT_ID" \
    --member "serviceAccount:$RUNTIME_SA" --role roles/secretmanager.secretAccessor --condition=None --quiet
done
for identity in "$RUNTIME_SA" "$BUILD_SA"; do
  run gcloud iam service-accounts add-iam-policy-binding "$identity" --project "$PROJECT_ID" \
    --member "serviceAccount:$DEPLOY_SA" --role roles/iam.serviceAccountUser --condition=None --quiet
done
for role in roles/storage.objectAdmin roles/storage.legacyBucketReader; do
  run gcloud storage buckets add-iam-policy-binding "$SOURCE_BUCKET" \
    --member "serviceAccount:$DEPLOY_SA" --role "$role" --quiet
done

remove_legacy() {
  local identity="$1" role="$2"
  if jq -e --arg member "serviceAccount:$identity" --arg role "$role" \
    '.bindings[] | select(.role == $role and .condition == null) | .members[] | select(. == $member)' \
    <<<"$POLICY" >/dev/null; then
    run gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
      --member "serviceAccount:$identity" --role "$role" --condition=None --quiet
  fi
}
remove_legacy "$RUNTIME_SA" roles/secretmanager.secretAccessor
remove_legacy "$DEPLOY_SA" roles/iam.serviceAccountUser
remove_legacy "$DEPLOY_SA" roles/storage.admin
echo "IAM scope ${MODE#--} complete. Verify the next staging deployment before promoting."
