#!/usr/bin/env bash
#
# Deploy the SAM stack, or create its change set without executing it.
# Called by the deploy job in .github/workflows/deploy-dev.yml and
# .github/workflows/deploy-prod.yml - one script for all three invocations, so
# dev and prod cannot drift apart on flags.
#
# Everything that differs between the stages arrives as an environment
# variable; nothing about dev or prod is hard-coded here.
#
# Reads:   SAM_CONFIG_ENV    samconfig.toml section to use (dev | prod)
#          STACK_NAME        CloudFormation stack to deploy
#          ARTIFACT_BUCKET   S3 bucket for the packaged artifacts
#          AWS_REGION        region to deploy into
#          TEMPLATE          template to deploy (set by sam-build.sh)
#          ENVIRONMENT       value for the Environment parameter (default: SAM_CONFIG_ENV)
#          APP_NAME          value for the AppName parameter (default week7-orders)
#          S3_PREFIX         artifact key prefix (default <APP_NAME>/<SAM_CONFIG_ENV>)
#          MODE              deploy (default) | preview - preview creates the
#                            change set with --no-execute-changeset and writes
#                            it to the job summary for the approver to read
# Writes:  the change set to $GITHUB_STEP_SUMMARY when MODE=preview
# Exits:   0 on success, the sam exit code otherwise
#
# Runnable locally:
#   SAM_CONFIG_ENV=dev STACK_NAME=week7-orders-dev AWS_REGION=eu-central-1 \
#   ARTIFACT_BUCKET=my-bucket MODE=preview bash .github/scripts/sam-deploy.sh

# A deploy is a single action, not a list of checks: stop at the first failure.
set -euo pipefail

: "${SAM_CONFIG_ENV:?SAM_CONFIG_ENV is not set}"
: "${STACK_NAME:?STACK_NAME is not set}"
: "${ARTIFACT_BUCKET:?ARTIFACT_BUCKET is not set - check the GitHub Environment variables}"
: "${AWS_REGION:?AWS_REGION is not set}"

TEMPLATE="${TEMPLATE:-template.yaml}"
ENVIRONMENT="${ENVIRONMENT:-$SAM_CONFIG_ENV}"
APP_NAME="${APP_NAME:-week7-orders}"
S3_PREFIX="${S3_PREFIX:-${APP_NAME}/${SAM_CONFIG_ENV}}"
MODE="${MODE:-deploy}"
GITHUB_STEP_SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

# Identical for both modes - the only difference is the final flag.
ARGS=(
  --config-env        "${SAM_CONFIG_ENV}"
  --template-file     "${TEMPLATE}"
  --stack-name        "${STACK_NAME}"
  --s3-bucket         "${ARTIFACT_BUCKET}"
  --s3-prefix         "${S3_PREFIX}"
  --region            "${AWS_REGION}"
  --capabilities      CAPABILITY_IAM
  --no-fail-on-empty-changeset
  --parameter-overrides "Environment=${ENVIRONMENT} AppName=${APP_NAME}"
)

case "${MODE}" in
  preview)
    CHANGESET="$(mktemp)"
    trap 'rm -f "$CHANGESET"' EXIT

    echo "Creating change set for ${STACK_NAME} (not executing it)"
    sam deploy "${ARGS[@]}" --no-execute-changeset | tee "${CHANGESET}"

    {
      echo "<details><summary>${SAM_CONFIG_ENV} change set for \`${STACK_NAME}\`</summary>"
      echo ""
      echo '```'
      cat "${CHANGESET}"
      echo '```'
      echo "</details>"
    } >> "${GITHUB_STEP_SUMMARY}"
    ;;

  deploy)
    echo "Deploying ${STACK_NAME} from ${TEMPLATE}"
    sam deploy "${ARGS[@]}" --no-confirm-changeset
    ;;

  *)
    echo "::error::MODE is '${MODE}', expected 'deploy' or 'preview'."
    exit 1
    ;;
esac
