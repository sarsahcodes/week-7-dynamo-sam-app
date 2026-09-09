# Week 7 — DynamoDB with AWS SAM, deployed by GitHub Actions

An Amazon DynamoDB **Orders** table defined entirely as infrastructure-as-code in an
AWS SAM template, deployed to two independent environments (`dev` and `prod`) by two
separate GitHub Actions pipelines, each using its own S3 artifact bucket and its own
short-lived OIDC deployment role.

---

## 1. What gets created

| | |
| --- | --- |
| Table name | `week7-orders-dev` / `week7-orders-prod` |
| Billing mode | `PAY_PER_REQUEST` (On-Demand) |
| Table class | `STANDARD_INFREQUENT_ACCESS` — **not** the default `STANDARD` |
| Partition key | `orderId` (String) |
| Sort key | `createdAt` (String) |
| Non-key attributes | `customerId`, `orderStatus`, `totalAmount`, `currency`, `itemCount` |
| GSI 1 | `CustomerOrdersIndex` — `customerId` (HASH) + `createdAt` (RANGE), projection `ALL` |
| GSI 2 | `OrderStatusIndex` — `orderStatus` (HASH) + `createdAt` (RANGE), projection `INCLUDE` |
| Extras | SSE at rest, TTL on `expiresAt`, PITR + deletion protection in prod only |

Both GSIs are keyed on **non-primary** attributes, which is what makes them useful:
`CustomerOrdersIndex` answers *"every order this customer placed, newest first"* and
`OrderStatusIndex` answers *"every order currently in this status"* — neither question
can be answered by a `Query` on the base table.

### A sample item

```json
{
  "orderId": "ORD-1001",
  "createdAt": "2026-09-01T09:15:00Z",
  "customerId": "CUST-001",
  "orderStatus": "PENDING",
  "totalAmount": 249.99,
  "currency": "GHS",
  "itemCount": 3
}
```

---

## 2. Repository layout

```
.
├── template.yaml                     # SAM template — the DynamoDB table
├── samconfig.toml                    # per-stage deploy config (dev / prod)
├── bootstrap/
│   ├── artifact-bucket.yaml          # IaC: one S3 artifact bucket per environment
│   └── github-oidc.yaml              # IaC: OIDC provider + per-env deploy role
├── .github/workflows/
│   ├── deploy-dev.yml                # develop branch → dev stack only
│   └── deploy-prod.yml               # main branch → prod stack only (approval gate)
├── scripts/
│   ├── bootstrap.sh                  # run once per environment
│   ├── seed-items.sh                 # load the sample orders
│   └── verify.sh                     # prove billing mode, table class, both GSIs
├── seed/
│   ├── sample-orders.json            # 5 orders across 3 customers and 4 statuses
│   └── console-item.json             # single item to paste into the console
└── docs/CONSOLE-VERIFICATION.md      # click-by-click CRUD walkthrough
```

---

## 3. One-time setup

### 3.1 Bootstrap AWS (run once per environment)

The artifact buckets and deploy roles are created **before** and **outside** the
application stack, so the application pipeline never needs permission to create IAM
roles or S3 buckets.

```bash
export AWS_REGION=eu-central-1

# Does this account already have the GitHub OIDC provider? (Shared lab
# accounts usually do - an account can only ever hold one.)
aws iam list-open-id-connect-providers

# If it exists, reuse it (the default):
./scripts/bootstrap.sh dev
./scripts/bootstrap.sh prod

# If it does not exist yet, let the FIRST run create it:
./scripts/bootstrap.sh dev true
./scripts/bootstrap.sh prod
```

The script checks for the provider itself and reuses it rather than failing, and
adds the `sts.amazonaws.com` audience if the existing provider is missing it.

This produces two buckets and two roles:

```
week7-orders-sam-artifacts-dev-<account-id>-<region>
week7-orders-sam-artifacts-prod-<account-id>-<region>

arn:aws:iam::<account-id>:role/week7-orders-github-deploy-dev
arn:aws:iam::<account-id>:role/week7-orders-github-deploy-prod
```

Each role's trust policy only accepts tokens whose `sub` claim matches its own branch
(`refs/heads/develop` for dev, `refs/heads/main` for prod) or its own GitHub
Environment, and each role's S3 and DynamoDB permissions are scoped to that
environment's bucket and table alone. The dev pipeline is cryptographically incapable
of touching prod.

