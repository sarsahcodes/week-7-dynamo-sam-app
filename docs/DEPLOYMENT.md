# Deployment guide

End-to-end, from an empty AWS account to a DynamoDB table deployed by GitHub
Actions into two independent environments.

Account used in the examples: `266735846670`, region `eu-central-1`.
Substitute your own if they differ.

---

## Contents

1. [How the pieces fit together](#1-how-the-pieces-fit-together)
2. [Prerequisites](#2-prerequisites)
3. [Stage 1 — Bootstrap AWS](#3-stage-1--bootstrap-aws)
4. [Stage 2 — Configure GitHub](#4-stage-2--configure-github)
5. [Stage 3 — Deploy the table](#5-stage-3--deploy-the-table)
6. [Verification](#6-verification)
7. [Troubleshooting](#7-troubleshooting)
8. [Tearing it down](#8-tearing-it-down)

---

## 1. How the pieces fit together

There are **three CloudFormation stacks per environment**, deployed in order.
The first two are one-time bootstrap; only the third is redeployed by the pipeline.

```
                     ONE TIME                          EVERY PUSH
        ┌───────────────────────────────┐      ┌──────────────────────┐
        │ week7-orders-artifacts-<env>  │      │  week7-orders-<env>  │
        │  S3 bucket for SAM artifacts  │─────▶│  the DynamoDB table  │
        └───────────────────────────────┘      └──────────────────────┘
        ┌───────────────────────────────┐               ▲
        │ week7-orders-oidc-<env>       │               │
        │  OIDC provider + deploy role  │───────────────┘
        └───────────────────────────────┘        assumed by GitHub Actions
```

Why bootstrap is separate: the pipeline's role is deliberately allowed to touch
**only** its own stack, bucket and table. It cannot create IAM roles or S3
buckets, so those must exist before it runs. That separation is what makes the
dev pipeline incapable of reaching prod.

| Stack | Created by | Contains |
| --- | --- | --- |
| `week7-orders-artifacts-<env>` | you, once | Versioned, encrypted, TLS-only S3 bucket for packaged templates |
| `week7-orders-oidc-<env>` | you, once | GitHub OIDC provider (account-wide, created once) + `week7-orders-github-deploy-<env>` role |
| `week7-orders-<env>` | the pipeline, every push | The `week7-orders-<env>` DynamoDB table and its two GSIs |

---

## 2. Prerequisites

| Tool | Check | If missing |
| --- | --- | --- |
| AWS CLI v2 | `aws --version` | [AWS CLI installer](https://aws.amazon.com/cli/) |
| SAM CLI | `sam --version` | `winget install --id Amazon.SAM-CLI -e` |
| GitHub CLI | `gh --version` | `winget install --id GitHub.cli -e` |
| Git | `git --version` | already present |

Authenticate both:

```powershell
aws sso login                 # or `aws configure` for static keys
aws sts get-caller-identity   # must print account 266735846670

gh auth login
```

### A note on shells

The commands below are given for **PowerShell**. If you use Git Bash instead:

| | PowerShell | Git Bash |
| --- | --- | --- |
| Set a variable | `$env:AWS_REGION = "eu-central-1"` | `export AWS_REGION=eu-central-1` |
| Continue a line | trailing `` ` `` | trailing `\` |
| Run a script | `.\scripts\deploy.ps1` | `./scripts/bootstrap.sh` |

Mixing them is the single most common source of confusing errors — a PowerShell
backtick pasted into bash produces `bash: --query: command not found`.

---

## 3. Stage 1 — Bootstrap AWS

Run **once per environment**. Do not run both the bash script and the raw
`aws cloudformation deploy` commands — they do the same thing.

### 3.1 Check for an existing OIDC provider

An AWS account can hold exactly **one** `token.actions.githubusercontent.com`
provider. Shared lab accounts usually already have one.

```powershell
aws iam list-open-id-connect-providers
```

* **Output is non-empty** → the provider exists, reuse it (the default).
* **Output is empty** → the first bootstrap run must create it.

### 3.2 Deploy the bootstrap stacks

**Git Bash:**

```bash
export AWS_REGION=eu-central-1

./scripts/bootstrap.sh dev        # add `true` only if no provider exists yet
./scripts/bootstrap.sh prod
```

**PowerShell** (equivalent, four explicit deploys):

```powershell
$env:AWS_REGION = "eu-central-1"

# --- dev ---
aws cloudformation deploy `
  --template-file bootstrap/artifact-bucket.yaml `
  --stack-name week7-orders-artifacts-dev `
  --no-fail-on-empty-changeset `
  --parameter-overrides Environment=dev AppName=week7-orders

aws cloudformation deploy `
  --template-file bootstrap/github-oidc.yaml `
  --stack-name week7-orders-oidc-dev `
  --capabilities CAPABILITY_NAMED_IAM `
  --no-fail-on-empty-changeset `
  --parameter-overrides Environment=dev AppName=week7-orders `
    GitHubOrg=sarsahcodes GitHubRepo=week-7-dynamo-sam-app `
    GitHubBranch=develop CreateOidcProvider=false

# --- prod (identical, with prod/main) ---
aws cloudformation deploy `
  --template-file bootstrap/artifact-bucket.yaml `
  --stack-name week7-orders-artifacts-prod `
  --no-fail-on-empty-changeset `
  --parameter-overrides Environment=prod AppName=week7-orders

aws cloudformation deploy `
  --template-file bootstrap/github-oidc.yaml `
  --stack-name week7-orders-oidc-prod `
  --capabilities CAPABILITY_NAMED_IAM `
  --no-fail-on-empty-changeset `
  --parameter-overrides Environment=prod AppName=week7-orders `
    GitHubOrg=sarsahcodes GitHubRepo=week-7-dynamo-sam-app `
    GitHubBranch=main CreateOidcProvider=false
```

Set `CreateOidcProvider=true` on the **first** stack only if step 3.1 showed no
provider.

### 3.3 Confirm all four stacks

```powershell
aws cloudformation describe-stacks `
  --query "Stacks[?starts_with(StackName,'week7-orders')].[StackName,StackStatus]" `
  --output table
```

All four must read `CREATE_COMPLETE` or `UPDATE_COMPLETE`. Anything in
`ROLLBACK_COMPLETE` must be deleted before it can be retried — see
[Troubleshooting](#7-troubleshooting).

### 3.4 What this produced

| | dev | prod |
| --- | --- | --- |
| Artifact bucket | `week7-orders-sam-artifacts-dev-266735846670-eu-central-1` | `week7-orders-sam-artifacts-prod-266735846670-eu-central-1` |
| Deploy role | `arn:aws:iam::266735846670:role/week7-orders-github-deploy-dev` | `arn:aws:iam::266735846670:role/week7-orders-github-deploy-prod` |

Read them back at any time:

```powershell
foreach ($s in 'artifacts-dev','oidc-dev','artifacts-prod','oidc-prod') {
  Write-Host "--- week7-orders-$s"
  aws cloudformation describe-stacks --stack-name "week7-orders-$s" `
    --query "Stacks[0].Outputs[].[OutputKey,OutputValue]" --output table
}
```

---

## 4. Stage 2 — Configure GitHub

### 4.1 Push both branches

```powershell
git push -u origin main
git push -u origin develop
```

### 4.2 Create the two environments

`gh variable set --env` returns **HTTP 404** if the environment does not exist,
so create them first:

```powershell
$REPO = gh repo view --json nameWithOwner -q .nameWithOwner
gh api -X PUT "repos/$REPO/environments/dev"  --silent
gh api -X PUT "repos/$REPO/environments/prod" --silent
```

### 4.3 Set the variables

Three per environment. These are **variables**, not secrets — none of them is
sensitive, and no AWS keys are stored in GitHub at all.

```powershell
gh variable set AWS_REGION          --env dev --body "eu-central-1"
gh variable set ARTIFACT_BUCKET     --env dev --body "week7-orders-sam-artifacts-dev-266735846670-eu-central-1"
gh variable set AWS_DEPLOY_ROLE_ARN --env dev --body "arn:aws:iam::266735846670:role/week7-orders-github-deploy-dev"

gh variable set AWS_REGION          --env prod --body "eu-central-1"
gh variable set ARTIFACT_BUCKET     --env prod --body "week7-orders-sam-artifacts-prod-266735846670-eu-central-1"
gh variable set AWS_DEPLOY_ROLE_ARN --env prod --body "arn:aws:iam::266735846670:role/week7-orders-github-deploy-prod"
```

Or read them from the live stacks instead of typing them:

```bash
./scripts/set-github-vars.sh dev
./scripts/set-github-vars.sh prod
```

Verify:

```powershell
gh variable list --env dev
gh variable list --env prod
```

### 4.4 Add the prod approval gate

**Settings → Environments → prod → Required reviewers →** add yourself.

This cannot be scripted through `gh` and is the visible evidence that dev and
prod are separately governed. Without it, prod deploys unattended.

---

## 5. Stage 3 — Deploy the table

### 5.1 Through the pipeline (the graded path)

| Trigger | Workflow | What happens |
| --- | --- | --- |
| Push to `develop` | `Deploy DEV` | cfn-lint → `sam validate` → `sam build` → `sam deploy` → DescribeTable check |
| Push to `main` | `Deploy PROD` | same, plus a wait for approval and a change-set preview before applying |
| Actions → Run workflow | either | manual `workflow_dispatch` |

```powershell
# dev
git checkout develop
git push

# prod
git checkout main
git merge develop
git push          # then approve the run under Actions
```

Watch it under **Actions**. Each run ends with a step that calls
`DescribeTable` and **fails the build** if the billing mode is not
`PAY_PER_REQUEST`, the table class is not `STANDARD_INFREQUENT_ACCESS`, or
fewer than two GSIs exist. The results are written to the run summary.

### 5.2 From your machine (useful for a quick check)

This uses **your** credentials, not the GitHub role, so it works even before the
OIDC stack is healthy.

```powershell
.\scripts\deploy.ps1 -Environment dev
.\scripts\deploy.ps1 -Environment prod
```

Or the raw commands:

```powershell
$env:AWS_REGION = "eu-central-1"
sam validate --lint --region eu-central-1
sam build
sam deploy --config-env dev `
  --s3-bucket week7-orders-sam-artifacts-dev-266735846670-eu-central-1
```

A local deploy proves the template is correct but demonstrates nothing about
the pipeline — the pipeline run is what the rubric scores.

---

## 6. Verification

**PowerShell:**

```powershell
.\scripts\seed-items.ps1 -Environment dev   # 5 orders across 3 customers, 4 statuses
.\scripts\verify.ps1     -Environment dev   # config + one query against each GSI
```

**Git Bash:**

```bash
./scripts/seed-items.sh dev
./scripts/verify.sh dev
```

**Or a single item by hand**, which is what the rubric asks you to demonstrate:

```powershell
aws dynamodb put-item --table-name week7-orders-dev --region eu-central-1 `
  --item file://seed/console-item.json
```

That file is in plain JSON, not DynamoDB JSON, so it is also the exact text to
paste into the console's *Create item -> JSON view*.

Expected table configuration:

| | |
| --- | --- |
| Billing mode | `PAY_PER_REQUEST` |
| Table class | `STANDARD_INFREQUENT_ACCESS` |
| Primary key | `orderId` (HASH) + `createdAt` (RANGE) |
| GSIs | `CustomerOrdersIndex`, `OrderStatusIndex` |

For the console walkthrough (insert, read, query both GSIs, update, delete), see
[CONSOLE-VERIFICATION.md](CONSOLE-VERIFICATION.md).

---

## 7. Troubleshooting

### `Provider with url https://token.actions.githubusercontent.com already exists`

The account already has the GitHub OIDC provider. Redeploy with
`CreateOidcProvider=false`. The role's trust policy references the provider by
ARN string, so it binds to the existing one without the stack owning it.

### `Cannot update stack in ROLLBACK_COMPLETE state`

A stack that fails during *create* cannot be updated — only deleted.

```powershell
aws cloudformation delete-stack --stack-name week7-orders-oidc-dev
aws cloudformation wait stack-delete-complete --stack-name week7-orders-oidc-dev
```

Then redeploy.

### `Your session has expired or credentials have changed`

```powershell
aws sso login
aws sts get-caller-identity
```

`aws login` in SAM's error text is not a real command; `aws sso login` is.

### `failed to set variable: HTTP 404`

The GitHub Environment does not exist yet. See [4.2](#42-create-the-two-environments).

### `bash: --query: command not found`

A PowerShell command with trailing backticks was pasted into Git Bash. Use `\`
for line continuation, or switch to PowerShell.

### `bash: sam: command not found`

SAM CLI is installed for Windows but not on Git Bash's PATH:

```bash
echo 'export PATH="/c/Program Files/Amazon/AWSSAMCLI/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

You do not need SAM locally for the pipeline — the runners install it themselves
via `aws-actions/setup-sam`.

### A push does not start any workflow run

Check, in order:

```powershell
gh run list --limit 10                       # has anything ever run?
gh workflow list                             # are the workflows registered?
git log origin/develop --oneline -1          # did the push actually land?
```

* **`gh workflow list` is empty** - the workflow files are not on the branch you
  pushed. They must exist at `.github/workflows/` on that branch.
* **Workflows listed but disabled** - re-enable with
  `gh workflow enable "Deploy DEV"`, or Settings -> Actions -> *Allow all actions*.
* **The push did not land** - `git status` will show unpushed commits.
* **Nothing changed in the triggering paths** - earlier versions of these
  workflows had a `paths:` filter, so doc-only commits were ignored. That filter
  has been removed; any push to the branch now runs the pipeline.

You can always start a run by hand: **Actions -> Deploy DEV -> Run workflow**, or
`gh workflow run "Deploy DEV" --ref develop`.

### `Error parsing parameter '--item': Expected: '=', received: 'i'`

The JSON file passed to the AWS CLI starts with a UTF-8 BOM (`ï»¿`). Windows
PowerShell 5.1 writes one whenever you use `Set-Content -Encoding utf8`. Write
the file without a BOM:

```powershell
[System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
```

The scripts in this repo already do this; the error only appears if you write a
payload file yourself.

### `Not authorized to perform sts:AssumeRoleWithWebIdentity`

Three things must line up:

1. The workflow declares `permissions: id-token: write` — it does.
2. The branch matches the role's trust policy: `develop` for dev, `main` for prod.
3. The OIDC provider carries the `sts.amazonaws.com` audience:

```powershell
aws iam get-open-id-connect-provider `
  --open-id-connect-provider-arn arn:aws:iam::266735846670:oidc-provider/token.actions.githubusercontent.com
```

If missing:

```powershell
aws iam add-client-id-to-open-id-connect-provider `
  --open-id-connect-provider-arn arn:aws:iam::266735846670:oidc-provider/token.actions.githubusercontent.com `
  --client-id sts.amazonaws.com
```

---

## 8. Tearing it down

Reverse order. Prod resists deletion by design — the table has
`DeletionProtectionEnabled` and the stack has `DeletionPolicy: Retain`.

```powershell
# 1. application stacks
aws cloudformation delete-stack --stack-name week7-orders-dev

# prod: disable protection first, and the table is retained even then
aws dynamodb update-table --table-name week7-orders-prod --no-deletion-protection-enabled
aws cloudformation delete-stack --stack-name week7-orders-prod
aws dynamodb delete-table --table-name week7-orders-prod

# 2. bootstrap stacks
aws cloudformation delete-stack --stack-name week7-orders-oidc-dev
aws cloudformation delete-stack --stack-name week7-orders-oidc-prod

# 3. buckets are RETAINED on stack delete - empty and remove them by hand
aws s3 rb s3://week7-orders-sam-artifacts-dev-266735846670-eu-central-1 --force
aws s3 rb s3://week7-orders-sam-artifacts-prod-266735846670-eu-central-1 --force
aws cloudformation delete-stack --stack-name week7-orders-artifacts-dev
aws cloudformation delete-stack --stack-name week7-orders-artifacts-prod
```

Leave the OIDC provider alone if anything else in the account uses it.
