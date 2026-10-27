#!/usr/bin/env bash
# Run once as project administrator after deploy.sh. Uses a NEW trust pool and service account.
set -euo pipefail
PUSH_PROJECT="${1:?usage: github.sh PROJECT REGION OWNER/REPO REPOSITORY_ID OWNER_ID}"
PUSH_REGION="${2:?missing region}"
PUSH_REPOSITORY="${3:?missing owner/repo}"
PUSH_REPOSITORY_ID="${4:?missing immutable repository id}"
PUSH_OWNER_ID="${5:?missing immutable owner id}"
PUSH_DEPLOY="sports-push-deploy@${PUSH_PROJECT}.iam.gserviceaccount.com"
PUSH_RUNTIME="sports-push-runtime@${PUSH_PROJECT}.iam.gserviceaccount.com"
PUSH_NUMBER=$(gcloud projects describe "$PUSH_PROJECT" --format='value(projectNumber)')
if ! gcloud iam service-accounts describe "$PUSH_DEPLOY" --project "$PUSH_PROJECT" >/dev/null 2>&1; then
  gcloud iam service-accounts create sports-push-deploy --project "$PUSH_PROJECT"
fi
if ! gcloud iam workload-identity-pools describe sports-push-github --location global --project "$PUSH_PROJECT" >/dev/null 2>&1; then
  gcloud iam workload-identity-pools create sports-push-github --location global --project "$PUSH_PROJECT"
fi
if gcloud iam workload-identity-pools providers describe github --workload-identity-pool sports-push-github --location global --project "$PUSH_PROJECT" >/dev/null 2>&1; then
  PUSH_ACTION=update-oidc
else
  PUSH_ACTION=create-oidc
fi
gcloud iam workload-identity-pools providers "$PUSH_ACTION" github --project "$PUSH_PROJECT" --location global \
  --workload-identity-pool sports-push-github --issuer-uri https://token.actions.githubusercontent.com \
  --attribute-mapping 'google.subject=assertion.sub,attribute.repository=assertion.repository' \
  --attribute-condition "assertion.repository_id=='${PUSH_REPOSITORY_ID}' && assertion.repository_owner_id=='${PUSH_OWNER_ID}' && assertion.ref=='refs/heads/main' && assertion.workflow_ref=='${PUSH_REPOSITORY}/.github/workflows/push-deploy.yml@refs/heads/main' && assertion.sub in ['repo:${PUSH_REPOSITORY}:environment:push-staging','repo:${PUSH_REPOSITORY}:environment:push-production']"
gcloud iam service-accounts add-iam-policy-binding "$PUSH_DEPLOY" --project "$PUSH_PROJECT" \
  --role roles/iam.workloadIdentityUser \
  --member "principalSet://iam.googleapis.com/projects/${PUSH_NUMBER}/locations/global/workloadIdentityPools/sports-push-github/attribute.repository/${PUSH_REPOSITORY}" >/dev/null
gcloud run services add-iam-policy-binding sports-cdn-push --region "$PUSH_REGION" --project "$PUSH_PROJECT" \
  --member "serviceAccount:${PUSH_DEPLOY}" --role roles/run.developer >/dev/null
gcloud iam service-accounts add-iam-policy-binding "$PUSH_RUNTIME" --project "$PUSH_PROJECT" \
  --member "serviceAccount:${PUSH_DEPLOY}" --role roles/iam.serviceAccountUser >/dev/null
gcloud artifacts repositories add-iam-policy-binding sports-push --location "$PUSH_REGION" --project "$PUSH_PROJECT" \
  --member "serviceAccount:${PUSH_DEPLOY}" --role roles/artifactregistry.writer >/dev/null
gcloud secrets add-iam-policy-binding sports-push-apns-key --project "$PUSH_PROJECT" \
  --member "serviceAccount:${PUSH_DEPLOY}" --role roles/secretmanager.secretVersionAdder >/dev/null
printf 'PUSH_WORKLOAD_IDENTITY_PROVIDER=projects/%s/locations/global/workloadIdentityPools/sports-push-github/providers/github\n' "$PUSH_NUMBER"
printf 'PUSH_DEPLOY_SERVICE_ACCOUNT=%s\n' "$PUSH_DEPLOY"
