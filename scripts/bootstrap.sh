#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# One-time bootstrap for a single environment.
#
#   ./scripts/bootstrap.sh dev  true    # first env in the account -> creates OIDC provider
#   ./scripts/bootstrap.sh prod false   # second env -> reuses the existing provider
#
# Creates:
#   1. the environment-scoped SAM artifact S3 bucket
#   2. the GitHub Actions OIDC deploy role for that environment
# and prints the two values to set on the matching GitHub Environment.
# -----------------------------------------------------------------------------
set -euo pipefail

ENVIRONMENT="${1:?usage: bootstrap.sh <dev|prod> [create-oidc-provider true|false]}"
CREATE_OIDC="${2:-false}"

APP_NAME="week7-orders"
REGION="${AWS_REGION:-eu-central-1}"
GITHUB_ORG="sarsahcodes"
GITHUB_REPO="week-7-dynamo-sam-app"

case "$ENVIRONMENT" in
  dev)  BRANCH="develop" ;;
  prod) BRANCH="main" ;;
  *)    echo "environment must be dev or prod" >&2; exit 1 ;;
esac

echo ">> [1/2] artifact bucket for ${ENVIRONMENT}"
aws cloudformation deploy \
  --template-file bootstrap/artifact-bucket.yaml \
  --stack-name "${APP_NAME}-artifacts-${ENVIRONMENT}" \
  --region "${REGION}" \
  --no-fail-on-empty-changeset \
  --parameter-overrides "Environment=${ENVIRONMENT}" "AppName=${APP_NAME}"

echo ">> [2/2] GitHub OIDC deploy role for ${ENVIRONMENT}"
aws cloudformation deploy \
  --template-file bootstrap/github-oidc.yaml \
  --stack-name "${APP_NAME}-oidc-${ENVIRONMENT}" \
  --region "${REGION}" \
  --capabilities CAPABILITY_NAMED_IAM \
  --no-fail-on-empty-changeset \
  --parameter-overrides \
      "Environment=${ENVIRONMENT}" \
      "AppName=${APP_NAME}" \
      "GitHubOrg=${GITHUB_ORG}" \
      "GitHubRepo=${GITHUB_REPO}" \
      "GitHubBranch=${BRANCH}" \
      "CreateOidcProvider=${CREATE_OIDC}"

BUCKET=$(aws cloudformation describe-stacks \
  --stack-name "${APP_NAME}-artifacts-${ENVIRONMENT}" --region "${REGION}" \
  --query "Stacks[0].Outputs[?OutputKey=='ArtifactBucketName'].OutputValue" --output text)

ROLE=$(aws cloudformation describe-stacks \
  --stack-name "${APP_NAME}-oidc-${ENVIRONMENT}" --region "${REGION}" \
  --query "Stacks[0].Outputs[?OutputKey=='DeployRoleArn'].OutputValue" --output text)

cat <<SUMMARY

Done. Now open GitHub -> Settings -> Environments -> "${ENVIRONMENT}"
and add these three environment *variables* (not secrets):

  AWS_REGION           = ${REGION}
  ARTIFACT_BUCKET      = ${BUCKET}
  AWS_DEPLOY_ROLE_ARN  = ${ROLE}

Or with the gh CLI:

  gh variable set AWS_REGION          --env ${ENVIRONMENT} --body "${REGION}"
  gh variable set ARTIFACT_BUCKET     --env ${ENVIRONMENT} --body "${BUCKET}"
  gh variable set AWS_DEPLOY_ROLE_ARN --env ${ENVIRONMENT} --body "${ROLE}"
SUMMARY
