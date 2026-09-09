#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Read the bootstrap stack outputs and set them as GitHub Environment variables.
#
#   ./scripts/set-github-vars.sh dev
#   ./scripts/set-github-vars.sh prod
#
# Requires the gh CLI, authenticated:  gh auth login
# Run ./scripts/bootstrap.sh <env> first - this reads what that created.
# -----------------------------------------------------------------------------
set -euo pipefail

ENVIRONMENT="${1:?usage: set-github-vars.sh <dev|prod>}"
APP_NAME="week7-orders"
REGION="${AWS_REGION:-eu-central-1}"

case "$ENVIRONMENT" in dev|prod) ;; *) echo "environment must be dev or prod" >&2; exit 1 ;; esac

stack_output () {  # stack_output <stack-suffix> <output-key>
  aws cloudformation describe-stacks \
    --stack-name "${APP_NAME}-$1-${ENVIRONMENT}" \
    --region "${REGION}" \
    --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" \
    --output text
}

echo ">> reading stack outputs for ${ENVIRONMENT}"
BUCKET=$(stack_output artifacts ArtifactBucketName)
ROLE=$(stack_output oidc DeployRoleArn)

if [ -z "$BUCKET" ] || [ "$BUCKET" = "None" ]; then
  echo "!! no artifact bucket found - run ./scripts/bootstrap.sh ${ENVIRONMENT} first" >&2; exit 1
fi
if [ -z "$ROLE" ] || [ "$ROLE" = "None" ]; then
  echo "!! no deploy role found - the ${APP_NAME}-oidc-${ENVIRONMENT} stack has not succeeded" >&2; exit 1
fi

echo "   AWS_REGION          = ${REGION}"
echo "   ARTIFACT_BUCKET     = ${BUCKET}"
echo "   AWS_DEPLOY_ROLE_ARN = ${ROLE}"

# `gh variable set --env` fails if the environment does not exist yet, so create it.
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
gh api -X PUT "repos/${REPO}/environments/${ENVIRONMENT}" --silent >/dev/null

echo ">> setting variables on the '${ENVIRONMENT}' GitHub Environment"
gh variable set AWS_REGION          --env "${ENVIRONMENT}" --body "${REGION}"
gh variable set ARTIFACT_BUCKET     --env "${ENVIRONMENT}" --body "${BUCKET}"
gh variable set AWS_DEPLOY_ROLE_ARN --env "${ENVIRONMENT}" --body "${ROLE}"

echo
gh variable list --env "${ENVIRONMENT}"
