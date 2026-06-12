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

gcloud config set project "$PROJECT_ID"

echo "── Enabling APIs"
gcloud services enable \
  run.googleapis.com \
  cloudbuild.googleapis.com \
  cloudscheduler.googleapis.com \
  firestore.googleapis.com \
  secretmanager.googleapis.com \
  fcm.googleapis.com \
  firebaseremoteconfig.googleapis.com \
  iamcredentials.googleapis.com

echo "── Firestore (native mode, regional = cheapest reads)"
gcloud firestore databases create --location="$REGION" --type=firestore-native || true

echo "── Secrets (placeholders — set real values after)"
for s in api-football-key session-jwt-secret r2-access-key-id r2-secret-access-key r2-endpoint google-oauth-client-id; do
  gcloud secrets describe "$s" >/dev/null 2>&1 || \
    printf 'CHANGE_ME' | gcloud secrets create "$s" --data-file=-
done
echo "   Set real values with: printf 'VALUE' | gcloud secrets versions add <name> --data-file=-"

echo "── Runtime service account"
RUNTIME_SA="sports-runtime@${PROJECT_ID}.iam.gserviceaccount.com"
gcloud iam service-accounts create sports-runtime --display-name "Backend runtime" || true
for role in roles/datastore.user roles/secretmanager.secretAccessor roles/firebase.sdkAdminServiceAgent; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member "serviceAccount:${RUNTIME_SA}" --role "$role" --condition=None -q >/dev/null
done

echo "── Cloud Scheduler → /internal/poll every minute (OIDC-authenticated)"
SCHEDULER_SA="sports-scheduler@${PROJECT_ID}.iam.gserviceaccount.com"
gcloud iam service-accounts create sports-scheduler --display-name "Poll scheduler" || true
# The backend verifies this OIDC identity itself (service is public for the app
# API), so no run.invoker binding is strictly required — but the audience and
# email must match POLLER_SERVICE_ACCOUNT below.
SERVICE_URL=$(gcloud run services describe "$SERVICE" --region "$REGION" --format 'value(status.url)' 2>/dev/null || echo "https://SET-AFTER-FIRST-DEPLOY")
gcloud scheduler jobs create http poll-live-scores \
  --location "$REGION" \
  --schedule '* * * * *' \
  --uri "${SERVICE_URL}/internal/poll" \
  --http-method POST \
  --oidc-service-account-email "$SCHEDULER_SA" \
  --oidc-token-audience "$SERVICE_URL" \
  --attempt-deadline 300s || \
  echo "   (job exists or service not deployed yet — rerun after first deploy)"

echo "── Workload Identity Federation for GitHub Actions deploys"
DEPLOY_SA="sports-deploy@${PROJECT_ID}.iam.gserviceaccount.com"
gcloud iam service-accounts create sports-deploy --display-name "GitHub Actions deploy" || true
for role in roles/run.admin roles/cloudbuild.builds.editor roles/iam.serviceAccountUser roles/storage.admin; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member "serviceAccount:${DEPLOY_SA}" --role "$role" --condition=None -q >/dev/null
done
gcloud iam workload-identity-pools create github --location global --display-name "GitHub" || true
gcloud iam workload-identity-pools providers create-oidc github-provider \
  --location global --workload-identity-pool github \
  --issuer-uri "https://token.actions.githubusercontent.com" \
  --attribute-mapping "google.subject=assertion.sub,attribute.repository=assertion.repository" \
  --attribute-condition "assertion.repository == 'thisisnsh/onlyfansforsports'" || true
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format 'value(projectNumber)')
gcloud iam service-accounts add-iam-policy-binding "$DEPLOY_SA" \
  --role roles/iam.workloadIdentityUser \
  --member "principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github/attribute.repository/thisisnsh/onlyfansforsports" -q >/dev/null

cat <<EOF

✅ Done. GitHub secrets/vars to set for this environment:
  secret GCP_WORKLOAD_IDENTITY_PROVIDER = projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github/providers/github-provider
  secret GCP_DEPLOY_SERVICE_ACCOUNT     = ${DEPLOY_SA}
  var    GCP_PROJECT_ID                 = ${PROJECT_ID}
  var    GCP_REGION                     = ${REGION}

Manual steps remaining (see infra/README.md):
  1. Firebase: add project in console, upload APNs key, publish remoteconfig.template.json
  2. OAuth consent screen → External → "In production" (basic scopes only)
  3. Set real secret values (API-Football key, JWT secret, R2 creds, OAuth client id)
  4. First deploy: gh workflow run backend-deploy.yml, then rerun this script so
     the scheduler job gets the real service URL
EOF
