# Stable Windows signing access

This module creates exactly three managed resources: secret **metadata** named
`mokaid/desktop/stable/windows-updates`, the IAM role
`mokaid-desktop-signing-windows-stable`, and its sole inline policy. It has no
dependency on Azure, Apple signing, CloudFront or application services.

The role can only call `secretsmanager:DescribeSecret` and
`secretsmanager:GetSecretValue` on the exact ARN of its created secret. It cannot
read the macOS secret or write, publish, assume another role, or administer IAM.
No wildcard secret scope or customer-managed KMS permissions are granted. The
secret uses the default AWS-managed Secrets Manager key, a 30-day recovery
window and Terraform `prevent_destroy`. Secret storage/API usage is billable.

OIDC trust requires both the STS audience and exact subject
`repo:Yapio-Ltd/mokaid:environment:desktop-signing-stable`. Sessions last at most
one hour. The subject identifies the protected environment, not the operating
system: reviewers must check the tagged workflow and frozen tooling SHA. Both
matrix legs share environment approval, but the reviewed workflow selects a
distinct role and secret for each platform. Windows has no fallback to macOS.
The existing macOS module/policy remains unchanged.

## Provisioning and secret initialization

The production flag is `desktop_windows_signing_enabled`, disabled by default
and explicitly enabled in `environments/prod/desktop.auto.tfvars`. Keep the flag
enabled after provisioning. Review a targeted plan for this module, expecting
**three creates, no updates and no deletions** on its first deployment:

```sh
umask 077
windows_plan_dir=$(mktemp -d /private/tmp/mokaid-windows-signing-plan.XXXXXX)
export TF_DATA_DIR="$windows_plan_dir/data"
terraform -chdir=infra/terraform/environments/prod init -input=false -lockfile=readonly
terraform -chdir=infra/terraform/environments/prod plan -input=false -lock-timeout=60s \
  -target='module.desktop_windows_signing[0]' \
  -out="$windows_plan_dir/windows-signing.tfplan"
```

Use the existing production backend and locking. This scoped plan is independent
of the avatar worker image and Azure validation; it does not certify the rest of
production is drift-free. Keep plans private because they may contain production
state. An unexpected existing role/secret requires investigation before import;
do not overwrite or silently adopt it.

The module does not read or create secret **versions**, accept private values as
inputs, or output credentials. After a reviewed apply, a trusted operator must
initialize the Windows secret outside Terraform with a JSON object containing
**only** `update_ed25519_seed`. Copy the existing stable channel seed in memory;
never generate a different key for Windows, print/export the macOS secret, or
copy its other fields. Verify the derived Ed25519 public key against both the
versioned stable update public key and the protected GitHub environment. Refuse
conflicting existing Windows content. An empty metadata-only secret cannot sign.

Then use the module outputs to configure the protected stable environment:

- `MOKAID_WINDOWS_SIGNING_AWS_ROLE_ARN`
- `MOKAID_WINDOWS_SIGNING_SECRET_ARN`
- `MOKAID_AWS_REGION=il-central-1`

The desired GitHub policy keeps new identifiers `null` (unmanaged) until the
resources and seed are verified; fill in actual outputs before reconciliation.
Do not alter `MOKAID_SIGNING_AWS_ROLE_ARN` or `MOKAID_MACOS_SIGNING_SECRET_ARN`.
Azure Authenticode and the AWS update signature are separate required checks.

## Azure OIDC configuration

The Windows job already uses Azure OIDC and remote Artifact Signing. No Azure
client secret, password, or signing certificate belongs in the Windows AWS
secret. After Azure identity validation and provisioning, configure:

- `MOKAID_AZURE_CLIENT_ID`, `MOKAID_AZURE_TENANT_ID`, `MOKAID_AZURE_SUBSCRIPTION_ID`
- `MOKAID_AZURE_SIGNING_ENDPOINT=https://neu.codesigning.azure.net`
- `MOKAID_AZURE_SIGNING_ACCOUNT`, `MOKAID_AZURE_CERTIFICATE_PROFILE`

The reconciler validates these public identifiers and pins the endpoint to the
reviewed North Europe service. The Azure federation audience is
`api://AzureADTokenExchange`, issuer is
`https://token.actions.githubusercontent.com`, and subject matches the stable
environment above. Grant only Artifact Signing Certificate Profile Signer at
the exact PublicTrust profile scope. Organization validation and Basic account
activation remain explicit Azure provisioning steps, outside this AWS module.
See [Microsoft OIDC guidance](https://learn.microsoft.com/en-us/azure/developer/github/connect-from-azure-openid-connect)
and [Artifact Signing roles](https://learn.microsoft.com/en-us/azure/artifact-signing/tutorial-assign-roles).

## Offline validation

```sh
terraform -chdir=infra/terraform/modules/desktop-windows-signing init -backend=false -input=false -lockfile=readonly
terraform -chdir=infra/terraform/modules/desktop-windows-signing validate
terraform -chdir=infra/terraform/modules/desktop-windows-signing test
python -m pytest -c infra/github/pyproject.toml infra/github/tests
```

Mock-provider tests verify actual policy JSON, exact trust, account/region guards
and immutable identity tags. Workflow tests ensure each platform selects only
its own role/secret; source-contract tests prevent secret value/version access
from entering the module. CI executes these checks automatically.
