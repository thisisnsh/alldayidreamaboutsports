#!/usr/bin/env bash
# Creates/updates only the isolated sports-push resources. Existing backend resources are never targeted.
set -euo pipefail
cd "$(dirname "$0")/.."
PUSH_PROJECT="${1:?usage: deploy.sh PROJECT REGION APNS_KEY_ID FIREBASE_APP_ID sandbox|production}"
PUSH_REGION="${2:?missing region}"
PUSH_KEY_ID="${3:?missing Apple APNs Key ID}"
PUSH_APP_ID="${4:?missing Firebase Apple app ID}"
PUSH_APNS_ENV="${5:?missing sandbox|production}"
case "$PUSH_PROJECT" in
  dreamaboutsports-staging) PUSH_CDN="https://scores-staging.alldayidreamaboutsports.com" ;;
  dreamaboutsports-prod) PUSH_CDN="https://scores.alldayidreamaboutsports.com" ;;
  *) echo "Use an explicit staging/prod project from this repository." >&2; exit 1 ;;
esac
case "$PUSH_APNS_ENV" in sandbox|production) ;; *) exit 1 ;; esac
# A staging Access policy must not be bypassed: optionally use the public production
# CDN read-only for staging device checks (the native app must use the same scores origin).
PUSH_CDN="${PUSH_SCORES_ORIGIN:-$PUSH_CDN}"
case "$PUSH_CDN" in https://scores.alldayidreamaboutsports.com|https://scores-staging.alldayidreamaboutsports.com) ;; *) exit 1 ;; esac
PUSH_SERVICE=sports-cdn-push
PUSH_DATABASE=sports-push
PUSH_QUEUE=sports-push
PUSH_RUNTIME="sports-push-runtime@${PUSH_PROJECT}.iam.gserviceaccount.com"
PUSH_INVOKER="sports-push-invoker@${PUSH_PROJECT}.iam.gserviceaccount.com"
PUSH_SECRET=sports-push-apns-key
# Fail before resource mutations if the key has not been installed. Never retrieve/print the secret.
gcloud secrets versions describe latest --secret "$PUSH_SECRET" --project "$PUSH_PROJECT" --format='value(state)' | grep -q '^ENABLED$'
gcloud services enable run.googleapis.com cloudbuild.googleapis.com artifactregistry.googleapis.com \
  cloudtasks.googleapis.com cloudscheduler.googleapis.com firestore.googleapis.com \
  secretmanager.googleapis.com firebaseappcheck.googleapis.com firebaserules.googleapis.com --project "$PUSH_PROJECT"
for PUSH_SA in sports-push-runtime sports-push-invoker; do
  if ! gcloud iam service-accounts describe "${PUSH_SA}@${PUSH_PROJECT}.iam.gserviceaccount.com" --project "$PUSH_PROJECT" >/dev/null 2>&1; then
    gcloud iam service-accounts create "$PUSH_SA" --project "$PUSH_PROJECT"
  fi
done
if ! gcloud firestore databases describe --database "$PUSH_DATABASE" --project "$PUSH_PROJECT" >/dev/null 2>&1; then
  gcloud firestore databases create --database "$PUSH_DATABASE" --location "$PUSH_REGION" --type firestore-native --project "$PUSH_PROJECT"
fi
# Restrict the new runtime's database rights to its own named database.
gcloud projects add-iam-policy-binding "$PUSH_PROJECT" --member "serviceAccount:${PUSH_RUNTIME}" \
  --role roles/datastore.user --condition "expression=resource.name==\"projects/${PUSH_PROJECT}/databases/${PUSH_DATABASE}\",title=sports-push-only" >/dev/null
# This config names sports-push, never (default). It does not deploy existing application rules.
npx --yes firebase-tools@15.34.1 deploy --only firestore:sports-push --config infra/firebase.json --project "$PUSH_PROJECT" --non-interactive
for PUSH_COLLECTION in installations matches transitions deliveries registrationBudgets; do
  gcloud firestore fields ttls update deleteAfter --collection-group "$PUSH_COLLECTION" \
    --database "$PUSH_DATABASE" --enable-ttl --project "$PUSH_PROJECT" --async >/dev/null
done
if ! gcloud tasks queues describe "$PUSH_QUEUE" --location "$PUSH_REGION" --project "$PUSH_PROJECT" >/dev/null 2>&1; then
  gcloud tasks queues create "$PUSH_QUEUE" --location "$PUSH_REGION" --project "$PUSH_PROJECT"
fi
gcloud tasks queues update "$PUSH_QUEUE" --location "$PUSH_REGION" --project "$PUSH_PROJECT" \
  --max-concurrent-dispatches 1 --max-dispatches-per-second 1 --max-attempts 3 --min-backoff 5s --max-backoff 30s
