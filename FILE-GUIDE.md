# File guide

What every file in this repository is for, and what the meaningful lines inside
it actually mean. Written to be read alongside the files themselves.

```
.
├── template.yaml                 # THE deliverable: the DynamoDB table
├── samconfig.toml                # per-environment deploy settings
├── bootstrap/
│   ├── artifact-bucket.yaml      # one S3 artifact bucket per environment
│   └── github-oidc.yaml          # OIDC provider + one deploy role per environment
├── .github/workflows/
│   ├── deploy-dev.yml            # develop -> dev
│   └── deploy-prod.yml           # main -> prod, with approval
├── scripts/                      # one-time setup, seeding, verification, diagnostics
├── seed/                         # sample data
├── .vscode/                      # editor settings so the templates lint cleanly
└── .gitignore
```

---

# 1. `template.yaml` — the SAM template

The only file the rubric's *Infrastructure as Code* section (40 points) grades
directly. Everything else exists to get this deployed.

## Header

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Transform: AWS::Serverless-2016-10-31
```

`Transform` is what makes this a **SAM** template rather than plain
CloudFormation. It tells CloudFormation to run the Serverless transform macro on
the template before deploying, expanding any `AWS::Serverless::*` resources into
ordinary CloudFormation.

This template declares a plain `AWS::DynamoDB::Table` rather than SAM's
`AWS::Serverless::SimpleTable`, because `SimpleTable` supports only a single
partition key — no sort key, no GSIs, no table class. A SAM template is a
superset of CloudFormation, so using the native resource type is normal and still
counts as SAM.

## Parameters

```yaml
Parameters:
  Environment:
    AllowedValues: [dev, prod]
  AppName:
    Default: week7-orders
    AllowedPattern: '^[a-z0-9][a-z0-9-]{2,32}$'
```

| | |
| --- | --- |
| `Environment` | The single input that makes one template produce two isolated deployments. It feeds the table name, the tags, and the protection settings. |
| `AllowedValues` | CloudFormation rejects anything else *before* creating resources, so a typo cannot create a `week7-orders-prodd` table. |
| `AllowedPattern` | DynamoDB and S3 naming rules are stricter than CloudFormation's. Enforcing the pattern here turns a late, cryptic API error into an immediate parameter-validation error. |

## Conditions

```yaml
Conditions:
  IsProd: !Equals [!Ref Environment, prod]
```

A named boolean, evaluated at deploy time, used further down with `!If`. This is
how one template gives production stronger settings than development without a
second template to keep in sync.

## The table

### Deletion behaviour

```yaml
DeletionPolicy: !If [IsProd, Retain, Delete]
UpdateReplacePolicy: !If [IsProd, Retain, Delete]
```

- **`DeletionPolicy`** — what happens to the table if the *stack* is deleted.
  `Retain` in prod means the table survives; `Delete` in dev means the
  environment stays disposable.
- **`UpdateReplacePolicy`** — what happens if a change forces CloudFormation to
  *replace* the table (renaming it, or altering the key schema). Without this,
  such a change silently destroys production data. These two are separate
  properties because they cover genuinely different accidents.

### Name and billing

```yaml
TableName: !Sub '${AppName}-${Environment}'
BillingMode: PAY_PER_REQUEST
```

- **`!Sub`** substitutes parameter values into a string, so the same template
  yields `week7-orders-dev` and `week7-orders-prod`.
- **`PAY_PER_REQUEST`** is On-Demand billing (**5 rubric points**). You pay per
  request with no capacity to provision. The alternative, `PROVISIONED`, requires
  read and write capacity units and is the default when the property is omitted.

### Table class

```yaml
TableClass: STANDARD_INFREQUENT_ACCESS
```

**5 rubric points**, and the requirement most easily missed: the lab asks for a
*non-default* storage class. The default is `STANDARD`; this is the other one.
Standard-IA trades roughly 60% cheaper storage for higher per-request cost, which
suits data that is written and rarely read. The console displays it as
*DynamoDB Standard-IA*.

### Attribute definitions

```yaml
AttributeDefinitions:
  - { AttributeName: orderId,     AttributeType: S }
  - { AttributeName: createdAt,   AttributeType: S }
  - { AttributeName: customerId,  AttributeType: S }
  - { AttributeName: orderStatus, AttributeType: S }
