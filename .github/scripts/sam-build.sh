#!/usr/bin/env bash
#
# Build the SAM application and tell the following steps which template to
# deploy. Called by the deploy job in both workflows.
#
# A template whose only resource is a DynamoDB table gives `sam build` nothing
# to do, and older SAM versions treat that as an error rather than a no-op.
# That is not a failed build, so it must not fail the deploy: fall back to the
# source template and carry on, with a warning in the log saying so.
#
# Reads:   TEMPLATE_SOURCE   template to build (default template.yaml)
# Writes:  TEMPLATE=<path to deploy> to $GITHUB_ENV, consumed by sam-deploy.sh
# Exits:   0 - a build that produces nothing is a warning, not a failure
#
# Runnable locally (prints the choice instead of exporting it):
#   bash .github/scripts/sam-build.sh

# No -e: the failure of `sam build` is a case handled below, not an abort.
set -uo pipefail

TEMPLATE_SOURCE="${TEMPLATE_SOURCE:-template.yaml}"
GITHUB_ENV="${GITHUB_ENV:-/dev/null}"
BUILT="ineffective"   # replaced below; never used as a path

if sam build --template "${TEMPLATE_SOURCE}"; then
  BUILT=".aws-sam/build/template.yaml"
  # A successful build that wrote nothing would otherwise hand the deploy step
  # a path that does not exist.
  if [ ! -f "${BUILT}" ]; then
    echo "::warning::sam build succeeded but produced no ${BUILT}; deploying the source template"
    BUILT="${TEMPLATE_SOURCE}"
  fi
else
  echo "::warning::sam build reported nothing to build; deploying the source template"
  BUILT="${TEMPLATE_SOURCE}"
fi

echo "TEMPLATE=${BUILT}" >> "${GITHUB_ENV}"
echo "Template to deploy: ${BUILT}"
