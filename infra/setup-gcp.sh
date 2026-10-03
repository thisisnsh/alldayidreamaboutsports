#!/usr/bin/env bash
# One-time GCP setup per environment. Run twice: staging and prod.
#
#   ./setup-gcp.sh dreamaboutsports-staging us-central1
#
# Prereqs: gcloud CLI authenticated as project owner; billing linked.
set -euo pipefail

PROJECT_ID="${1:?usage: setup-gcp.sh <project-id> <region>}"
REGION="${2:?usage: setup-gcp.sh <project-id> <region>}"
SERVICE="alldayidreamaboutsports-backend"

# Scores CDN hostname for this environment (the cf-cache-status probe targets it).
# Derived from the project id so staging and prod stay in sync with the R2 custom
# domains in infra/README.md.
case "$PROJECT_ID" in
  *staging*) SCORES_DOMAIN="https://scores-staging.alldayidreamaboutsports.com" ;;
  *)         SCORES_DOMAIN="https://scores.alldayidreamaboutsports.com" ;;
esac

gcloud config set project "$PROJECT_ID"

echo "── Enabling APIs"
gcloud services enable \
  run.googleapis.com \
  cloudbuild.googleapis.com \
  cloudscheduler.googleapis.com \
  cloudtasks.googleapis.com \
  secretmanager.googleapis.com \
  firebaseremoteconfig.googleapis.com \
  iamcredentials.googleapis.com

echo "── Secrets (placeholders — set real values after)"
for s in api-football-key r2-access-key-id r2-secret-access-key r2-endpoint; do
  gcloud secrets describe "$s" >/dev/null 2>&1 || \
    printf 'CHANGE_ME' | gcloud secrets create "$s" --data-file=-
done
echo "   Set real values with: printf 'VALUE' | gcloud secrets versions add <name> --data-file=-"

echo "── Runtime service account"
RUNTIME_SA="sports-runtime@${PROJECT_ID}.iam.gserviceaccount.com"
gcloud iam service-accounts describe "$RUNTIME_SA" >/dev/null 2>&1 || \
  gcloud iam service-accounts create sports-runtime --display-name "Backend runtime"
for role in roles/secretmanager.secretAccessor roles/cloudtasks.enqueuer; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member "serviceAccount:${RUNTIME_SA}" --role "$role" --condition=None -q >/dev/null
done

echo "── Cloud Tasks queue (fan-out target for the live-score dispatcher)"
gcloud tasks queues describe live-scores --location "$REGION" >/dev/null 2>&1 || \
  gcloud tasks queues create live-scores --location "$REGION"
# A fetch normally completes in under a second. Keeping a single task in flight
# prevents overlapping polls from diffing and publishing the same transition.
gcloud tasks queues update live-scores --location "$REGION" \
  --max-concurrent-dispatches 1 >/dev/null

echo "── Cloud Scheduler / Tasks identity (OIDC for /internal/*)"
SCHEDULER_SA="sports-scheduler@${PROJECT_ID}.iam.gserviceaccount.com"
gcloud iam service-accounts describe "$SCHEDULER_SA" >/dev/null 2>&1 || \
  gcloud iam service-accounts create sports-scheduler --display-name "Internal OIDC identity"
# Both the scheduler job and the Cloud Tasks it enqueues authenticate to
# /internal/* as this SA. The backend verifies this OIDC identity itself (the
# service is public for the app API), so no run.invoker binding is required —
# but the audience and email must match the backend's SCHEDULER_SA_EMAIL.
# The runtime SA enqueues tasks that mint tokens as this SA, so it needs to act
# as it (serviceAccountUser).
gcloud iam service-accounts add-iam-policy-binding "$SCHEDULER_SA" \
  --member "serviceAccount:${RUNTIME_SA}" --role roles/iam.serviceAccountUser -q >/dev/null