```

A frequent misunderstanding: this is **not** a schema. DynamoDB is schemaless,
and items may carry any attributes at all. `AttributeDefinitions` declares only
the attributes used as **keys** — of the table or of an index — because those
need a fixed type for indexing.

That is why `totalAmount`, `currency` and `itemCount` are absent here despite
being present on every item. They are not keys.

`S` is String, `N` is Number, `B` is Binary. Every key here is `S`; `createdAt`
is an ISO-8601 string precisely so that lexicographic sorting equals
chronological sorting.

The attribute is named `orderStatus` rather than `status` deliberately: `status`
is a DynamoDB reserved word, and querying it requires
`ExpressionAttributeNames` gymnastics in every query.

### Primary key

```yaml
KeySchema:
  - { AttributeName: orderId,   KeyType: HASH }
  - { AttributeName: createdAt, KeyType: RANGE }
```

- **`HASH`** is the partition key. It determines which physical partition the
  item lives on.
- **`RANGE`** is the sort key, optional in this lab. Items sharing a partition
  key are stored sorted by it, which makes range queries (`begins_with`,
  `between`, "newest first") cheap.

Together they form a **composite primary key** and must be unique per item.

### Global Secondary Index 1

```yaml
- IndexName: CustomerOrdersIndex
  KeySchema:
    - { AttributeName: customerId, KeyType: HASH }
    - { AttributeName: createdAt,  KeyType: RANGE }
  Projection:
    ProjectionType: ALL
```

Answers *"every order this customer placed, newest first"*. On the base table
that question needs a full `Scan`, because `customerId` is not part of the
primary key. The GSI gives it its own partition key.

`ProjectionType: ALL` copies every attribute into the index, so a query is
answered entirely from the index with no second read.

### Global Secondary Index 2

```yaml
- IndexName: OrderStatusIndex
  KeySchema:
    - { AttributeName: orderStatus, KeyType: HASH }
    - { AttributeName: createdAt,   KeyType: RANGE }
  Projection:
    ProjectionType: INCLUDE
    NonKeyAttributes: [customerId, totalAmount, currency]
```

Answers *"every order currently in this status"*, across all customers.

`INCLUDE` is the middle of the three projection types:

| Type | What is copied into the index |
| --- | --- |
| `KEYS_ONLY` | Index keys + table keys only — smallest, cheapest |
| `INCLUDE` | Those plus the attributes you name |
| `ALL` | Everything |

A projection is a genuine copy: every write to the table writes to each index
too. Using `INCLUDE` here keeps that write cost down. The visible consequence is
that a query on this index returns no `itemCount` — it is deliberately not
projected, which is worth pointing out in a demo.

Both indexes are keyed on **non-primary attributes**, which is what the rubric
asks for.

### Operational settings

```yaml
SSESpecification:
  SSEEnabled: true
PointInTimeRecoverySpecification:
  PointInTimeRecoveryEnabled: !If [IsProd, true, false]
DeletionProtectionEnabled: !If [IsProd, true, false]
TimeToLiveSpecification:
  AttributeName: expiresAt
  Enabled: true
```

| | |
| --- | --- |
| `SSEEnabled` | Encryption at rest with an AWS-owned key. No cost, no key management. |
| Point-in-time recovery | Continuous backups, restorable to any second in the last 35 days. Prod only, because it is billed per GB. |
| `DeletionProtectionEnabled` | Blocks `DeleteTable` outright until switched off. Separate from `DeletionPolicy`: one guards the API call, the other guards the stack operation. |
| TTL on `expiresAt` | If an item carries an `expiresAt` epoch timestamp, DynamoDB deletes it free of charge after that time. Items without the attribute are untouched — which is all of the sample data. |

### Outputs

```yaml
Outputs:
  TableName:
    Value: !Ref OrdersTable
    Export:
      Name: !Sub '${AWS::StackName}-TableName'
