# Stable desktop signing identity — module 1.0.0

This module provisions exactly one IAM role, `mokaid-desktop-signing-stable`, and
one inline policy. It is independent of CloudFront, ACM, S3 and ECS. It does not
create, read, rotate, export or manage a signing-secret value, and it does not
sign or publish a release.

The role trusts the existing GitHub OIDC provider with **both** exact claims:

- audience `sts.amazonaws.com`;
- subject `repo:Yapio-Ltd/mokaid:environment:desktop-signing-stable` in production.

Its only granted actions are `secretsmanager:DescribeSecret` and
`secretsmanager:GetSecretValue` on the one supplied full stable macOS secret ARN.
There are no wildcard resources, beta/Windows/application secrets, publishing
permissions, `iam:PassRole`, write actions or customer-managed KMS permissions.
The existing secret uses the AWS-managed Secrets Manager key. A future custom
KMS key requires a separate reviewed change; do not broaden this role to `kms:*`.

Sessions are capped at one hour. Unsigned native compilation and tests happen in
separate jobs without OIDC or signing environments; only the protected signing
job assumes this role, after artifact restoration and tool installation. Signing
must finish within the remaining credential lifetime or renew credentials before
continuing. Environment approval authorizes the entire signing job, including
its earlier steps; review the tagged workflow and the frozen trusted tooling SHA
before approval. IAM cannot establish that the workflow contents were reviewed.
Do not bypass the reviewer/ref restrictions described in
[the GitHub policy](../../../github/README.md).

## Interface

| Input | Contract |
| --- | --- |
| `github_oidc_provider_arn` | Exact existing `token.actions.githubusercontent.com` provider ARN |
| `github_repository` | Exact case-sensitive `owner/repository`, no wildcard or subject suffix |
| `macos_signing_secret_arn` | One complete `mokaid/desktop/stable/macos-signing-XXXXXX` ARN in `il-central-1` |
| `tags` | Optional extra tags; fixed ownership/channel tags cannot be overridden |

The provider, secret and authenticated Terraform caller must share an AWS
account. Outputs `signing_role_arn` and `macos_signing_secret_arn` contain only
public identifiers. The module has no `aws_secretsmanager_secret_version` data
source and no secret-version resources; private material cannot enter its state.
It inherits AWS provider configuration from its caller, with `~> 5.100` pinned
and a committed provider lockfile for standalone tests. Terraform 1.10+ is required.

## Validation without AWS mutations

From the repository root:

```sh
terraform -chdir=infra/terraform/modules/desktop-signing init -backend=false -input=false -lockfile=readonly
terraform -chdir=infra/terraform/modules/desktop-signing fmt -check
terraform -chdir=infra/terraform/modules/desktop-signing validate
terraform -chdir=infra/terraform/modules/desktop-signing test
tflint --chdir=infra/terraform/modules/desktop-signing
```

Every test uses a mocked AWS provider and `command = plan`. Tests inspect the
module's real generated JSON, not a mock IAM policy document, and reject secret
scope expansion, incorrect trust, cross-account inputs and mutable identity tags.

## Production composition and scoped plan

`environments/prod/desktop_signing.tf` keeps provisioning disabled by default with
`desktop_stable_signing_enabled=false`. Its exact non-secret secret ARN and GitHub
repository are reviewed production configuration. It also refuses a second stable
signer managed through the older `desktop_signing_secret_arns.stable` map. The
existing prod root supplies its encrypted S3 state and DynamoDB lock; do not create
a second production state or disable locking for this module.

After explicit approval of the exact IAM grant, prepare a **targeted plan only**:

```sh
umask 077
signing_plan_dir=$(mktemp -d /private/tmp/mokaid-stable-signing-plan.XXXXXX)
export TF_DATA_DIR="$signing_plan_dir/data"
terraform -chdir=infra/terraform/environments/prod init -input=false -lockfile=readonly
terraform -chdir=infra/terraform/environments/prod plan -input=false -lock-timeout=60s \
  -target='module.desktop_stable_signing[0]' \
  -var='desktop_stable_signing_enabled=true' -out="$signing_plan_dir/signing.tfplan"
```

Resource targeting is exceptional here: the unrelated production stack has known
ECS drift and an externally blocked CloudFront creation. Do not apply a global
production plan to provision this role. Review the saved plan for **exactly two
managed creates, zero updates and zero deletions**, restricted to this module;
metadata data-source reads are expected. A targeted plan is not proof that the
rest of production is drift-free. Plan files may contain existing production
state, so keep the temporary directory private and never upload a full plan or
JSON as a public artifact.

No `apply` is run by these examples. The operator must review and separately apply
that exact saved plan, then persist `desktop_stable_signing_enabled=true` in the
reviewed production configuration before any later plan. Leaving the flag false
after provisioning would plan removal of the role. Never re-create, overwrite or
adopt an unexpected existing role silently; inspect it and obtain approval for a
separate import if appropriate.

After apply, verify the trust policy and sole inline policy using IAM read APIs,
then set only `MOKAID_SIGNING_AWS_ROLE_ARN` and the existing
`MOKAID_MACOS_SIGNING_SECRET_ARN` in the protected stable GitHub environment. The
role does not remove public-release blockers: Windows identity, update keys,
signed installers, verified update feeds and distribution availability remain
separate requirements. Keep `MOKAID_DESKTOP_ONLY=false` until all are satisfied.
