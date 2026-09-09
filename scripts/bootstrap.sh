#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# One-time bootstrap for a single environment.
#
#   ./scripts/bootstrap.sh dev          # reuses an existing OIDC provider (default)
#   ./scripts/bootstrap.sh dev true      # ALSO creates the provider (first time in a fresh account)
#
# An account can hold only one token.actions.githubusercontent.com provider.
# The script detects an existing one and refuses to try creating a duplicate.
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
# Optional: pin the numeric GitHub owner id in the immutable OIDC subject.
# Leave empty to wildcard it (the owner NAME stays pinned either way).
#   GITHUB_ORG_ID=$(curl -s https://api.github.com/users/sarsahcodes | grep '"id"' | head -1)
GITHUB_ORG_ID="${GITHUB_ORG_ID:-}"

case "$ENVIRONMENT" in
  dev)  BRANCH="develop" ;;
  prod) BRANCH="main" ;;
  *)    echo "environment must be dev or prod" >&2; exit 1 ;;
esac

# An account can only have one GitHub OIDC provider - never try to create a second.
EXISTING_PROVIDER=$(aws iam list-open-id-connect-providers \
  --query "OpenIDConnectProviderList[?contains(Arn, 'token.actions.githubusercontent.com')].Arn" \
  --output text 2>/dev/null || true)

if [ -n "${EXISTING_PROVIDER}" ]; then
  if [ "${CREATE_OIDC}" = "true" ]; then
    echo ">> GitHub OIDC provider already exists (${EXISTING_PROVIDER}); reusing it."
    CREATE_OIDC="false"
  fi
  # Role assumption fails silently later if this audience is missing.
  if ! aws iam get-open-id-connect-provider \
        --open-id-connect-provider-arn "${EXISTING_PROVIDER}" \
        --query 'ClientIDList' --output text | grep -q 'sts.amazonaws.com'; then
    echo ">> adding the sts.amazonaws.com audience to the existing provider"
    aws iam add-client-id-to-open-id-connect-provider \
      --open-id-connect-provider-arn "${EXISTING_PROVIDER}" \
      --client-id sts.amazonaws.com
  fi
elif [ "${CREATE_OIDC}" != "true" ]; then
  echo "!! No GitHub OIDC provider found in this account." >&2
  echo "!! Re-run as: ./scripts/bootstrap.sh ${ENVIRONMENT} true" >&2
  exit 1
fi

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
      "GitHubOrgId=${GITHUB_ORG_ID}" \
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
