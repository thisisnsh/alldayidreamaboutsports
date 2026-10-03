#!/usr/bin/env bash
# Reconcile invocation IAM without replacing unrelated service IAM bindings.
set -euo pipefail
PROJECT_ID="${1:?usage: secure-backend.sh <project-id> <region>}"
REGION="${2:?usage: secure-backend.sh <project-id> <region>}"
SERVICE=alldayidreamaboutsports-backend

for identity in sports-scheduler sports-deploy; do
  gcloud run services add-iam-policy-binding "$SERVICE" \
    --project "$PROJECT_ID" --region "$REGION" \
    --member "serviceAccount:${identity}@${PROJECT_ID}.iam.gserviceaccount.com" \
    --role roles/run.invoker --quiet >/dev/null
done

policy=$(gcloud run services get-iam-policy "$SERVICE" \
  --project "$PROJECT_ID" --region "$REGION" --format=json)
for principal in allUsers allAuthenticatedUsers; do
  if jq -e --arg principal "$principal" \
    '.bindings[] | select(.role == "roles/run.invoker") | .members[] | select(. == $principal)' \
    <<<"$policy" >/dev/null; then
    gcloud run services remove-iam-policy-binding "$SERVICE" \
      --project "$PROJECT_ID" --region "$REGION" \
      --member "$principal" --role roles/run.invoker --quiet >/dev/null
  fi
done
# IAM protects both custom domains and the direct run.app URL. Authenticated
# GitHub smoke checks use external ingress; scheduler/tasks use GCP OIDC.
gcloud run services update "$SERVICE" --project "$PROJECT_ID" --region "$REGION" \
  --invoker-iam-check --quiet >/dev/null
