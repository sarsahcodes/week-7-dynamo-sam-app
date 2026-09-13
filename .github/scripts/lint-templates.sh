#!/usr/bin/env bash
#
# Lint every CloudFormation/SAM template in the repository with cfn-lint.
# Called by the validate job in .github/workflows/deploy-dev.yml and
# .github/workflows/deploy-prod.yml.
#
# The list of templates lives here rather than in the two workflows, so a new
# template is added to CI in one place instead of two.
#
# Reads:   nothing
# Exits:   0 when every template lints clean, non-zero otherwise (cfn-lint's
#          own exit code, which GitHub renders as annotations)
#
# Runnable locally:
#   bash .github/scripts/lint-templates.sh

set -euo pipefail

TEMPLATES=(
  template.yaml
  bootstrap/artifact-bucket.yaml
  bootstrap/github-oidc.yaml
)

# --quiet keeps the pip noise out of the log; the runner image already has pip.
if ! command -v cfn-lint > /dev/null 2>&1; then
  pip install --quiet cfn-lint
fi

echo "cfn-lint $(cfn-lint --version 2>&1 | tail -n1)"
printf 'Linting: %s\n' "${TEMPLATES[*]}"

cfn-lint "${TEMPLATES[@]}"
