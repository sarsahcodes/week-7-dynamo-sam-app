#!/usr/bin/env bash
#
# Verify the deployed DynamoDB table against the week 7 lab requirements.
# Called by .github/workflows/deploy-dev.yml and .github/workflows/deploy-prod.yml.
#
# The three requirements checked here are the ones the rubric asks for and the
# ones a template edit can silently undo: On-Demand billing, the
# Standard-Infrequent-Access table class, and at least two global secondary
# indexes. Checking them against the live table - rather than against
# template.yaml - is what proves the deploy actually landed.
#
# Reads:   TABLE_NAME          the table to describe (required)
#          AWS_REGION          region to describe it in (default eu-central-1)
#          ENVIRONMENT_LABEL   heading used in the job summary (default: suffix
#                              of TABLE_NAME, e.g. week7-orders-dev -> dev)
# Writes:  a result table to $GITHUB_STEP_SUMMARY (stdout-only when run locally)
# Exits:   0 when every requirement holds, 1 with ::error:: annotations otherwise
#
# Runnable locally:
#   TABLE_NAME=week7-orders-dev AWS_REGION=eu-central-1 \
#   bash .github/scripts/verify-table.sh

# Deliberately no -e: report every failed requirement in one run instead of
# stopping at the first, so a bad deploy is diagnosed in a single pass.
set -uo pipefail

TABLE_NAME="${TABLE_NAME:-}"
AWS_REGION="${AWS_REGION:-eu-central-1}"
ENVIRONMENT_LABEL="${ENVIRONMENT_LABEL:-${TABLE_NAME##*-}}"
GITHUB_STEP_SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

if [ -z "$TABLE_NAME" ]; then
  echo "::error::TABLE_NAME is not set - the calling workflow must export it."
  exit 1
fi

RC=0
problem() { echo "::error::$*"; RC=1; }

# describe-table output goes to a temp file, not into the checkout, so the
# workspace is left exactly as the deploy step produced it.
DESCRIBE="$(mktemp)"
trap 'rm -f "$DESCRIBE"' EXIT

if ! aws dynamodb describe-table \
       --table-name "$TABLE_NAME" \
       --region "$AWS_REGION" > "$DESCRIBE" 2>&1; then
  echo "::error::describe-table failed for '${TABLE_NAME}' in ${AWS_REGION}."
  cat "$DESCRIBE"
  exit 1
fi

# Defaults on every read: a table with no GSIs has no key at all rather than an
# empty list, and jq would otherwise emit "null" and pass the numeric test.
BILLING=$(jq -r '.Table.BillingModeSummary.BillingMode // "PROVISIONED"' "$DESCRIBE")
CLASS=$(jq -r '.Table.TableClassSummary.TableClass // "STANDARD"' "$DESCRIBE")
GSIS=$(jq -r '[(.Table.GlobalSecondaryIndexes // [])[].IndexName] | join(", ")' "$DESCRIBE")
GSI_COUNT=$(jq -r '(.Table.GlobalSecondaryIndexes // []) | length' "$DESCRIBE")

echo "Table        : ${TABLE_NAME} (${AWS_REGION})"
echo "Billing mode : ${BILLING}"
echo "Table class  : ${CLASS}"
echo "GSIs (${GSI_COUNT})     : ${GSIS:-none}"

[ "$BILLING" = "PAY_PER_REQUEST" ] ||
  problem "billing mode is '${BILLING}', expected PAY_PER_REQUEST (On-Demand)."

[ "$CLASS" = "STANDARD_INFREQUENT_ACCESS" ] ||
  problem "table class is '${CLASS}', expected STANDARD_INFREQUENT_ACCESS."

[ "$GSI_COUNT" -ge 2 ] ||
  problem "table has ${GSI_COUNT} global secondary index(es), expected at least 2."

if [ "$RC" -eq 0 ]; then
  HEADING="${ENVIRONMENT_LABEL} deployment verified :white_check_mark:"
else
  HEADING="${ENVIRONMENT_LABEL} deployment did NOT meet the requirements :x:"
fi

{
  echo "### ${HEADING}"
  echo ""
  echo "| Check | Value |"
  echo "| --- | --- |"
  echo "| Table | \`${TABLE_NAME}\` |"
  echo "| Region | \`${AWS_REGION}\` |"
  echo "| Billing mode | \`${BILLING}\` |"
  echo "| Table class | \`${CLASS}\` |"
  echo "| GSIs | \`${GSIS:-none}\` |"
} >> "$GITHUB_STEP_SUMMARY"

exit $RC
