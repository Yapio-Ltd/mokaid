"""Offline security contracts for the generic, pre-validation Azure account phase."""

import json
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[3]
DIRECTORY = ROOT / "infra/azure/artifact-signing"
TEMPLATE = json.loads((DIRECTORY / "phase-a.json").read_text())
NESTED = TEMPLATE["resources"][1]["properties"]["template"]
VERIFIER_ROLE = "4339b7cf-9826-4e41-b4ed-c7f4505dac08"


def resource(kind):
    return next(item for item in NESTED["resources"] if item["type"] == kind)


def test_phase_a_has_only_account_identity_federation_and_human_verifier():
    assert [item["type"] for item in TEMPLATE["resources"]] == [
        "Microsoft.Resources/resourceGroups",
        "Microsoft.Resources/deployments",
    ]
    deployment = TEMPLATE["resources"][1]
    assert deployment["subscriptionId"] == "[parameters('subscriptionId')]"
    assert deployment["resourceGroup"] == "[parameters('resourceGroupName')]"
    assert deployment["properties"]["mode"] == "Incremental"
    assert deployment["properties"]["expressionEvaluationOptions"] == {"scope": "inner"}
    assert [item["type"] for item in NESTED["resources"]] == [
        "Microsoft.CodeSigning/codeSigningAccounts",
        "Microsoft.ManagedIdentity/userAssignedIdentities",
        "Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials",
        "Microsoft.Authorization/roleAssignments",
    ]
    account = resource("Microsoft.CodeSigning/codeSigningAccounts")
    assert account["apiVersion"] == "2025-10-13"
    assert account["properties"] == {"sku": {"name": "Basic"}}
    assert TEMPLATE["parameters"]["location"]["allowedValues"] == ["westeurope"]
    assert not any(
        word in json.dumps(TEMPLATE).lower()
        for word in ("clientsecret", "password", "privatekey", "deploymentScripts".lower())
    )


def test_federation_requires_exact_protected_environment_and_azure_audience():
    federation = resource(
        "Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials"
    )
    assert federation["apiVersion"] == "2024-11-30"
    assert federation["properties"] == {
        "issuer": "https://token.actions.githubusercontent.com",
        "subject": "repo:Yapio-Ltd/mokaid:environment:desktop-signing-stable",
        "audiences": ["api://AzureADTokenExchange"],
    }


def test_only_human_can_verify_identity_and_no_ci_signing_role_is_granted():
    assignment = resource("Microsoft.Authorization/roleAssignments")
    assert assignment["scope"] == "[variables('signingAccountId')]"
    assert NESTED["variables"]["signingAccountId"] == (
        "[resourceId('Microsoft.CodeSigning/codeSigningAccounts', "
        "parameters('signingAccountName'))]"
    )
    assert assignment["properties"]["principalId"] == "[parameters('operatorObjectId')]"
    assert assignment["properties"]["principalType"] == "User"
    assert assignment["properties"]["roleDefinitionId"] == (
        "[subscriptionResourceId('Microsoft.Authorization/roleDefinitions', "
        "parameters('identityVerifierRoleId'))]"
    )
    assert TEMPLATE["parameters"]["identityVerifierRoleId"]["allowedValues"] == [
        VERIFIER_ROLE
    ]
    assert assignment["name"] == (
        "[guid(variables('signingAccountId'), parameters('operatorObjectId'), "
        "parameters('identityVerifierRoleId'))]"
    )


def test_outputs_match_existing_workflow_and_do_not_claim_a_certificate_profile():
    outputs = TEMPLATE["outputs"]
    assert outputs["githubEnvironment"]["value"] == "desktop-signing-stable"
    variables = outputs["githubEnvironmentVariables"]["value"]
    assert set(variables) == {
        "MOKAID_AZURE_CLIENT_ID", "MOKAID_AZURE_TENANT_ID",
        "MOKAID_AZURE_SUBSCRIPTION_ID", "MOKAID_AZURE_SIGNING_ENDPOINT",
        "MOKAID_AZURE_SIGNING_ACCOUNT",
    }
    assert variables["MOKAID_AZURE_SIGNING_ENDPOINT"] == "https://weu.codesigning.azure.net"
    workflow = yaml.load(
        (ROOT / ".github/workflows/desktop-release.yml").read_text(),
        Loader=yaml.BaseLoader,
    )
    signing = json.dumps(workflow["jobs"]["sign"])
    assert all("vars." + name in signing for name in variables)
    assert all(output["type"] in {"object", "string"} for output in outputs.values())


def test_public_example_has_no_real_scope_or_operator_and_no_private_files():
    assert {path.name for path in DIRECTORY.iterdir()} == {
        "phase-a.json", "parameters.example.json", "README.md"
    }
    example = json.loads((DIRECTORY / "parameters.example.json").read_text())["parameters"]
    assert set(example) == {
        "subscriptionId", "tenantId", "operatorObjectId", "signingAccountName"
    }
    for name in ("subscriptionId", "tenantId", "operatorObjectId"):
        assert example[name] == {"value": "00000000-0000-0000-0000-000000000000"}
        assert "defaultValue" not in TEMPLATE["parameters"][name]
    assert example["signingAccountName"] == {"value": "replace-with-unique-name"}
