#!/usr/bin/env bash
# Usage: demo-unsigned.sh
# Pushes a locally built, unsigned image to ECR and tries to deploy it through
# the same verification step as the pipeline. Then tries to overwrite its tag.
set -euo pipefail

REPO="marcinbator/ecs-supply-chain"
export AWS_REGION="${AWS_REGION:-eu-central-1}"
export ECS_CLUSTER=ecs-supply-chain ECS_SERVICE=ecs-supply-chain
export CERT_IDENTITY="https://github.com/$REPO/.github/workflows/app.yml@refs/heads/main"
cd "$(dirname "$0")/.."

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGISTRY="$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"
TAG="unsigned-$(date +%s)"

aws ecr get-login-password | docker login --username AWS --password-stdin "$REGISTRY"
docker build -t "$REGISTRY/ecs-supply-chain:$TAG" --build-arg APP_VERSION=unsigned app/
docker push "$REGISTRY/ecs-supply-chain:$TAG"
IMAGE=$(docker inspect --format '{{index .RepoDigests 0}}' "$REGISTRY/ecs-supply-chain:$TAG")

echo "== Deploying unsigned image $IMAGE"
if .github/scripts/deploy.sh "$IMAGE"; then
  echo "UNEXPECTED: unsigned image was deployed"
  exit 1
fi

echo "== Overwriting existing tag $TAG"
docker build -t "$REGISTRY/ecs-supply-chain:$TAG" --build-arg APP_VERSION=overwrite app/
if docker push "$REGISTRY/ecs-supply-chain:$TAG"; then
  echo "UNEXPECTED: tag was overwritten"
  exit 1
fi
echo "OK: unsigned image rejected and tag overwrite refused by ECR"
