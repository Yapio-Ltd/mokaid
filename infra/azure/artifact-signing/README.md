# Azure Artifact Signing: account and identity preparation

`phase-a.json` is a subscription-scope ARM template for one Basic signing account
in North Europe, a dedicated resource group, a user-assigned managed identity,
its GitHub federated credential, and one human Identity Verifier assignment on
the signing account. Including the nested deployment record, there are six
resource IDs. The template is incremental and role names are deterministic.

It does not create a certificate profile, validate an organization, grant the CI
identity any Azure resource role, configure GitHub, or sign/publish software.
No application registration, client secret, password or private signing key is
required. The CI identity may not yet pass Azure login subscription discovery:
its profile-scoped signing permission comes in Phase B.

## Cost and identity prerequisite

Creating a Basic account starts billing: US$9.99/month for 5,000 signatures, then
US$0.005 per extra signature, before tax. The monthly base charge is not prorated.
Count signed files, not releases. Confirm the legal organization and this paid
activation before deploying. See [official pricing](https://azure.microsoft.com/en-us/pricing/details/artifact-signing/).

Public Trust supports organizations in Israel. Individual validation is limited
to the US/Canada. A paid Azure subscription is required; organization validation
does not require an organization-type billing account. Submit the exact legal
entity and representative information through the Azure portal. Do not infer
legal details from a product or billing label. Identity review can take 1–20
business days and may require further documents. [Microsoft setup guidance](https://learn.microsoft.com/en-us/azure/artifact-signing/quickstart).

## Scope and trust

The managed identity accepts exactly:

- issuer `https://token.actions.githubusercontent.com`;
- audience `api://AzureADTokenExchange`;
- subject `repo:Yapio-Ltd/mokaid:environment:desktop-signing-stable`.

The only assignment is **Artifact Signing Identity Verifier**
(`4339b7cf-9826-4e41-b4ed-c7f4505dac08`) to the human operator, scoped to the
account. Owner does not replace this explicit role for identity verification.
The built-in role ID was verified against Azure; retain the restricted allowed
value. No signer, contributor or owner role is assigned to CI in this phase.

GitHub environment approval and reviewed workflow code remain necessary. The
federated subject identifies the environment, not the runner OS. AWS access to
the update seed is separate; see the [Windows secret module](../../terraform/modules/desktop-windows-signing/README.md).

## Private parameters and validation

Copy `parameters.example.json` outside the checkout into a private directory.
Replace the three zero UUIDs and placeholder account name with verified values.
Keep operator-specific parameters, full validation outputs and deployment plans
out of the public repository. Account names are global: check availability before
activation. The configured region is pinned to `northeurope` and its endpoint to
`https://neu.codesigning.azure.net`.

Use an existing authenticated Azure CLI; no password or token should appear in
shell arguments. Set `AZURE_SIGNING_PARAMETERS` to the private absolute path.
The following checks read only non-secret technical identifiers and refuse a
subscription, tenant, or signed-in human mismatch before template validation:

```sh
AZURE_SIGNING_PARAMETERS=/absolute/private/path/parameters.json
AZURE_SIGNING_SUBSCRIPTION=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["parameters"]["subscriptionId"]["value"])' "$AZURE_SIGNING_PARAMETERS")
AZURE_SIGNING_TENANT=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["parameters"]["tenantId"]["value"])' "$AZURE_SIGNING_PARAMETERS")
AZURE_SIGNING_OPERATOR=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["parameters"]["operatorObjectId"]["value"])' "$AZURE_SIGNING_PARAMETERS")
test "$(az account show --subscription "$AZURE_SIGNING_SUBSCRIPTION" --query id -o tsv)" = "$AZURE_SIGNING_SUBSCRIPTION" && \
  test "$(az account show --subscription "$AZURE_SIGNING_SUBSCRIPTION" --query tenantId -o tsv)" = "$AZURE_SIGNING_TENANT" && \
  test "$(az account show --subscription "$AZURE_SIGNING_SUBSCRIPTION" --query state -o tsv)" = Enabled && \
  test "$(az ad signed-in-user show --query id -o tsv)" = "$AZURE_SIGNING_OPERATOR" && \
  az deployment sub validate --subscription "$AZURE_SIGNING_SUBSCRIPTION" \
    --location northeurope --name mokaid-signing-phase-a-validation \
    --template-file infra/azure/artifact-signing/phase-a.json \
    --parameters "@$AZURE_SIGNING_PARAMETERS" --validation-level Template --only-show-errors
```

Template validation is not deployment. It skips provider preflight and RBAC
checks and does not prove a globally unique account name is available. Before an
approved deployment, register required providers, check name availability, and
run provider-level validation and what-if against the same subscription and
parameters. Inspect for the six expected resource IDs and no unrelated changes.
`tenantId` is an expected context, not a request to create/switch tenants;
subscription-scoped resource-group creation uses the CLI target subscription.
Never run the nested deployment against a different `subscriptionId` parameter.

Offline structural/policy checks run in the existing CI policy job:

```sh
python -m pytest -c infra/github/pyproject.toml infra/github/tests/test_azure_signing_template.py
```

## Phase B and workflow outputs

After Microsoft approves the portal identity validation, create one PublicTrust
certificate profile. Grant **Artifact Signing Certificate Profile Signer**
(`2837e146-70d7-4cfd-ad55-7efa6464f958`) to the managed identity at that exact
profile resource scope, not at account/subscription scope. Verify the live role
name/ID again before applying. A test/private profile cannot replace public
trust. See [Microsoft role guidance](https://learn.microsoft.com/en-us/azure/artifact-signing/tutorial-assign-roles).

Phase A outputs the five non-secret variables expected by the existing workflow:
`MOKAID_AZURE_CLIENT_ID`, `MOKAID_AZURE_TENANT_ID`,
`MOKAID_AZURE_SUBSCRIPTION_ID`, `MOKAID_AZURE_SIGNING_ENDPOINT`, and
`MOKAID_AZURE_SIGNING_ACCOUNT`. Only Phase B adds
`MOKAID_AZURE_CERTIFICATE_PROFILE`. Configure them in the protected stable signing
environment after verifying the deployed resources. Do not add a client secret.

A failed deployment may leave a paid account present. Inspect actual resources
and billing before retrying. Do not automatically delete an account that might
later contain certificates or underpin signed releases. Public distribution
requires successful Authenticode/timestamp and update-signature validation of
both platforms before publication.

Schemas: [account](https://learn.microsoft.com/en-us/azure/templates/microsoft.codesigning/2025-10-13/codesigningaccounts),
[managed identity](https://learn.microsoft.com/en-us/azure/templates/microsoft.managedidentity/2024-11-30/userassignedidentities),
[federated credential](https://learn.microsoft.com/en-us/azure/templates/microsoft.managedidentity/2024-11-30/userassignedidentities/federatedidentitycredentials).
