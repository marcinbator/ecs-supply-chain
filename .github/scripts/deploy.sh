#!/usr/bin/env bash
# Usage: deploy.sh <repository@sha256:digest>
# Verifies the Cosign signature, registers a new task definition revision with
# the image digest and waits for the ECS blue/green deployment to finish.
set -euo pipefail

IMAGE="${1:?usage: deploy.sh <repository@sha256:digest>}"
: "${AWS_REGION:?}" "${ECS_CLUSTER:?}" "${ECS_SERVICE:?}" "${CERT_IDENTITY:?}"
DESIRED_COUNT="${DESIRED_COUNT:-1}"
OIDC_ISSUER="https://token.actions.githubusercontent.com"

summary() {
  echo "$1"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then echo "$1" >> "$GITHUB_STEP_SUMMARY"; fi
}

if [[ "$IMAGE" != *@sha256:* ]]; then
  summary "REJECTED: image must be referenced by digest: $IMAGE"
  exit 1
fi

echo "Verifying signature of $IMAGE"
if ! cosign verify "$IMAGE" \
  --certificate-identity "$CERT_IDENTITY" \
  --certificate-oidc-issuer "$OIDC_ISSUER" > /dev/null; then
  summary "REJECTED: no valid signature from $CERT_IDENTITY, service not updated"
  exit 1
fi

TASK_DEF=$(aws ecs describe-task-definition --task-definition "$ECS_SERVICE" --query taskDefinition)
NEW_TASK_DEF=$(jq --arg image "$IMAGE" '
  .containerDefinitions[0].image = $image
  | del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .compatibilities, .registeredAt, .registeredBy)
' <<< "$TASK_DEF")
TASK_DEF_ARN=$(aws ecs register-task-definition --cli-input-json "$NEW_TASK_DEF" \
  --query taskDefinition.taskDefinitionArn --output text)
echo "Registered $TASK_DEF_ARN"

STARTED=$(date +%s)
aws ecs update-service --cluster "$ECS_CLUSTER" --service "$ECS_SERVICE" \
  --task-definition "$TASK_DEF_ARN" --desired-count "$DESIRED_COUNT" > /dev/null

DEPLOYMENT_ARN=""
until [[ -n "$DEPLOYMENT_ARN" && "$DEPLOYMENT_ARN" != "None" ]]; do
  sleep 5
  DEPLOYMENT_ARN=$(aws ecs list-service-deployments --cluster "$ECS_CLUSTER" --service "$ECS_SERVICE" \
    --created-at "after=$STARTED" \
    --query 'sort_by(serviceDeployments, &createdAt)[-1].serviceDeploymentArn' --output text)
done
echo "Service deployment: $DEPLOYMENT_ARN"

while true; do
  DEPLOYMENT=$(aws ecs describe-service-deployments --service-deployment-arns "$DEPLOYMENT_ARN" \
    --query 'serviceDeployments[0]')
  STATUS=$(jq -r .status <<< "$DEPLOYMENT")
  echo "$(date +%T) status=$STATUS stage=$(jq -r '.lifecycleStage // "-"' <<< "$DEPLOYMENT")"
  case "$STATUS" in
    PENDING | IN_PROGRESS | ROLLBACK_REQUESTED | ROLLBACK_IN_PROGRESS | STOP_REQUESTED) sleep 20 ;;
    *) break ;;
  esac
done

REASON=$(jq -r '.statusReason // ""' <<< "$DEPLOYMENT")
ALARMS=$(jq -r '(.alarms.triggeredAlarmNames // []) | join(", ")' <<< "$DEPLOYMENT")

if [[ "$STATUS" == "SUCCESSFUL" ]]; then
  summary "SUCCESS: $IMAGE deployed after bake time"
elif [[ -n "$ALARMS" ]]; then
  summary "ROLLBACK: alarm ($ALARMS) during bake time, traffic moved back to the previous version. $REASON"
  exit 1
else
  summary "STOPPED: new version failed health checks and never received production traffic ($STATUS). $REASON"
  exit 1
fi