```

- **`!Ref`** on a DynamoDB table returns its name; **`!GetAtt OrdersTable.Arn`**
  returns the ARN. What `!Ref` returns is resource-type specific.
- **`Export`** publishes the value account-wide so another stack could import it
  with `Fn::ImportValue`. Prefixing with `${AWS::StackName}` keeps the dev and
  prod exports from colliding, since export names must be unique per region.

---

# 2. `samconfig.toml` — deployment settings per environment

Saves you from retyping a dozen flags, and is what the rubric means by
*SAM pipeline configured*.

```toml
[dev.deploy.parameters]
stack_name          = "week7-orders-dev"
region              = "eu-central-1"
capabilities        = "CAPABILITY_IAM"
resolve_s3          = false
s3_prefix           = "week7-orders/dev"
parameter_overrides = "Environment=\"dev\" AppName=\"week7-orders\""
```

The table name pattern is `[<config-env>.<command>.parameters]`, selected at run
time with `sam deploy --config-env dev`.

| Key | Meaning |
| --- | --- |
| `stack_name` | Separate stacks per environment — the root of the isolation |
| `capabilities` | Acknowledges that the stack may create IAM resources |
| **`resolve_s3 = false`** | **The key line for the extra-credit.** When true, SAM silently creates and reuses one managed bucket for every deployment in the account. Setting it false forces an explicit `--s3-bucket`, which is what makes the per-environment buckets real rather than decorative. |
| `s3_prefix` | Keeps each environment's artifacts in its own key prefix as well as its own bucket |
| `parameter_overrides` | Supplies the template's `Environment` parameter. The escaped quotes are SAM's required format. |

`s3_bucket` is deliberately absent: the bucket name embeds the AWS account id,
which a committed file should not assume. The workflows pass it at run time from
a GitHub Environment variable.

---

# 3. `bootstrap/artifact-bucket.yaml`

Deployed once per environment. Produces the S3 bucket that SAM uploads packaged
templates to — one of the two extra-credit items (**10 points**).

```yaml
BucketName: !Sub '${AppName}-sam-artifacts-${Environment}-${AWS::AccountId}-${AWS::Region}'
```

S3 bucket names are globally unique across all AWS customers, so the account id
and region are appended. `AWS::AccountId` and `AWS::Region` are pseudo-parameters
— values CloudFormation supplies at deploy time without being declared.

| Block | Why |
| --- | --- |
| `PublicAccessBlockConfiguration` (all four true) | Belt and braces against a bucket policy or ACL ever making artifacts public |
| `BucketEncryption` with `BucketKeyEnabled` | Encryption at rest; the bucket key reduces per-object KMS calls |
| `VersioningConfiguration: Enabled` | SAM writes each package under a new key, and versioning lets you roll back to a prior artifact |
| `OwnershipControls: BucketOwnerEnforced` | Disables ACLs entirely — the modern S3 default, access is governed by policy alone |
| `LifecycleConfiguration` | Expires noncurrent versions after 90 days and aborts incomplete multipart uploads after 7. Without this, a versioned artifact bucket grows without limit. |
| `DeletionPolicy: Retain` | Deleting the stack does not delete deployment history |

The bucket policy has two statements:

- **`DenyInsecureTransport`** — denies every action when `aws:SecureTransport` is
  false, i.e. plain HTTP. An explicit `Deny` overrides any `Allow` anywhere.
- **`AllowCloudFormationRead`** — lets the CloudFormation service read templates
  from the bucket, restricted with `aws:SourceAccount` so no other account's
  CloudFormation can be tricked into reading it (the confused-deputy problem).

---

# 4. `bootstrap/github-oidc.yaml`

The security core of the whole setup, and the reason no AWS keys exist in GitHub.

## How OIDC replaces stored keys

A GitHub Actions job can ask GitHub for a short-lived, signed JSON Web Token
describing itself: which repository, which branch, which environment. It hands
that token to AWS STS. STS verifies the signature against the registered identity
provider, checks the token's claims against the role's trust policy, and returns
temporary credentials that expire in an hour.

Nothing is stored. Nothing can leak. A stolen workflow file is useless without
GitHub itself signing a matching token.

## The provider

```yaml
GitHubOidcProvider:
  Type: AWS::IAM::OIDCProvider
  Condition: ShouldCreateOidcProvider
  Properties:
    Url: https://token.actions.githubusercontent.com
    ClientIdList: [sts.amazonaws.com]