### 3.2 Configure the GitHub Environments

Create two environments under **Settings → Environments**: `dev` and `prod`.
On `prod`, add yourself under *Required reviewers* — that is the manual approval gate.

Set three **variables** on each environment (the bootstrap script prints the values):

| Variable | dev | prod |
| --- | --- | --- |
| `AWS_REGION` | `eu-central-1` | `eu-central-1` |
| `ARTIFACT_BUCKET` | `…-artifacts-dev-…` | `…-artifacts-prod-…` |
| `AWS_DEPLOY_ROLE_ARN` | `…github-deploy-dev` | `…github-deploy-prod` |

Or let the script read the stack outputs and set them for you (needs the `gh`
CLI, authenticated with `gh auth login`):

```bash
./scripts/set-github-vars.sh dev
./scripts/set-github-vars.sh prod
```

It creates the GitHub Environment if it does not exist, sets all three
variables from the live CloudFormation outputs, and prints them back. Add the
required reviewer on `prod` in the GitHub UI afterwards - that part is manual.

No AWS access keys are stored anywhere. Credentials are minted per job by
`aws-actions/configure-aws-credentials` and expire in an hour.

---

## 4. Deploying

| Action | Result |
| --- | --- |
| Push to `develop` | `Deploy DEV` runs: lint → validate → build → deploy → verify |
| Push to `main` | `Deploy PROD` runs: lint → validate → **wait for approval** → change-set preview → deploy → verify |
| Manual run | Either workflow via *Actions → Run workflow* |

The normal flow is: work on `develop`, let the dev pipeline prove the template, then
open a PR into `main` and approve the prod deployment.

Each pipeline ends with a verification step that calls `DescribeTable` and **fails the
build** if the billing mode is not `PAY_PER_REQUEST`, the table class is not
`STANDARD_INFREQUENT_ACCESS`, or fewer than two GSIs exist. The results are written to
the workflow summary, so the rubric evidence is on every run.

### Deploying from a laptop instead

```bash
sam validate --lint
sam build
sam deploy --config-env dev --s3-bucket week7-orders-sam-artifacts-dev-<acct>-<region>
```

---

## 5. Verifying the table

Console walkthrough (insert, read, query both GSIs, update, delete):
**[docs/CONSOLE-VERIFICATION.md](docs/CONSOLE-VERIFICATION.md)**

From the CLI:

```bash
./scripts/seed-items.sh dev     # load 5 sample orders
./scripts/verify.sh dev         # config + a query against each GSI
```

---

## 6. How the two challenge items were met

**Environment-scoped artifact buckets.** `bootstrap/artifact-bucket.yaml` is deployed
once per stage and produces a bucket whose name embeds the environment, the account id
and the region. `samconfig.toml` sets `resolve_s3 = false` so SAM never falls back to
its shared managed bucket, and each workflow passes its own `--s3-bucket` and
`--s3-prefix`. Buckets are versioned, encrypted, TLS-only, fully public-blocked, with a
lifecycle rule that expires noncurrent artifact versions after 90 days.

**Separate dev and prod pipelines.** Instead of the single multi-stage workflow that
`sam pipeline init` generates, there are two independent files. Each declares one
branch trigger, one GitHub Environment, one role, one bucket and one stack; neither
references the other environment's resources. Prod additionally gets a concurrency
lock, a required-reviewer gate, and a change-set preview printed to the job summary
before anything is applied.

---

## 7. Rubric map

| Requirement | Where |
| --- | --- |
| DynamoDB defined in SAM template | `template.yaml` → `OrdersTable` |
| On-Demand billing | `BillingMode: PAY_PER_REQUEST` |
| Non-default table class | `TableClass: STANDARD_INFREQUENT_ACCESS` |
| Primary key + 2 attributes + 2 GSIs | `KeySchema`, `AttributeDefinitions`, `GlobalSecondaryIndexes` |
| SAM pipeline configured | `samconfig.toml` with `dev` / `prod` config environments |
| GitHub Actions functioning | `.github/workflows/deploy-dev.yml`, `deploy-prod.yml` |
| Multi-environment deployment | `Environment` parameter → separate stacks, tables, buckets, roles |
| CRUD via console | `docs/CONSOLE-VERIFICATION.md` |
| Environment-scoped artifact buckets | `bootstrap/artifact-bucket.yaml` + `resolve_s3 = false` |
| Separate dev/prod pipelines | two workflow files, one environment each |