if SERVICE_URL=$(gcloud run services describe "$SERVICE" --region "$REGION" --format 'value(status.url)' 2>/dev/null); then
  upsert_scheduler_job() {
    local name="$1"
    local schedule="$2"
    local path="$3"
    local action="create"

    if gcloud scheduler jobs describe "$name" --location "$REGION" >/dev/null 2>&1; then
      action="update"
    fi

    gcloud scheduler jobs "$action" http "$name" \
      --location "$REGION" \
      --schedule "$schedule" \
      --uri "${SERVICE_URL}${path}" \
      --http-method POST \
      --oidc-service-account-email "$SCHEDULER_SA" \
      --oidc-token-audience "$SERVICE_URL" \
      --attempt-deadline 300s
  }

  # Cloud Scheduler is minute-granular, so once a minute it hits /internal/dispatch,
  # which enqueues 12 Cloud Tasks spaced 5s apart (each → /internal/fetch, a single
  # fast read). That gives ~every-5s polling with no request ever sleeping/pinning
  # the CPU. The handler gates itself on the match window (tasks.ts), enqueuing
  # nothing at all when no match is within [kickoff−30min, kickoff+4h] — which is
  # what keeps five leagues inside the API-Football quota. The job itself runs
  # year-round and never needs pausing.
  echo "── Cloud Scheduler → /internal/dispatch every minute (fans out to Cloud Tasks)"
  upsert_scheduler_job dispatch-live-scores '* * * * *' /internal/dispatch

  echo "── Cloud Scheduler → /internal/sync-schedule every 6h (fixtures-{date}.json)"
  # Keeps today±1's fixture files alive while the poller is asleep. The dispatch
  # gate above reads those files to decide whether to open a match window, so
  # they must NOT depend on the gated job to write them — on a day with no
  # football the poller never runs, and the file would never exist.
  # 5 calls × 4 runs = 20 API calls/day.
  upsert_scheduler_job sync-schedule '0 */6 * * *' /internal/sync-schedule

  echo "── Cloud Scheduler → /internal/sync-catalog daily (leagues + teams refresh)"
  # Independent of the live-score dispatcher (which only runs inside match
  # windows), so the multi-league catalog stays fresh year-round.
  upsert_scheduler_job sync-catalog '0 4 * * *' /internal/sync-catalog

  echo "── Cloud Scheduler → /internal/cache-health every 5 min (cf-cache-status probe)"
  # Enforces the §0 cache-only invariant: GETs a warm file + each live match file on
  # $SCORES_DOMAIN, reads cf-cache-status, and alerts on sustained MISS/BYPASS/DYNAMIC
  # (the signal that users are reaching R2 instead of the edge). Runs year-round so a
  # cache regression is caught even outside match windows.
  upsert_scheduler_job cache-health '*/5 * * * *' /internal/cache-health

  echo "── Cloud Run env → SERVICE_URL + SCORES_DOMAIN"
  gcloud run services update "$SERVICE" --region "$REGION" \
    --update-env-vars "SERVICE_URL=${SERVICE_URL},SCORES_DOMAIN=${SCORES_DOMAIN}" >/dev/null
else
  echo "   Cloud Run service not deployed yet — skipping scheduler jobs"
  echo "   Rerun this script after the first deploy to create or update them"
fi

echo "── Workload Identity Federation for GitHub Actions deploys"
DEPLOY_SA="sports-deploy@${PROJECT_ID}.iam.gserviceaccount.com"
gcloud iam service-accounts describe "$DEPLOY_SA" >/dev/null 2>&1 || \
  gcloud iam service-accounts create sports-deploy --display-name "GitHub Actions deploy"
for role in roles/run.admin roles/run.sourceDeveloper roles/cloudbuild.builds.editor roles/iam.serviceAccountUser roles/serviceusage.serviceUsageConsumer roles/storage.admin; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member "serviceAccount:${DEPLOY_SA}" --role "$role" --condition=None -q >/dev/null
done
gcloud iam workload-identity-pools describe github --location global >/dev/null 2>&1 || \
  gcloud iam workload-identity-pools create github --location global --display-name "GitHub"
gcloud iam workload-identity-pools providers describe github-provider \
  --location global --workload-identity-pool github >/dev/null 2>&1 || \
  gcloud iam workload-identity-pools providers create-oidc github-provider \
    --location global --workload-identity-pool github \
    --issuer-uri "https://token.actions.githubusercontent.com" \
    --attribute-mapping "google.subject=assertion.sub,attribute.repository=assertion.repository" \
    --attribute-condition "assertion.repository == 'thisisnsh/alldayidreamaboutsports'"
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format 'value(projectNumber)')
gcloud iam service-accounts add-iam-policy-binding "$DEPLOY_SA" \
  --role roles/iam.workloadIdentityUser \
  --member "principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github/attribute.repository/thisisnsh/alldayidreamaboutsports" -q >/dev/null

cat <<EOF

✅ Done. GitHub secrets/vars to set for this environment:
  secret GCP_WORKLOAD_IDENTITY_PROVIDER = projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github/providers/github-provider
  secret GCP_DEPLOY_SERVICE_ACCOUNT     = ${DEPLOY_SA}
  var    GCP_PROJECT_ID                 = ${PROJECT_ID}
  var    GCP_REGION                     = ${REGION}
  var    R2_BUCKET_SCORES               = environment's public scores bucket

Manual steps remaining (see infra/README.md):
  1. Firebase: add project in console, publish remoteconfig.template.json
     (no APNs/FCM — push was dropped for polling + CDN)
  2. Set real secret values (API-Football key, R2 creds)
  3. First deploy: gh workflow run backend-deploy.yml, then rerun this script so
     the scheduler job gets the real service URL
EOF