```

An account can hold exactly **one** provider for that URL, so `CreateOidcProvider`
defaults to `false` — most training accounts already have one from an earlier lab,
and creating a second fails the stack with `AlreadyExists`.

`ClientIdList` is the **audience**. The token must claim `aud: sts.amazonaws.com`;
if the existing provider is missing this entry, every assume-role attempt fails.

## The trust policy — where deployments are actually authorised

```yaml
Condition:
  StringEquals:
    'token.actions.githubusercontent.com:aud': 'sts.amazonaws.com'
  StringLike:
    'token.actions.githubusercontent.com:sub':
      - 'repo:<org>/<repo>:ref:refs/heads/develop'
      - 'repo:<org>/<repo>:environment:dev'
      - 'repo:<org>@*/<repo>@*:ref:refs/heads/develop'
      - 'repo:<org>@*/<repo>@*:environment:dev'
```

The `sub` claim identifies the exact workflow run. Only a run on the named branch
of the named repository, or one bound to the matching GitHub Environment, can
assume this role. The dev pipeline cannot obtain prod credentials — enforced by
STS, not by convention.

**Why four patterns and not two.** GitHub is migrating accounts to *immutable*
subjects that embed numeric ids:

```
classic     repo:sarsahcodes/week-7-dynamo-sam-app:ref:refs/heads/develop
immutable   repo:sarsahcodes@142625676/week-7-dynamo-sam-app@98765432:ref:refs/heads/develop
```

A migrated account sends **only** the immutable form, so a policy listing just
the classic subject fails with *"Not authorized to perform
sts:AssumeRoleWithWebIdentity"*. Listing both covers either case. Setting the
`GitHubOrgId` parameter replaces the `@*` wildcard with the real owner id; the
owner **name** stays pinned either way, so scoping holds regardless.

## The permissions

Three inline policies, each scoped to one environment:

| Policy | Scope |
| --- | --- |
| `cloudformation-stack-access` | Only `stack/week7-orders-<env>/*`, plus the SAM transform ARN and a few account-wide read actions |
| `artifact-bucket-access` | Only that environment's bucket ARN and its objects |
| `dynamodb-table-access` | Only `table/week7-orders-<env>` and `table/week7-orders-<env>/index/*` |

Notably absent: any ability to create IAM roles or S3 buckets. That is why
bootstrap is a separate manual step — the pipeline is not permitted to escalate
its own privileges.

---

# 5. `.github/workflows/deploy-dev.yml` and `deploy-prod.yml`

Two files, not one. The auto-generated `sam pipeline init` workflow puts both
stages in a single file; splitting them is the second extra-credit item
(**10 points**). Each declares one branch, one environment, one role, one bucket
and one stack, and references nothing belonging to the other.

## Triggers and permissions

```yaml
on:
  push:
    branches: [develop]
  workflow_dispatch:

permissions:
  id-token: write
  contents: read

concurrency:
  group: deploy-dev
```

| | |
| --- | --- |
| `branches: [develop]` | The whole of the environment separation at the trigger level |
| `workflow_dispatch` | Adds a manual *Run workflow* button — useful when a demo needs a run on cue |
| **`id-token: write`** | Required. Without it the job cannot request an OIDC token at all, and assume-role fails with a misleading permissions error. |
| `contents: read` | Everything else is dropped to read-only, following least privilege |
| `concurrency` | Two simultaneous deploys to the same stack would collide in CloudFormation; this serialises them |

## The `validate` job

Runs `cfn-lint` and `sam validate` with **no AWS credentials at all**. A broken
template is caught before anything touches AWS, and a pull request can be checked
without granting it deployment access.

## The `deploy` job

```yaml
environment: dev
```

Binds the job to the GitHub Environment, which supplies `vars.AWS_REGION`,
`vars.ARTIFACT_BUCKET` and `vars.AWS_DEPLOY_ROLE_ARN` — and, on prod, enforces
the reviewer gate before the job starts.

Steps:

1. **Show OIDC subject claim** — decodes the token locally and prints `sub`,
   `aud`, `repository`, `ref`. Purely diagnostic, marked `continue-on-error` so
   it can never fail a deployment. When assume-role fails, this is the fastest
   way to see what GitHub actually sent versus what the trust policy accepts.
2. **configure-aws-credentials** — the actual OIDC exchange.
3. **sam build** — copies the template into `.aws-sam/build/`. Falls back to the
   source template if the build finds nothing to build, since this stack contains
   no Lambda functions.
4. **sam deploy** — `--config-env` supplies the settings, `--s3-bucket` the one
   value the config cannot know.
5. **Verify** — calls `DescribeTable` and **fails the build** unless billing mode
   is `PAY_PER_REQUEST`, the class is `STANDARD_INFREQUENT_ACCESS`, and there are
   at least two GSIs. The values are written to the run summary, so every run
   carries its own rubric evidence.

## What prod adds

- `environment: prod` with required reviewers — the run pauses for approval.
- A change-set preview created with `--no-execute-changeset` and printed to the
  summary, so the diff is visible before it is applied.

---

# 6. `scripts/`

| Script | Purpose |
| --- | --- |
| `bootstrap.sh <env> [true]` | Deploys both bootstrap stacks for one environment, detects and reuses an existing OIDC provider, adds the `sts.amazonaws.com` audience if missing, then prints the values needed in GitHub |
| `set-github-vars.sh <env>` | Reads the stack outputs and sets the three GitHub Environment variables — removes hand-copying as a failure mode |
| `deploy.ps1 -Environment <env>` | Manual validate → build → deploy on Windows, resolving the bucket from the stack rather than hardcoding the account id |
| `seed-items.sh` / `seed-items.ps1` | Loads `seed/sample-orders.json` into the table |
| `verify.sh` / `verify.ps1` | Prints the table configuration, then queries each GSI once |
| `diagnose-oidc.sh <env>` | For *"Not authorized to perform sts:AssumeRoleWithWebIdentity"*: prints the role ARN, the trust policy, probes it with the classic, environment and immutable subject forms, and checks the provider and its audience |

Two Windows-specific details appear in the PowerShell scripts and are worth
knowing about:

- The AWS CLI on Windows mishandles inline JSON containing nested quotes, so
  every payload is written to a temp file and passed as `file://`.
- Windows PowerShell 5.1's `Set-Content -Encoding utf8` writes a **BOM**, and the
  AWS CLI rejects a JSON file that starts with one
  (`Error parsing parameter '--item'`). The scripts use
  `[System.IO.File]::WriteAllText` with `UTF8Encoding($false)` instead.

---

# 7. `seed/`

| File | Format | Use |
| --- | --- | --- |
| `sample-orders.json` | DynamoDB typed JSON (`{"S": "..."}`) | Five orders across three customers and four statuses, loaded by the seed scripts. Enough variety that both GSI queries return visibly different result sets. |
| `console-item.json` | Plain JSON | A single item for pasting into the console's *Create item → JSON view* |

The two formats exist because they serve different consumers. The CLI's
`put-item` requires typed JSON, where the type is explicit and **numbers are
quoted** (`"N": "599.99"`) so no precision is lost to a float. The console form
accepts plain JSON when *View DynamoDB JSON* is toggled off.

---

# 8. `.vscode/` and `.gitignore`

`.vscode/settings.json` declares CloudFormation's YAML short-form intrinsic tags
(`!Sub`, `!Ref`, `!GetAtt`, `!If`, …). The generic YAML language server does not
know them and otherwise reports *"Unresolved tag: !Sub"* on every line that uses
one. `yaml.schemas` is deliberately left empty: there is no CloudFormation/SAM
schema for that extension, and attaching an unrelated one makes it reject valid
template keys. Real validation comes from `cfn-lint`, in CI and via the
recommended extension.

`.gitignore` excludes `.aws-sam/` (build output), Python and editor artefacts,
`docs/`, and anything credential-shaped — `*.pem`, `.env`, `credentials`.

---

# Where the rubric points live

| Requirement | File |
| --- | --- |
| DynamoDB defined in SAM template | `template.yaml` |
| On-Demand billing | `template.yaml` → `BillingMode` |
| Non-default table class | `template.yaml` → `TableClass` |
| Primary key + 2 attributes + 2 GSIs | `template.yaml` → `KeySchema`, `AttributeDefinitions`, `GlobalSecondaryIndexes` |
| SAM pipeline configured | `samconfig.toml` |
| GitHub Actions functioning | `.github/workflows/*.yml` |
| Multi-environment deployment | `Environment` parameter + separate stacks, buckets, roles |
| Environment-scoped artifact buckets | `bootstrap/artifact-bucket.yaml` + `resolve_s3 = false` |
| Separate dev/prod pipelines | two workflow files, one environment each |
