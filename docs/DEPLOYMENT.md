# Deployment and testing — step by step

Every step from an empty AWS account to a DynamoDB table deployed by GitHub
Actions into two independent environments, and then tested.

Each step says **what** to run, **why** it exists, and **what you should see**.
Skipping a step generally produces an error several steps later, so the order
matters more than it looks.

Examples use account `266735846670` and region `eu-central-1`. Substitute yours.

---

## Contents

- [What you are building](#what-you-are-building)
- [Step 0 — Install and authenticate the tools](#step-0--install-and-authenticate-the-tools)
- **Part A — Bootstrap AWS (once per environment)**
  - [Step 1 — Check for an existing GitHub OIDC provider](#step-1--check-for-an-existing-github-oidc-provider)
  - [Step 2 — Create the artifact bucket and deploy role](#step-2--create-the-artifact-bucket-and-deploy-role)
  - [Step 3 — Confirm all four bootstrap stacks](#step-3--confirm-all-four-bootstrap-stacks)
  - [Step 4 — Read back the values you will need](#step-4--read-back-the-values-you-will-need)
- **Part B — Configure GitHub**
  - [Step 5 — Push both branches](#step-5--push-both-branches)
  - [Step 6 — Create the two GitHub Environments](#step-6--create-the-two-github-environments)
  - [Step 7 — Set the three variables per environment](#step-7--set-the-three-variables-per-environment)
  - [Step 8 — Add the production approval gate](#step-8--add-the-production-approval-gate)
- **Part C — Deploy the table**
  - [Step 9 — Deploy dev through the pipeline](#step-9--deploy-dev-through-the-pipeline)
  - [Step 10 — Deploy prod through the pipeline](#step-10--deploy-prod-through-the-pipeline)
  - [Step 11 — Deploy from your machine instead](#step-11--deploy-from-your-machine-instead-optional)
- **Part D — Test the table**
  - [Step 12 — Confirm the configuration](#step-12--confirm-the-configuration)
  - [Step 13 — CREATE an item in the console](#step-13--create-an-item-in-the-console)
  - [Step 14 — READ it back](#step-14--read-it-back)
  - [Step 15 — QUERY GSI 1](#step-15--query-gsi-1-customerordersindex)
  - [Step 16 — QUERY GSI 2](#step-16--query-gsi-2-orderstatusindex)
  - [Step 17 — UPDATE and watch it move between indexes](#step-17--update-and-watch-it-move-between-indexes)
  - [Step 18 — DELETE](#step-18--delete)
- [Evidence checklist for the review](#evidence-checklist-for-the-review)
- [Troubleshooting](#troubleshooting)
- [Tearing it down](#tearing-it-down)

---

## What you are building

There are **three CloudFormation stacks per environment**. The first two are
bootstrap, deployed once by you. Only the third is redeployed by the pipeline.

```
                     ONE TIME (you)                    EVERY PUSH (pipeline)
        ┌───────────────────────────────┐      ┌──────────────────────┐
        │ week7-orders-artifacts-<env>  │      │  week7-orders-<env>  │
        │  S3 bucket for SAM artifacts  │─────▶│  the DynamoDB table  │
        └───────────────────────────────┘      └──────────────────────┘
        ┌───────────────────────────────┐               ▲
        │ week7-orders-oidc-<env>       │               │
        │  OIDC provider + deploy role  │───────────────┘
        └───────────────────────────────┘        assumed by GitHub Actions
```

**Why bootstrap is separate.** The pipeline's IAM role is deliberately allowed to
touch only its own stack, its own bucket and its own table. It cannot create IAM
roles or S3 buckets. So those must already exist before it runs. That constraint
is what makes it impossible for the dev pipeline to reach production — not a
convention, an IAM boundary.

| Stack | Created by | Contains |
| --- | --- | --- |
| `week7-orders-artifacts-<env>` | you, once | Versioned, encrypted, TLS-only S3 bucket for packaged templates |
| `week7-orders-oidc-<env>` | you, once | GitHub OIDC provider (account-wide, created once) + the `week7-orders-github-deploy-<env>` role |
| `week7-orders-<env>` | the pipeline, every push | The DynamoDB table and its two GSIs |

---

## Step 0 — Install and authenticate the tools

**What.**

```powershell
aws --version      # AWS CLI v2
sam --version      # SAM CLI
gh --version       # GitHub CLI
git --version
```

Install anything missing:

```powershell
winget install --id Amazon.SAM-CLI -e
winget install --id GitHub.cli -e
```

Then authenticate both services:

```powershell
aws sso login                 # or `aws configure` for static keys
aws sts get-caller-identity   # must print account 266735846670

gh auth login
```

**Why.** `aws sts get-caller-identity` is the only reliable proof that your
credentials work. AWS SSO sessions expire after a few hours, and the failure
surfaces halfway through a deploy as *"Your session has expired"* — re-running
this one command is how you tell credentials apart from a real problem.

**Expected.** A JSON blob with `"Account": "266735846670"`.

### A note on shells

Commands below are given for **PowerShell**. If you use Git Bash:

| | PowerShell | Git Bash |
| --- | --- | --- |
| Set a variable | `$env:AWS_REGION = "eu-central-1"` | `export AWS_REGION=eu-central-1` |
| Continue a line | trailing `` ` `` | trailing `\` |
| Run a script | `.\scripts\deploy.ps1` | `./scripts/bootstrap.sh` |

Pasting a PowerShell block into bash produces `bash: --query: command not found`,
because bash treats the backtick as command substitution and the next line as a
new command. This is the single most common source of confusing errors here.

---

# Part A — Bootstrap AWS

Run Part A **once per environment**. It creates nothing that changes afterwards.

## Step 1 — Check for an existing GitHub OIDC provider

**What.**

```powershell
aws iam list-open-id-connect-providers
```

**Why.** An AWS account can hold exactly **one** identity provider for
`token.actions.githubusercontent.com`. Shared training accounts usually already
have one from an earlier lab. Trying to create a second fails the whole stack
with `AlreadyExists (409)` and rolls it back — which is precisely what happens
if you skip this step.

**Expected.**

- **Non-empty output** → a provider exists. Reuse it. This is the default, so
  do nothing special in Step 2.
- **Empty output** → no provider yet. Pass `true` to the first bootstrap run in
  Step 2 so it creates one.

## Step 2 — Create the artifact bucket and deploy role

**What (Git Bash):**

```bash
export AWS_REGION=eu-central-1

./scripts/bootstrap.sh dev        # append `true` only if Step 1 found nothing
./scripts/bootstrap.sh prod
```

**What (PowerShell)** — the same four deploys, written out:

```powershell
$env:AWS_REGION = "eu-central-1"

# --- dev: artifact bucket ---
aws cloudformation deploy `
  --template-file bootstrap/artifact-bucket.yaml `
  --stack-name week7-orders-artifacts-dev `
  --no-fail-on-empty-changeset `
  --parameter-overrides Environment=dev AppName=week7-orders

# --- dev: OIDC deploy role ---
aws cloudformation deploy `
  --template-file bootstrap/github-oidc.yaml `
  --stack-name week7-orders-oidc-dev `
  --capabilities CAPABILITY_NAMED_IAM `
  --no-fail-on-empty-changeset `
  --parameter-overrides Environment=dev AppName=week7-orders `
    GitHubOrg=sarsahcodes GitHubRepo=week-7-dynamo-sam-app `
    GitHubBranch=develop CreateOidcProvider=false

# --- prod: artifact bucket ---
aws cloudformation deploy `
  --template-file bootstrap/artifact-bucket.yaml `
  --stack-name week7-orders-artifacts-prod `
  --no-fail-on-empty-changeset `
  --parameter-overrides Environment=prod AppName=week7-orders

# --- prod: OIDC deploy role ---
aws cloudformation deploy `
  --template-file bootstrap/github-oidc.yaml `
  --stack-name week7-orders-oidc-prod `
  --capabilities CAPABILITY_NAMED_IAM `
  --no-fail-on-empty-changeset `
  --parameter-overrides Environment=prod AppName=week7-orders `
    GitHubOrg=sarsahcodes GitHubRepo=week-7-dynamo-sam-app `
    GitHubBranch=main CreateOidcProvider=false
```

Run **one** of these two, not both — the bash script is a wrapper around exactly
these commands.

**Why each part.**

- **`--capabilities CAPABILITY_NAMED_IAM`** on the OIDC stack: the template sets
  an explicit `RoleName`. CloudFormation requires you to acknowledge named IAM
  resources, because a fixed name can collide with or shadow an existing role.
- **`--no-fail-on-empty-changeset`**: re-running with no changes exits 0 instead
  of erroring, so the command is safely repeatable.
- **`GitHubBranch=develop` / `main`**: written into the role's trust policy. The
  dev role only accepts tokens from workflow runs on `develop`; prod only from
  `main`. This is enforced by STS, not by the workflow file.
- **`CreateOidcProvider=false`**: from Step 1. The role's trust policy references
  the provider by ARN string, so it binds to a pre-existing provider fine
  without the stack owning it.

**Expected.** Four `Successfully created/updated stack` messages. The bash script
additionally prints the bucket name and role ARN you need in Step 7.

## Step 3 — Confirm all four bootstrap stacks

**What.**

```powershell
aws cloudformation describe-stacks `
  --query "Stacks[?starts_with(StackName,'week7-orders')].[StackName,StackStatus]" `
  --output table
```

**Why.** `aws cloudformation deploy` can report success for the command while a
stack ends up rolled back. Checking status is how you find out before the
failure resurfaces as a confusing GitHub Actions error two steps later.

**Expected.** Four rows, all `CREATE_COMPLETE` or `UPDATE_COMPLETE`.

Anything showing `ROLLBACK_COMPLETE` must be **deleted** before it can be
retried — CloudFormation cannot update a stack that failed during creation:

```powershell
aws cloudformation delete-stack --stack-name week7-orders-oidc-dev
aws cloudformation wait stack-delete-complete --stack-name week7-orders-oidc-dev
```

Then fix the cause and repeat Step 2.

## Step 4 — Read back the values you will need

**What.**

```powershell
foreach ($s in 'artifacts-dev','oidc-dev','artifacts-prod','oidc-prod') {
  Write-Host "--- week7-orders-$s"
  aws cloudformation describe-stacks --stack-name "week7-orders-$s" `
    --query "Stacks[0].Outputs[].[OutputKey,OutputValue]" --output table
}
```

**Why.** These four values are the only link between AWS and GitHub. Reading
them from the stack outputs rather than typing them by hand removes a whole
class of silent misconfiguration — a role ARN left over from a previous lab
whose trust policy names a different repository fails with an error that gives
no hint that the ARN is the problem.

**Expected.**

| | dev | prod |
| --- | --- | --- |
| Artifact bucket | `week7-orders-sam-artifacts-dev-266735846670-eu-central-1` | `week7-orders-sam-artifacts-prod-266735846670-eu-central-1` |
| Deploy role | `arn:aws:iam::266735846670:role/week7-orders-github-deploy-dev` | `arn:aws:iam::266735846670:role/week7-orders-github-deploy-prod` |

---

# Part B — Configure GitHub

## Step 5 — Push both branches

**What.**

```powershell
git push -u origin main
git push -u origin develop
```

**Why.** A workflow file only exists to GitHub once it is on the branch. Actions
are also triggered by what is on the remote, never by local commits — a fix
committed but not pushed silently keeps running the old workflow, and the logs
give no clue. Confirm nothing is stranded:

```powershell
git log --oneline origin/develop..develop     # must be empty
git log --oneline origin/main..main           # must be empty
```

**Expected.** Both commands print nothing.

## Step 6 — Create the two GitHub Environments

**What.**

```powershell
$REPO = gh repo view --json nameWithOwner -q .nameWithOwner
gh api -X PUT "repos/$REPO/environments/dev"  --silent
gh api -X PUT "repos/$REPO/environments/prod" --silent
```

**Why.** `gh variable set --env dev` returns **HTTP 404** if the environment does
not exist yet, and the message does not say so. GitHub Environments are also
what carry the approval gate and scope each set of variables to one deployment
target, so they are not optional here.

**Expected.** No output (that is what `--silent` means). Verify with
`gh api "repos/$REPO/environments" -q '.environments[].name'`.

## Step 7 — Set the three variables per environment

**What.**

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

**Why these are variables, not secrets.** None of the three is sensitive. A role
ARN is not a credential — it is useless without a token whose subject matches the
trust policy. There are no AWS access keys anywhere in this setup; each job mints
credentials that expire in an hour. Using variables also means you can read the
values back to check them, which you cannot do with secrets.

**Expected.**

```powershell
gh variable list --env dev
gh variable list --env prod
```

Three rows each.

## Step 8 — Add the production approval gate

**What.** In the browser: **Settings → Environments → prod → Required reviewers**
→ add yourself → **Save protection rules**.

**Why.** This is the only manual step in Part B, because `gh` cannot set
protection rules. It is also the most visible evidence that dev and prod are
separately governed: without it, a merge to `main` deploys production with no
human in the loop.

**Expected.** The prod environment page shows *Required reviewers: 1*.

---

# Part C — Deploy the table

## Step 9 — Deploy dev through the pipeline

**What.**

```powershell
git checkout develop
git push          # any push to develop triggers Deploy DEV
```

Or start one by hand:

```powershell
gh workflow run "Deploy DEV" --ref develop
gh run watch
```

**Why.** This is the path the rubric scores. The workflow runs five stages:

| Stage | What it proves |
| --- | --- |
| `cfn-lint` | The template is structurally valid CloudFormation |
| `sam validate` | SAM accepts the transform |
| OIDC assume-role | GitHub can authenticate to AWS without stored keys |
| `sam build` + `sam deploy` | The stack actually applies |
| `DescribeTable` check | The live table has On-Demand billing, the Standard-IA class and two GSIs |

That last stage **fails the build** if any of the three requirements is wrong, so
a green run is itself the evidence — you are not asked to take a screenshot's
word for it.

**Expected.** A green run. Open it and read the job summary:

```
### DEV deployment verified ✅
| Check | Value |
| Table | week7-orders-dev |
| Billing mode | PAY_PER_REQUEST |
| Table class | STANDARD_INFREQUENT_ACCESS |
| GSIs | CustomerOrdersIndex, OrderStatusIndex |
```

## Step 10 — Deploy prod through the pipeline

**What.**

```powershell
git checkout main
git merge develop
git push
```

Then open **Actions → Deploy PROD** and click **Review deployments → Approve**.

**Why.** Prod runs the same stages plus two: it waits for your approval before
touching anything, and it creates a CloudFormation change set with
`--no-execute-changeset` first, printing the diff to the run summary. You see
exactly what will change before it changes.

**Expected.** The run pauses with *Waiting for review*. After approval it
completes and prints the same verification table for `week7-orders-prod`.

## Step 11 — Deploy from your machine instead (optional)

**What.**

```powershell
.\scripts\deploy.ps1 -Environment dev
```

or the raw commands:

```powershell
$env:AWS_REGION = "eu-central-1"
sam validate --lint --region eu-central-1
sam build
sam deploy --config-env dev `
  --s3-bucket week7-orders-sam-artifacts-dev-266735846670-eu-central-1
```

**Why.** This uses **your** credentials rather than the GitHub role, so it works
even while the OIDC setup is still broken. Useful for getting the table up so you
can practise the console testing in Part D while you debug the pipeline.

`--config-env dev` pulls the stack name, region, capabilities, tags and
`Environment=dev` from `samconfig.toml`; the bucket is passed explicitly because
its name embeds the account id, which the committed config cannot know.

**Expected.** `Successfully created/updated stack - week7-orders-dev`.

A local deploy proves the template is correct but demonstrates nothing about the
pipeline. It does not substitute for Step 9.

---

# Part D — Test the table

Steps 12–18 are the *Verification & Usability* rubric item (10 points). Take a
screenshot at each one.

Open the table:

```
https://eu-central-1.console.aws.amazon.com/dynamodbv2/home?region=eu-central-1#item-explorer?table=week7-orders-dev
```

Or navigate: **DynamoDB → Tables → `week7-orders-dev` → Explore table items**.

Load the sample data first so the index queries return something interesting:

```powershell
.\scripts\seed-items.ps1 -Environment dev     # 5 orders, 3 customers, 4 statuses
```

```bash
./scripts/seed-items.sh dev                   # Git Bash equivalent
```

## Step 12 — Confirm the configuration

**What.** On the table's **Overview** tab, then the **Indexes** tab:

| Look for | Expected |
| --- | --- |
| Status | `Active` |
| Capacity mode | `On-demand` |
| Table class | `DynamoDB Standard-IA` |
| Partition key | `orderId (String)` |
| Sort key | `createdAt (String)` |
| Indexes | `CustomerOrdersIndex`, `OrderStatusIndex`, both `Active` |

Or from the CLI:

```powershell
.\scripts\verify.ps1 -Environment dev
```

**Why.** Three of these are graded directly: On-Demand billing (5 points), a
non-default table class (5 points), and the key schema plus two GSIs (20 points).
If *Table class* reads `DynamoDB Standard`, the wrong template was deployed.

## Step 13 — CREATE an item in the console

**What.** **Explore table items → Create item → JSON view**.

If the **View DynamoDB JSON** toggle is **off**, paste:

```json
{
  "orderId": "ORD-2001",
  "createdAt": "2026-09-09T10:00:00Z",
  "customerId": "CUST-004",
  "orderStatus": "PENDING",
  "totalAmount": 599.99,
  "currency": "GHS",
  "itemCount": 5
}
```

If the toggle is **on**, the console wants the typed form:

```json
{
  "orderId":     { "S": "ORD-2001" },
  "createdAt":   { "S": "2026-09-09T10:00:00Z" },
  "customerId":  { "S": "CUST-004" },
  "orderStatus": { "S": "PENDING" },
  "totalAmount": { "N": "599.99" },
  "currency":    { "S": "GHS" },
  "itemCount":   { "N": "5" }
}
```

Click **Create item**. Then add a second one: same `customerId` (`CUST-004`),
`orderId` `ORD-2002`, `createdAt` `2026-09-09T11:30:00Z`, `orderStatus` `SHIPPED`.

**Why.** Numbers are quoted in DynamoDB JSON (`"N": "599.99"`, never `599.99`) —
the wire format carries them as strings so precision is never lost to a float.
Pasting an unquoted number is the most common error at this step.

The second item matters: with two orders for one customer in different statuses,
Steps 15 and 16 return visibly different result sets, which is what makes the two
indexes distinguishable in a demo.

**Expected.** Both items appear in the item list.

## Step 14 — READ it back

**What.** **Explore table items → Query**, source = the table itself:

- Partition key `orderId` = `ORD-2001`
- Sort key `createdAt` — leave blank, or *Equal to* `2026-09-09T10:00:00Z`

**Run**.

**Why.** This is a `Query` on the base table's primary key — the cheapest and
only fully precise access pattern DynamoDB offers. It answers "this one order",
and nothing else. Everything the base table cannot answer is why the GSIs exist.

**Expected.** Exactly one item. Click it to open the full item view.

## Step 15 — QUERY GSI 1 (CustomerOrdersIndex)

**What.** Same Query panel, change the source dropdown from the table to
**`CustomerOrdersIndex`**:

- Partition key `customerId` = `CUST-004`
- Sort order: **Descending**

**Run**.

**Why.** `customerId` is not part of the primary key, so this question —
*"every order this customer placed, newest first"* — is impossible to answer on
the base table without a full scan. The GSI gives it its own partition key and
reuses `createdAt` as the sort key, which is what makes "newest first" free.

Projection is `ALL`, so every attribute comes back without a second read against
the base table.

**Expected.** Both `ORD-2001` and `ORD-2002`, newest first, all attributes shown.

## Step 16 — QUERY GSI 2 (OrderStatusIndex)

**What.** Change the source to **`OrderStatusIndex`**:

- Partition key `orderStatus` = `PENDING`

**Run**.

**Why.** A different access pattern over the same items: *"everything currently
in this status"*, across all customers. This index uses an `INCLUDE` projection
rather than `ALL`, carrying only `customerId`, `totalAmount` and `currency`
alongside the keys — a smaller index costs less to store and write.

**Expected.** All pending orders. Note that `itemCount` is **absent** from the
results: it is deliberately not projected. That absence is the projection type
being visible, not a bug.

## Step 17 — UPDATE and watch it move between indexes

**What.** Open `ORD-2001` → **Edit** → change `orderStatus` from `PENDING` to
`SHIPPED` → **Save changes**.

Now re-run the Step 16 query for `PENDING`, then again for `SHIPPED`.

**Why.** This is the single most convincing thing to show in a live review. One
attribute edit on the base table causes the item to disappear from one partition
of `OrderStatusIndex` and appear in another, with no code involved — DynamoDB
maintains the index asynchronously. It demonstrates that the GSIs are live
infrastructure, not just declarations in a template.

**Expected.** `ORD-2001` is gone from the `PENDING` results and present in the
`SHIPPED` results. (Propagation is usually instant but is eventually consistent —
if it lags a second, re-run.)

## Step 18 — DELETE

**What.** Select `ORD-2002` in the item list → **Actions → Delete items →
Delete**. Then re-run the Step 15 query for `CUST-004`.

**Why.** Completes the CRUD cycle and shows the index shrinking with the table.

**Expected.** Only `ORD-2001` remains in the `CustomerOrdersIndex` results.

---

## Evidence checklist for the review

| Rubric item | Where to show it |
| --- | --- |
| DynamoDB defined in SAM template | `template.yaml` → `OrdersTable` |
| On-Demand billing | Console Overview, or the pipeline's verification step |
| Non-default table class | Console Overview: `DynamoDB Standard-IA` |
| Primary key + 2 attributes + 2 GSIs | Console Indexes tab; Steps 15–16 |
| SAM pipeline configured | `samconfig.toml`, `dev` and `prod` config environments |
| GitHub Actions functioning | Actions → a green `Deploy DEV` run |
| Multi-environment deployment | Two stacks, two tables, two buckets, two roles; the prod approval gate |
| CRUD via console | Steps 13–18 |
| Environment-scoped artifact buckets | S3 → the two `…-sam-artifacts-…` buckets side by side |
| Separate dev/prod pipelines | Two workflow files, one branch and one environment each |

Four browser tabs worth having open before the session starts: the DynamoDB item
explorer, the Actions run summary, the S3 bucket list, and the CloudFormation
stack list.

---

## Troubleshooting

Ordered by when you are likely to hit them.

### `Provider with url https://token.actions.githubusercontent.com already exists`

The account already has the GitHub OIDC provider — see [Step 1](#step-1--check-for-an-existing-github-oidc-provider).
Redeploy with `CreateOidcProvider=false`. The role's trust policy references the
provider by ARN string, so it binds to the existing one without owning it.

### `Cannot update stack in ROLLBACK_COMPLETE state`

A stack that fails during *create* can only be deleted, never updated.

```powershell
aws cloudformation delete-stack --stack-name week7-orders-oidc-dev
aws cloudformation wait stack-delete-complete --stack-name week7-orders-oidc-dev
```

### `Your session has expired or credentials have changed`

```powershell
aws sso login
aws sts get-caller-identity
```

`aws login`, which SAM's error text suggests, is not a real command.

### `failed to set variable: HTTP 404`

The GitHub Environment does not exist yet — see [Step 6](#step-6--create-the-two-github-environments).

### `bash: --query: command not found`

A PowerShell block with trailing backticks was pasted into Git Bash. Use `\` for
line continuation, or switch shells.

### `bash: sam: command not found`

SAM CLI is installed for Windows but not on Git Bash's PATH:

```bash
echo 'export PATH="/c/Program Files/Amazon/AWSSAMCLI/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

You do not need SAM locally for the pipeline — the runners install it themselves.

### `Error parsing parameter '--item': Expected: '=', received: 'i'`

The JSON file starts with a UTF-8 BOM (`ï»¿`). Windows PowerShell 5.1 writes one
with `Set-Content -Encoding utf8`. Write it without:

```powershell
[System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
```

The repo's scripts already do this.

### A push starts no workflow run

```powershell
gh run list --limit 10                  # has anything ever run?
gh workflow list                        # are the workflows registered?
git log --oneline origin/develop..develop   # did the push actually land?
```

- **Nothing registered** → the workflow files are not on the branch you pushed.
- **Registered but disabled** → `gh workflow enable "Deploy DEV"`, or
  Settings → Actions → *Allow all actions*.
- **Commits listed** → they are still local. Push them.

Force a run any time with `gh workflow run "Deploy DEV" --ref develop`.

### `Not authorized to perform sts:AssumeRoleWithWebIdentity`

STS was reached; the role's **trust policy** rejected the token. Run:

```bash
./scripts/diagnose-oidc.sh dev
```

**Most likely cause: immutable OIDC subjects.** GitHub is migrating accounts to
subjects that embed numeric ids:

```
classic     repo:sarsahcodes/week-7-dynamo-sam-app:ref:refs/heads/develop
immutable   repo:sarsahcodes@<ownerId>/week-7-dynamo-sam-app@<repoId>:ref:refs/heads/develop
```

A migrated account sends **only** the immutable form, so a trust policy listing
just the classic subject never matches. `bootstrap/github-oidc.yaml` accepts both
— redeploy if your role predates that change:

```bash
./scripts/bootstrap.sh dev
```

The **Show OIDC subject claim** step in `Deploy DEV` prints the subject GitHub
actually sent; compare it against the patterns the diagnostic lists.

Also check:

1. The workflow declares `permissions: id-token: write` — it does.
2. `AWS_DEPLOY_ROLE_ARN` matches the stack's `DeployRoleArn` output exactly. A
   stale ARN from a previous lab is a common cause.
3. The provider carries the `sts.amazonaws.com` audience:

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

## Tearing it down

Reverse order. Prod resists deletion by design: the table has
`DeletionProtectionEnabled` and the stack has `DeletionPolicy: Retain`.

```powershell
# 1. application stacks
aws cloudformation delete-stack --stack-name week7-orders-dev

aws dynamodb update-table --table-name week7-orders-prod --no-deletion-protection-enabled
aws cloudformation delete-stack --stack-name week7-orders-prod
aws dynamodb delete-table --table-name week7-orders-prod    # retained by the stack policy

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

**Why teardown needs its own section.** `delete-stack` alone leaves the prod
table and both buckets behind — `Retain` policies are there so a stack mistake
cannot destroy data, but they also mean the resources quietly keep costing money
after the lab is marked.
