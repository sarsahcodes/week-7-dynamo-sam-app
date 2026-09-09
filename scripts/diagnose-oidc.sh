#!/usr/bin/env bash
#
# Diagnose "Not authorized to perform sts:AssumeRoleWithWebIdentity".
#
# That error means STS was reached but the ROLE'S TRUST POLICY rejected the
# token. Four things must line up; this prints all four and says which is wrong.
#
#   ./scripts/diagnose-oidc.sh dev
#   ./scripts/diagnose-oidc.sh prod
#
set -uo pipefail

ENVIRONMENT="${1:?usage: diagnose-oidc.sh <dev|prod>}"
REGION="${AWS_REGION:-eu-central-1}"
APP_NAME="${APP_NAME:-week7-orders}"
GH_ORG="${GITHUB_ORG:-sarsahcodes}"
GH_REPO="${GITHUB_REPO:-week-7-dynamo-sam-app}"
case "$ENVIRONMENT" in dev) BRANCH=develop ;; prod) BRANCH=main ;; *) echo "dev or prod"; exit 1 ;; esac

ok()  { printf '  \033[32mOK\033[0m    %s\n' "$*"; }
bad() { printf '  \033[31mWRONG\033[0m %s\n' "$*"; }
hdr() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
[ -n "${ACCOUNT_ID}" ] && [ "${ACCOUNT_ID}" != "None" ] || { echo "Configure AWS credentials first."; exit 1; }
echo "Account ${ACCOUNT_ID} | Region ${REGION} | Environment ${ENVIRONMENT} | Branch ${BRANCH}"

hdr "1. Role ARN the workflow should be using"
STACK_ROLE_ARN="$(aws cloudformation describe-stacks \
  --stack-name "${APP_NAME}-oidc-${ENVIRONMENT}" --region "${REGION}" \
  --query "Stacks[0].Outputs[?OutputKey=='DeployRoleArn'].OutputValue | [0]" \
  --output text 2>/dev/null)"

if [ -z "${STACK_ROLE_ARN}" ] || [ "${STACK_ROLE_ARN}" = "None" ]; then
  bad "Stack ${APP_NAME}-oidc-${ENVIRONMENT} has no DeployRoleArn output."
  aws cloudformation describe-stacks --stack-name "${APP_NAME}-oidc-${ENVIRONMENT}" \
    --region "${REGION}" --query "Stacks[0].StackStatus" --output text 2>/dev/null
  echo "  Deploy it before anything else: ./scripts/bootstrap.sh ${ENVIRONMENT}"
  exit 1
fi
ok "DeployRoleArn = ${STACK_ROLE_ARN}"
echo "  >> This exact string must be the AWS_DEPLOY_ROLE_ARN variable on the"
echo "     '${ENVIRONMENT}' GitHub Environment. Check with:"
echo "         gh variable list --env ${ENVIRONMENT}"

ROLE_NAME="${STACK_ROLE_ARN##*/}"

hdr "2. Trust policy on ${ROLE_NAME}"
TRUST="$(aws iam get-role --role-name "${ROLE_NAME}" --query 'Role.AssumeRolePolicyDocument' --output json 2>/dev/null)"
[ -n "${TRUST}" ] || { bad "Role ${ROLE_NAME} does not exist."; exit 1; }
echo "${TRUST}" | python3 -m json.tool

SUBS="$(echo "${TRUST}" | python3 -c "
import json,sys
c=json.load(sys.stdin)['Statement'][0].get('Condition',{})
v=(c.get('StringLike',{}) or {}).get('token.actions.githubusercontent.com:sub','')
v=(c.get('StringEquals',{}) or {}).get('token.actions.githubusercontent.com:sub',v)
print('\n'.join(v if isinstance(v,list) else [v]))")"
AUD="$(echo "${TRUST}" | python3 -c "
import json,sys
c=json.load(sys.stdin)['Statement'][0].get('Condition',{})
print((c.get('StringEquals',{}) or {}).get('token.actions.githubusercontent.com:aud',''))")"
FED="$(echo "${TRUST}" | python3 -c "
import json,sys
print(json.load(sys.stdin)['Statement'][0]['Principal'].get('Federated',''))")"

hdr "3. Do the accepted subjects cover this repo and branch?"
CLASSIC="repo:${GH_ORG}/${GH_REPO}:ref:refs/heads/${BRANCH}"
ENVSUB="repo:${GH_ORG}/${GH_REPO}:environment:${ENVIRONMENT}"
IMMUT="repo:${GH_ORG}@142625676/${GH_REPO}@999999:ref:refs/heads/${BRANCH}"   # sample immutable form
echo "  Accepted patterns:"; echo "${SUBS}" | sed 's/^/    /'; echo

for probe in "${CLASSIC}" "${ENVSUB}" "${IMMUT}"; do
  M=0
  while IFS= read -r pat; do [ -n "$pat" ] || continue; case "$probe" in ${pat}) M=1 ;; esac; done <<< "${SUBS}"
  [ "$M" = 1 ] && ok "matches  ${probe}" || bad "no match ${probe}"
done
echo
echo "  The IMMUTABLE probe matters: GitHub is migrating accounts to subjects"
echo "  that embed numeric ids. A migrated account sends ONLY that form, and a"
echo "  policy listing just the classic subject fails with exactly the error"
echo "  you are debugging. Redeploy the oidc stack from the current template if"
echo "  the immutable probe says 'no match'."

hdr "4. Audience and provider"
[ "${AUD}" = "sts.amazonaws.com" ] && ok "aud condition = sts.amazonaws.com" || bad "aud condition = '${AUD}' (expected sts.amazonaws.com)"

echo "  Trust policy federates to: ${FED}"
PROVIDERS="$(aws iam list-open-id-connect-providers --output text 2>/dev/null | awk '{print $2}')"
echo "  Providers in account:"; echo "${PROVIDERS}" | sed 's/^/    /'
if echo "${PROVIDERS}" | grep -qxF "${FED}"; then
  ok "provider exists"
  IDS="$(aws iam get-open-id-connect-provider --open-id-connect-provider-arn "${FED}" --query 'ClientIDList' --output text 2>/dev/null)"
  echo "  Client IDs: ${IDS}"
  echo "${IDS}" | grep -q "sts.amazonaws.com" \
    && ok "provider audience includes sts.amazonaws.com" \
    || { bad "provider audience missing sts.amazonaws.com"; echo "     Fix: aws iam add-client-id-to-open-id-connect-provider --open-id-connect-provider-arn ${FED} --client-id sts.amazonaws.com"; }
else
  bad "trust policy references a provider that does not exist"
fi

hdr "Next step"
cat <<TXT
  The 'Show OIDC subject claim' step in Deploy DEV prints the subject GitHub
  actually sent. Compare it to the accepted patterns in section 3 - they must
  match literally (with * as the only wildcard).

  To pin the owner id rather than wildcard it:
      curl -s https://api.github.com/users/${GH_ORG} | grep '"id"'
      GITHUB_ORG_ID=<that number> ./scripts/bootstrap.sh ${ENVIRONMENT}
TXT