# Queue-local permission: the new service cannot enqueue work for the existing scores backend.
gcloud tasks queues add-iam-policy-binding "$PUSH_QUEUE" --location "$PUSH_REGION" --project "$PUSH_PROJECT" \
  --member "serviceAccount:${PUSH_RUNTIME}" --role roles/cloudtasks.enqueuer >/dev/null
gcloud iam service-accounts add-iam-policy-binding "$PUSH_INVOKER" --project "$PUSH_PROJECT" \
  --member "serviceAccount:${PUSH_RUNTIME}" --role roles/iam.serviceAccountUser >/dev/null
gcloud secrets add-iam-policy-binding "$PUSH_SECRET" --project "$PUSH_PROJECT" \
  --member "serviceAccount:${PUSH_RUNTIME}" --role roles/secretmanager.secretAccessor >/dev/null
if ! gcloud artifacts repositories describe sports-push --location "$PUSH_REGION" --project "$PUSH_PROJECT" >/dev/null 2>&1; then
  gcloud artifacts repositories create sports-push --repository-format docker --location "$PUSH_REGION" --project "$PUSH_PROJECT"
fi
PUSH_NUMBER=$(gcloud projects describe "$PUSH_PROJECT" --format='value(projectNumber)')
PUSH_URL="https://${PUSH_SERVICE}-${PUSH_NUMBER}.${PUSH_REGION}.run.app"
PUSH_ENV_FILE=$(mktemp)
trap 'rm -f "$PUSH_ENV_FILE"' EXIT
python3 - "$PUSH_ENV_FILE" "$PUSH_PROJECT" "$PUSH_REGION" "$PUSH_URL" "$PUSH_CDN" "$PUSH_INVOKER" "$PUSH_KEY_ID" "$PUSH_APP_ID" "$PUSH_APNS_ENV" <<'PY'
import json, sys
path, project, region, url, cdn, invoker, key_id, app_id, apns_env = sys.argv[1:]
with open(path, 'w') as f:
    json.dump(dict(GCP_PROJECT_ID=project, SERVICE_URL=url, SCORES_ORIGIN=cdn,
        INVOKER_EMAIL=invoker, TASKS_LOCATION=region, TASKS_QUEUE='sports-push',
        FIRESTORE_DATABASE='sports-push', FIREBASE_APP_IDS=app_id,
        APNS_TEAM_ID='983LBM5U6B', APNS_KEY_ID=key_id, APNS_ENVIRONMENT=apns_env,
        APNS_BUNDLE_ID='com.thisisnsh.alldaysports', DRY_RUN='true', POLL_SECONDS='5'), f)
PY
# Public registration is App Check + device-secret authenticated. Internal routes additionally require OIDC.
gcloud run deploy "$PUSH_SERVICE" --source . --project "$PUSH_PROJECT" --region "$PUSH_REGION" \
  --service-account "$PUSH_RUNTIME" --allow-unauthenticated --min-instances 0 --max-instances 2 \
  --cpu 1 --memory 512Mi --concurrency 20 --timeout 120 --env-vars-file "$PUSH_ENV_FILE" \
  --set-secrets "APNS_PRIVATE_KEY=${PUSH_SECRET}:latest"
PUSH_URL=$(gcloud run services describe "$PUSH_SERVICE" --project "$PUSH_PROJECT" --region "$PUSH_REGION" --format='value(status.url)')
gcloud run services update "$PUSH_SERVICE" --project "$PUSH_PROJECT" --region "$PUSH_REGION" --update-env-vars "SERVICE_URL=${PUSH_URL}"
if gcloud scheduler jobs describe sports-push-dispatch --location "$PUSH_REGION" --project "$PUSH_PROJECT" >/dev/null 2>&1; then
  PUSH_JOB_ACTION=update
else
  PUSH_JOB_ACTION=create
fi
gcloud scheduler jobs "$PUSH_JOB_ACTION" http sports-push-dispatch --project "$PUSH_PROJECT" --location "$PUSH_REGION" \
  --schedule '* * * * *' --time-zone UTC --uri "${PUSH_URL}/internal/dispatch" --http-method POST \
  --oidc-service-account-email "$PUSH_INVOKER" --oidc-token-audience "$PUSH_URL" --attempt-deadline 120s
gcloud scheduler jobs pause sports-push-dispatch --project "$PUSH_PROJECT" --location "$PUSH_REGION"
printf 'Push service prepared in dry-run mode; scheduler paused. URL: %s\n' "$PUSH_URL"
printf 'Complete the physical-device checks in push/README.md before enabling sends.\n'
