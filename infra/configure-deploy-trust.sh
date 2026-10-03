#!/usr/bin/env bash
# Restrict federation to this immutable repository, main, the deployment
# workflow, and the selected environment. Reconciles existing providers too.
set -euo pipefail
PROJECT_ID="${1:?usage: configure-deploy-trust.sh <project-id> <staging|prod>}"
DEPLOY_ENVIRONMENT="${2:?usage: configure-deploy-trust.sh <project-id> <staging|prod>}"
case "$DEPLOY_ENVIRONMENT" in staging|prod) ;; *) exit 1 ;; esac
REPOSITORY="${GITHUB_REPOSITORY:-thisisnsh/alldayidreamaboutsports}"
metadata=$(gh api "repos/$REPOSITORY")
REPOSITORY_ID=$(jq -er '.id | tostring' <<<"$metadata")
OWNER_ID=$(jq -er '.owner.id | tostring' <<<"$metadata")
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
DEPLOY_SA="sports-deploy@${PROJECT_ID}.iam.gserviceaccount.com"

gcloud iam workload-identity-pools describe github --project "$PROJECT_ID" --location global >/dev/null 2>&1 || \
  gcloud iam workload-identity-pools create github --project "$PROJECT_ID" --location global --display-name GitHub
action=create-oidc
if gcloud iam workload-identity-pools providers describe github-provider \
  --project "$PROJECT_ID" --location global --workload-identity-pool github >/dev/null 2>&1; then
  action=update-oidc
fi
condition="assertion.repository_id == '${REPOSITORY_ID}' && assertion.repository_owner_id == '${OWNER_ID}' && assertion.ref == 'refs/heads/main' && assertion.workflow_ref == '${REPOSITORY}/.github/workflows/backend-deploy.yml@refs/heads/main' && assertion.sub == 'repo:${REPOSITORY}:environment:${DEPLOY_ENVIRONMENT}'"
gcloud iam workload-identity-pools providers "$action" github-provider \
  --project "$PROJECT_ID" --location global --workload-identity-pool github \
  --issuer-uri https://token.actions.githubusercontent.com \
  --attribute-mapping 'google.subject=assertion.sub,attribute.repository_id=assertion.repository_id,attribute.repository_owner_id=assertion.repository_owner_id,attribute.ref=assertion.ref,attribute.workflow_ref=assertion.workflow_ref' \
  --attribute-condition "$condition" --quiet

policy_file=$(mktemp)
trap 'rm -f "$policy_file"' EXIT
pool="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github/"
member="${pool}attribute.repository_id/${REPOSITORY_ID}"
gcloud iam service-accounts get-iam-policy "$DEPLOY_SA" --project "$PROJECT_ID" --format=json | \
  jq --arg pool "$pool" --arg member "$member" '
    .bindings = ([.bindings[]? |
      if .role == "roles/iam.workloadIdentityUser" then
        .members |= map(select(startswith($pool) | not))
      else . end | select(.members | length > 0)] +
      [{role: "roles/iam.workloadIdentityUser", members: [$member]}])
  ' > "$policy_file"
gcloud iam service-accounts set-iam-policy "$DEPLOY_SA" "$policy_file" --project "$PROJECT_ID" --quiet >/dev/null
echo "Deployment trust restricted to ${REPOSITORY} main / ${DEPLOY_ENVIRONMENT}."
