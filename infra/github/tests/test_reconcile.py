"""Offline policy and REST contract tests; no test can invoke a live GitHub API."""

from __future__ import annotations

import argparse
import asyncio
import base64
import copy
import json
from pathlib import Path
from typing import Any

import pytest

import reconcile as policy

ROOT = policy.API_ROOT
PUBLIC = "desktop-public-stable"
SIGNING = "desktop-signing-stable"
MODE = {"protected_branches": False, "custom_branch_policies": True}


@pytest.fixture
def document() -> dict[str, Any]:
    # Fixed pre-provisioning fixture: real public ARNs/keys can be populated in
    # desired.json without changing the operation set exercised by unit tests.
    # The actual reviewed file is independently checked below, never normalized.
    environments: dict[str, Any] = {
        "prod": {
            "refs": [
                {"type": "branch", "name": "main"},
                {"type": "branch", "name": "prod"},
            ],
            "require_reviewer": False,
            "prevent_self_review": False,
            "wait_timer": 0,
            "variables": {"MOKAID_DESKTOP_ONLY": "false"},
        }
    }
    for category in ("signing", "public"):
        for channel in ("stable", "beta"):
            keys = (
                (
                    "MOKAID_SIGNING_AWS_ROLE_ARN",
                    "MOKAID_MACOS_SIGNING_SECRET_ARN",
                    "MOKAID_WINDOWS_SIGNING_SECRET_ARN",
                )
                if category == "signing"
                else (
                    "MOKAID_PUBLISH_AWS_ROLE_ARN",
                    "MOKAID_DOWNLOADS_BUCKET",
                    "MOKAID_DOWNLOADS_DISTRIBUTION_ID",
                )
            )
            environments[f"desktop-{category}-{channel}"] = {
                "refs": [
                    (
                        {"type": "tag", "name": "desktop-v*"}
                        if category == "signing"
                        else {"type": "branch", "name": "main"}
                    )
                ],
                "require_reviewer": True,
                "prevent_self_review": False,
                "wait_timer": 0,
                "variables": {
                    "MOKAID_AWS_REGION": "il-central-1",
                    **dict.fromkeys(keys),
                    "MOKAID_UPDATE_PUBLIC_KEY": None,
                },
            }
    environments[SIGNING]["refs"].append({"type": "branch", "name": "main"})
    return {
        "schema_version": 1,
        "repository": "Yapio-Ltd/mokaid",
        "default_branch": "main",
        "reviewer": {"login": "Tomyshh", "id": 113070134},
        "repository_variables": {
            "AWS_DEPLOY_ROLE_ARN": "arn:aws:iam::660601648321:role/mokaid-github-deploy",
            "MOKAID_DESKTOP_ONLY": "false",
        },
        "environments": environments,
    }


@pytest.fixture
def config(document: dict[str, Any]) -> policy.Configuration:
    return policy.Configuration.parse(document)


class FakeApi:
    """Stateful in-memory GitHub contract, including its unconfigured-ref 404."""

    def __init__(self) -> None:
        self.repository = {
            "full_name": policy.REPOSITORY,
            "default_branch": "main",
            "private": False,
            "permissions": {"admin": True},
        }
        self.reviewer = {"login": "Tomyshh", "id": 113070134}
        self.environments: dict[str, dict[str, Any]] = {
            "prod": {
                "name": "prod",
                "protection_rules": [],
                "deployment_branch_policy": None,
                "can_admins_bypass": True,
            }
        }
        self.branches: dict[str, list[Any]] = {"prod": []}
        self.custom: dict[str, list[Any]] = {"prod": []}
        self.variables: dict[str, str] = {}
        self.calls: list[tuple[str, str, Any]] = []
        self.overrides: dict[str, Any] = {}
        self.fail_write: int | None = None
        self.write_count = 0
        self.ignore_writes = False

    async def request(
        self, method: str, endpoint: str, body: Any = None, *, missing_ok: bool = False
    ) -> Any:
        self.calls.append((method, endpoint, copy.deepcopy(body)))
        if method != "GET":
            self.write_count += 1
            if self.write_count == self.fail_write:
                raise policy.PolicyError("Mock interrupted write")
            if self.ignore_writes:
                return None
            assert body is not None
            if method == "PUT":
                name = endpoint.rsplit("/", 1)[1]
                rules = []
                if body["wait_timer"]:
                    rules.append(
                        {"type": "wait_timer", "wait_timer": body["wait_timer"]}
                    )
                if body["reviewers"]:
                    rules.append(
                        {
                            "type": "required_reviewers",
                            "prevent_self_review": body["prevent_self_review"],
                            "reviewers": [
                                {"type": item["type"], "reviewer": {"id": item["id"]}}
                                for item in body["reviewers"]
                            ],
                        }
                    )
                rules.append({"type": "branch_policy"})
                self.environments[name] = {
                    "name": name,
                    "protection_rules": rules,
                    "deployment_branch_policy": body["deployment_branch_policy"],
                    "can_admins_bypass": True,
                }
                self.branches.setdefault(name, [])
                self.custom.setdefault(name, [])
            elif endpoint.endswith("/variables"):
                self.variables[f"{endpoint}/{body['name']}"] = body["value"]
            else:
                assert endpoint.endswith("/deployment-branch-policies")
                self.branches[endpoint.split("/")[-2]].append(body)
            return None
        if endpoint in self.overrides:
            return copy.deepcopy(self.overrides[endpoint])
        if endpoint == ROOT:
            return copy.deepcopy(self.repository)
        if endpoint == "users/Tomyshh":
            return copy.deepcopy(self.reviewer)
        if "/variables/" in endpoint:
            if endpoint in self.variables:
                return {
                    "name": endpoint.rsplit("/", 1)[1],
                    "value": self.variables[endpoint],
                }
        else:
            name = endpoint.split("/environments/", 1)[1].split("/", 1)[0]
            if name in self.environments:
                if "/deployment-branch-policies" in endpoint:
                    if self.environments[name]["deployment_branch_policy"] is not None:
                        return {
                            "total_count": len(self.branches[name]),
                            "branch_policies": copy.deepcopy(self.branches[name]),
                        }
                elif "/deployment_protection_rules" in endpoint:
                    return {
                        "total_count": len(self.custom[name]),
                        "custom_deployment_protection_rules": copy.deepcopy(
                            self.custom[name]
                        ),
                    }
                else:
                    return copy.deepcopy(self.environments[name])
        if missing_ok:
            return None
        raise policy.PolicyError(f"Mock HTTP 404: {endpoint}")


def snapshot(api: FakeApi, config: policy.Configuration) -> policy.Snapshot:
    return asyncio.run(policy.collect(api, config))


def converged(config: policy.Configuration) -> FakeApi:
    api = FakeApi()
    plan = policy.build_plan(config, snapshot(api, config))
    asyncio.run(policy.execute(api, config, plan, plan.digest()))
    api.calls.clear()
    api.write_count = 0
    return api


def test_default_plan_is_read_only_and_exact(config: policy.Configuration) -> None:
    api = FakeApi()
    plan = policy.build_plan(config, snapshot(api, config))
    assert len(plan.operations) == 19
    assert all(method == "GET" for method, _, _ in api.calls)
    assert not any(
        "/secrets" in endpoint or "AWS_DEPLOY_ENABLED" in endpoint
        for _, endpoint, _ in api.calls
    )
    payload = plan.json()
    assert payload["plan_sha256"] == plan.digest()
    assert len(plan.digest()) == 64
    public = [
        op
        for op in plan.operations
        if op.method == "PUT" and "desktop-public" in op.endpoint
    ]
    assert len(public) == 2
    assert all(
        op.body["reviewers"] == [{"type": "User", "id": 113070134}] for op in public
    )
    assert all(op.body["prevent_self_review"] is False for op in public)
    assert all(op.method in ("PUT", "POST") for op in plan.operations)
    assert (
        len(
            [
                op
                for op in plan.operations
                if op.endpoint.endswith("deployment-branch-policies")
            ]
        )
        == 7
    )
    assert not any(
        op.body.get("value") is None
        for op in plan.operations
        if op.endpoint.endswith("variables")
    )


def test_real_reviewed_configuration_preserves_all_resolved_public_values() -> None:
    actual = json.loads(Path(policy.__file__).with_name("desired.json").read_text())
    actual_config = policy.Configuration.parse(actual)
    assert actual["repository_variables"]["MOKAID_DESKTOP_ONLY"] == "false"
    assert actual["environments"]["prod"]["variables"]["MOKAID_DESKTOP_ONLY"] == "false"
    assert policy.refs(actual["environments"][SIGNING]["refs"], SIGNING) == (
        ("branch", "main"),
        ("tag", "desktop-v*"),
    )
    assert policy.refs(
        actual["environments"]["desktop-signing-beta"]["refs"], "beta"
    ) == (("tag", "desktop-v*"),)
    stable = actual["environments"]["desktop-signing-stable"]["variables"]
    assert stable["MOKAID_MACOS_SIGNING_SECRET_ARN"] == (
        "arn:aws:secretsmanager:il-central-1:660601648321:secret:"
        "mokaid/desktop/stable/macos-signing-8pPQkT"
    )
    scopes = {
        f"{ROOT}/actions/variables": actual["repository_variables"],
        **{
            f"{ROOT}/environments/{name}/variables": env["variables"]
            for name, env in actual["environments"].items()
        },
    }
    expected = {
        (scope, key, value)
        for scope, values in scopes.items()
        for key, value in values.items()
        if value is not None
    }
    api = FakeApi()
    plan = policy.build_plan(actual_config, snapshot(api, actual_config))
    assert {
        (op.endpoint, op.body["name"], op.body["value"])
        for op in plan.operations
        if op.endpoint.endswith("/variables")
    } == expected
    assert all(method == "GET" for method, _, _ in api.calls)
    converged_api = converged(actual_config)
    assert converged_api.variables == {
        f"{scope}/{key}": value for scope, key, value in expected
    }
    assert not policy.build_plan(
        actual_config, snapshot(converged_api, actual_config)
    ).operations


def test_idempotent_apply_then_noop(config: policy.Configuration) -> None:
    api = converged(config)
    plan = policy.build_plan(config, snapshot(api, config))
    assert not plan.operations
    assert not asyncio.run(policy.execute(api, config, plan, plan.digest())).operations
    assert api.write_count == 0


def legacy_signing(config: policy.Configuration) -> FakeApi:
    """Exact pre-migration public metadata, including an existing tag rule ID."""
    api = converged(config)
    api.branches[SIGNING] = [
        {"id": 71, "node_id": "synthetic-tag-rule", "type": "tag", "name": "desktop-v*"}
    ]
    return api


def migration_plan(api: FakeApi, config: policy.Configuration) -> policy.Plan:
    return policy.build_plan(config, snapshot(api, config), stable_signing_main=True)


def test_stable_main_migration_is_one_post_preserving_stronger_controls(
    config: policy.Configuration,
) -> None:
    api = legacy_signing(config)
    env = api.environments[SIGNING]
    env["can_admins_bypass"] = False
    env["protection_rules"][0]["prevent_self_review"] = True
    env["protection_rules"].append({"type": "wait_timer", "wait_timer": 30})
    before = copy.deepcopy(api.environments)
    branches = copy.deepcopy(api.branches)
    variables = copy.deepcopy(api.variables)
    plan = migration_plan(api, config)
    assert plan.json()["stable_signing_main"] is True
    assert [op.json() for op in plan.operations] == [
        {
            "method": "POST",
            "endpoint": f"{ROOT}/environments/{SIGNING}/deployment-branch-policies",
            "body": {"type": "branch", "name": "main"},
        }
    ]
    assert api.write_count == 0
    verified = asyncio.run(policy.execute(api, config, plan, plan.digest()))
    assert not verified.operations
    assert api.write_count == 1
    assert api.environments == before
    assert api.variables == variables
    branches[SIGNING].append({"type": "branch", "name": "main"})
    assert api.branches == branches
    assert not migration_plan(api, config).operations


def test_stable_main_migration_requires_explicit_mode(
    config: policy.Configuration,
) -> None:
    api = legacy_signing(config)
    with pytest.raises(policy.PolicyError, match="custom refs differ"):
        policy.build_plan(config, snapshot(api, config))
    assert api.write_count == 0


def test_stable_main_noop_is_bound_to_mode_and_keeps_all_controls(
    config: policy.Configuration,
) -> None:
    api = converged(config)
    before = snapshot(api, config)
    normal = policy.build_plan(config, before)
    plan = migration_plan(api, config)
    assert not plan.operations
    assert plan.digest() != normal.digest()
    asyncio.run(policy.execute(api, config, plan, plan.digest()))
    assert api.write_count == 0
    assert snapshot(api, config).fingerprint() == before.fingerprint()


@pytest.mark.parametrize(
    "name", ["prod", "desktop-signing-beta", PUBLIC, "desktop-public-beta"]
)
def test_stable_main_mode_blocks_other_environment_mutations(
    config: policy.Configuration,
    name: str,
) -> None:
    api = legacy_signing(config)
    del api.environments[name]
    with pytest.raises(policy.PolicyError, match="only.*main"):
        migration_plan(api, config)
    assert api.write_count == 0


@pytest.mark.parametrize(
    "target", ["missing", "unrestricted", "reviewer", "variable", "bypass-unknown"]
)
def test_stable_main_mode_never_bootstraps_or_repairs_other_drift(
    config: policy.Configuration,
    target: str,
) -> None:
    api = legacy_signing(config)
    if target == "missing":
        del api.environments[SIGNING]
    elif target == "unrestricted":
        api.environments[SIGNING]["deployment_branch_policy"] = None
        api.branches[SIGNING] = []
    elif target == "reviewer":
        api.environments[SIGNING]["protection_rules"] = [{"type": "branch_policy"}]
    elif target == "variable":
        del api.variables[f"{ROOT}/actions/variables/MOKAID_DESKTOP_ONLY"]
    else:
        del api.environments[SIGNING]["can_admins_bypass"]
    with pytest.raises(policy.PolicyError, match="main"):
        migration_plan(api, config)
    assert api.write_count == 0


@pytest.mark.parametrize(
    "rules",
    [
        [],
        [{"type": "branch", "name": "desktop-v*"}],
        [{"type": "tag", "name": "desktop-v*"}, {"type": "tag", "name": "main"}],
        [{"type": "tag", "name": "desktop-v*"}, {"type": "branch", "name": "prod"}],
        [{"type": "tag", "name": "desktop-v*"}, {"type": "branch", "name": "*"}],
    ],
)
def test_stable_main_mode_rejects_every_other_starting_ref_set(
    config: policy.Configuration,
    rules: list[Any],
) -> None:
    api = legacy_signing(config)
    api.branches[SIGNING] = rules
    with pytest.raises(policy.PolicyError, match="custom refs differ"):
        migration_plan(api, config)
    assert api.write_count == 0


@pytest.mark.parametrize(
    "name", ["desktop-signing-beta", "prod", PUBLIC, "desktop-public-beta"]
)
def test_configuration_cannot_extend_migration_to_another_environment(
    document: dict[str, Any],
    name: str,
) -> None:
    document["environments"][name]["refs"].append(
        {"type": "branch", "name": "unexpected"}
    )
    with pytest.raises(policy.PolicyError, match="refs differ"):
        policy.Configuration.parse(document)


@pytest.mark.parametrize(
    "change", ["already-added", "timer", "reviewer", "other-environment"]
)
def test_stable_main_stale_plan_never_writes(
    config: policy.Configuration, change: str
) -> None:
    api = legacy_signing(config)
    plan = migration_plan(api, config)
    if change == "already-added":
        api.branches[SIGNING].append({"type": "branch", "name": "main"})
    elif change == "timer":
        api.environments[SIGNING]["protection_rules"].append(
            {"type": "wait_timer", "wait_timer": 1}
        )
    elif change == "reviewer":
        api.environments[SIGNING]["protection_rules"][0]["reviewers"][0]["reviewer"][
            "id"
        ] = 2
    else:
        api.environments[PUBLIC]["can_admins_bypass"] = False
    with pytest.raises(policy.PolicyError, match="state changed"):
        asyncio.run(policy.execute(api, config, plan, plan.digest()))
    assert api.write_count == 0


@pytest.mark.parametrize(
    "change", ["timer", "self-review", "bypass", "tag-id", "other-environment"]
)
def test_stable_main_readback_rejects_lost_stronger_controls_without_repair(
    config: policy.Configuration,
    monkeypatch: pytest.MonkeyPatch,
    change: str,
) -> None:
    api = legacy_signing(config)
    api.environments[SIGNING]["can_admins_bypass"] = False
    api.environments[SIGNING]["protection_rules"][0]["prevent_self_review"] = True
    api.environments[SIGNING]["protection_rules"].append(
        {"type": "wait_timer", "wait_timer": 30}
    )
    plan = migration_plan(api, config)
    original = api.request

    async def request(
        method: str, endpoint: str, body: Any = None, *, missing_ok: bool = False
    ) -> Any:
        result = await original(method, endpoint, body, missing_ok=missing_ok)
        if method == "POST":
            if change == "timer":
                api.environments[SIGNING]["protection_rules"][-1]["wait_timer"] = 29
            elif change == "self-review":
                api.environments[SIGNING]["protection_rules"][0][
                    "prevent_self_review"
                ] = False
            elif change == "bypass":
                api.environments[SIGNING]["can_admins_bypass"] = True
            elif change == "tag-id":
                api.branches[SIGNING][0]["id"] = 72
            else:
                api.environments[PUBLIC]["can_admins_bypass"] = False
        return result

    monkeypatch.setattr(api, "request", request)
    with pytest.raises(policy.PolicyError, match="preserv"):
        asyncio.run(policy.execute(api, config, plan, plan.digest()))
    assert api.write_count == 1


@pytest.mark.parametrize("failure", ["error", "ignored"])
def test_stable_main_failed_post_never_retries(
    config: policy.Configuration, failure: str
) -> None:
    api = legacy_signing(config)
    plan = migration_plan(api, config)
    if failure == "error":
        api.fail_write = 1
    else:
        api.ignore_writes = True
    with pytest.raises(policy.PolicyError, match="interrupted|did not converge"):
        asyncio.run(policy.execute(api, config, plan, plan.digest()))
    assert api.write_count == 1
    assert api.branches[SIGNING] == [
        {"id": 71, "node_id": "synthetic-tag-rule", "type": "tag", "name": "desktop-v*"}
    ]


def test_stable_main_revalidates_operation_scope_before_any_write(
    config: policy.Configuration,
) -> None:
    api = legacy_signing(config)
    plan = migration_plan(api, config)
    changed = policy.replace(plan, operations=())
    with pytest.raises(policy.PolicyError, match="differs from the reviewed plan"):
        asyncio.run(policy.execute(api, config, changed, changed.digest()))
    assert api.write_count == 0


def test_stable_main_readback_accepts_only_target_server_timestamp_change(
    config: policy.Configuration,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    api = legacy_signing(config)
    api.environments[SIGNING]["updated_at"] = "2026-09-14T00:00:00Z"
    plan = migration_plan(api, config)
    original = api.request

    async def request(
        method: str, endpoint: str, body: Any = None, *, missing_ok: bool = False
    ) -> Any:
        result = await original(method, endpoint, body, missing_ok=missing_ok)
        if method == "POST":
            api.environments[SIGNING]["updated_at"] = "2026-09-14T01:00:00Z"
            api.branches[SIGNING][-1].update(id=72, node_id="synthetic-main-rule")
        return result

    monkeypatch.setattr(api, "request", request)
    assert not asyncio.run(policy.execute(api, config, plan, plan.digest())).operations
    assert api.write_count == 1
    assert api.branches[SIGNING][0]["id"] == 71


@pytest.mark.parametrize("stale", [False, True])
def test_stable_main_cli_plan_apply_is_explicit_and_digest_bound(
    config: policy.Configuration,
    document: dict[str, Any],
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    tmp_path: Path,
    stale: bool,
) -> None:
    api = legacy_signing(config)
    flags: list[bool] = []

    def factory(*, allow_writes: bool) -> FakeApi:
        flags.append(allow_writes)
        return api

    monkeypatch.setattr(policy, "GhApi", factory)
    source = tmp_path / "desired-fixture.json"
    source.write_text(json.dumps(document), encoding="utf-8")
    arguments = ["--config", str(source), "--stable-signing-main"]
    assert (
        asyncio.run(policy.run(policy.parser().parse_args([*arguments, "--plan"]))) == 0
    )
    result = json.loads(capsys.readouterr().out)
    assert result["stable_signing_main"] is True
    assert len(result["operations"]) == 1
    assert flags == [False] and api.write_count == 0
    if stale:
        api.environments[PUBLIC]["can_admins_bypass"] = False
    apply_args = policy.parser().parse_args(
        [
            *arguments,
            "--apply",
            "--expect-plan",
            result["plan_sha256"],
        ]
    )
    if stale:
        with pytest.raises(policy.PolicyError, match="fingerprint"):
            asyncio.run(policy.run(apply_args))
        assert api.write_count == 0
    else:
        assert asyncio.run(policy.run(apply_args)) == 0
        assert api.write_count == 1
        assert "applied and verified" in capsys.readouterr().err
        assert asyncio.run(policy.run(policy.parser().parse_args(arguments))) == 0
        assert json.loads(capsys.readouterr().out)["operations"] == []


def test_signing_gate_upgrade_is_exactly_two_protective_puts(
    config: policy.Configuration,
) -> None:
    api = converged(config)
    names = {"desktop-signing-stable", "desktop-signing-beta"}
    for name in names:
        api.environments[name]["protection_rules"] = [
            rule
            for rule in api.environments[name]["protection_rules"]
            if rule["type"] != "required_reviewers"
        ]
    plan = policy.build_plan(config, snapshot(api, config))
    assert len(plan.operations) == 2
    assert {op.endpoint.rsplit("/", 1)[1] for op in plan.operations} == names
    for operation in plan.operations:
        assert operation.method == "PUT"
        assert operation.body == {
            "wait_timer": 0,
            "prevent_self_review": False,
            "reviewers": [{"type": "User", "id": 113070134}],
            "deployment_branch_policy": MODE,
        }
    assert not asyncio.run(policy.execute(api, config, plan, plan.digest())).operations


@pytest.mark.parametrize("name", ["desktop-signing-stable", "desktop-signing-beta"])
def test_signing_review_cannot_be_disabled_in_configuration(
    document: dict[str, Any],
    name: str,
) -> None:
    document["environments"][name]["require_reviewer"] = False
    with pytest.raises(policy.PolicyError, match="required reviewer"):
        policy.Configuration.parse(document)


def test_failed_or_stale_approval_writes_nothing(config: policy.Configuration) -> None:
    api = FakeApi()
    plan = policy.build_plan(config, snapshot(api, config))
    with pytest.raises(policy.PolicyError, match="fingerprint"):
        asyncio.run(policy.execute(api, config, plan, "0" * 64))
    assert api.write_count == 0
    api.environments["prod"]["updated_at"] = "concurrent edit"
    with pytest.raises(policy.PolicyError, match="state changed"):
        asyncio.run(policy.execute(api, config, plan, plan.digest()))
    assert api.write_count == 0


def test_apply_requires_admin(config: policy.Configuration) -> None:
    api = FakeApi()
    api.repository["permissions"]["admin"] = False
    plan = policy.build_plan(config, snapshot(api, config))
    with pytest.raises(policy.PolicyError, match="Administration"):
        asyncio.run(policy.execute(api, config, plan, plan.digest()))
    assert not api.write_count


def test_interrupted_apply_stops_and_never_blindly_broadens(
    config: policy.Configuration,
) -> None:
    api = FakeApi()
    plan = policy.build_plan(config, snapshot(api, config))
    api.fail_write = 2
    with pytest.raises(policy.PolicyError, match="interrupted"):
        asyncio.run(policy.execute(api, config, plan, plan.digest()))
    assert api.write_count == 2
    assert api.environments["prod"]["deployment_branch_policy"] == MODE
    assert api.branches["prod"] == []
    with pytest.raises(policy.PolicyError, match="partial applies"):
        policy.build_plan(config, snapshot(api, config))


def test_post_apply_convergence_is_verified(config: policy.Configuration) -> None:
    api = FakeApi()
    api.ignore_writes = True
    plan = policy.build_plan(config, snapshot(api, config))
    with pytest.raises(policy.PolicyError, match="did not converge"):
        asyncio.run(policy.execute(api, config, plan, plan.digest()))
    assert api.write_count == 19


@pytest.mark.parametrize(
    "mutation,expected",
    [
        (lambda d: d.update(unknown=True), "top-level"),
        (lambda d: d.update(repository="someone/else"), "Unsupported"),
        (lambda d: d.update(schema_version=2), "Unsupported"),
        (lambda d: d.update(default_branch="prod"), "Unsupported"),
        (lambda d: d["reviewer"].update(id=999), "identity"),
        (lambda d: d["environments"].pop("prod"), "five"),
        (lambda d: d["environments"][PUBLIC].update(extra=True), "field"),
        (
            lambda d: d["environments"][PUBLIC].update(require_reviewer=False),
            "required reviewer",
        ),
        (lambda d: d["environments"][PUBLIC].update(prevent_self_review=1), "boolean"),
        (lambda d: d["environments"][PUBLIC].update(wait_timer=True), "wait_timer"),
        (lambda d: d["environments"][PUBLIC].update(wait_timer=-1), "wait_timer"),
        (lambda d: d["environments"][PUBLIC].update(wait_timer=43201), "wait_timer"),
        (
            lambda d: d["environments"][PUBLIC].update(
                refs=[{"type": "branch", "name": "*"}]
            ),
            "refs differ",
        ),
        (
            lambda d: d["repository_variables"].update(AWS_DEPLOY_ENABLED="true"),
            "allowlist",
        ),
    ],
)
def test_configuration_rejects_unsafe_changes(
    document: dict[str, Any], mutation: Any, expected: str
) -> None:
    mutation(document)
    with pytest.raises(policy.PolicyError, match=expected):
        policy.Configuration.parse(document)


@pytest.mark.parametrize(
    "name,value",
    [
        ("MOKAID_AWS_REGION", "il-central-1"),
        ("MOKAID_DOWNLOADS_BUCKET", "mokaid-desktop-downloads-production"),
        ("MOKAID_DOWNLOADS_DISTRIBUTION_ID", "E123456789ABCD"),
        ("MOKAID_UPDATE_PUBLIC_KEY", base64.b64encode(b"a" * 32).decode()),
        (
            "MOKAID_MACOS_SIGNING_SECRET_ARN",
            "arn:aws:secretsmanager:il-central-1:660601648321:secret:mokaid/desktop/stable/signing-abc123",
        ),
        ("MOKAID_DESKTOP_ONLY", "false"),
        ("MOKAID_PUBLISH_AWS_ROLE_ARN", None),
    ],
)
def test_public_identifier_validation(name: str, value: Any) -> None:
    assert policy.validate_variable(name, value) == value


@pytest.mark.parametrize(
    "name,value",
    [
        ("TOKEN", None),
        ("MOKAID_AWS_REGION", "secret-do-not-echo"),
        ("MOKAID_AWS_REGION", ""),
        ("MOKAID_AWS_REGION", True),
        ("MOKAID_AWS_REGION", "a" * 1025),
        ("MOKAID_DESKTOP_ONLY", "true"),
        ("MOKAID_UPDATE_PUBLIC_KEY", "!invalid!"),
        ("MOKAID_UPDATE_PUBLIC_KEY", base64.b64encode(b"private-key" * 8).decode()),
        ("AWS_DEPLOY_ROLE_ARN", "arn:aws:iam::999999999999:role/other"),
        ("MOKAID_MACOS_SIGNING_SECRET_ARN", "actual-private-secret-contents"),
    ],
)
def test_private_or_unsafe_values_rejected_without_echo(name: str, value: Any) -> None:
    with pytest.raises(policy.PolicyError) as caught:
        policy.validate_variable(name, value)
    if isinstance(value, str) and len(value) > 5:
        assert value not in str(caught.value)


@pytest.mark.parametrize(
    "value",
    [
        None,
        {},
        [None],
        [{"type": "Tag", "name": "x"}],
        [{"name": ""}],
        [{"name": "main"}, {"name": "main"}],
    ],
)
def test_bad_ref_shapes(value: Any) -> None:
    with pytest.raises(policy.PolicyError):
        policy.refs(value, "test")


def test_ref_default_and_type_distinction() -> None:
    assert policy.refs([{"name": "main"}, {"name": "main", "type": "tag"}], "test") == (
        ("branch", "main"),
        ("tag", "main"),
    )
    with pytest.raises(policy.PolicyError, match="object"):
        policy.Configuration.parse(None)


@pytest.mark.parametrize(
    "target,value,expected",
    [
        (ROOT, {"full_name": "other/repo", "default_branch": "main"}, "identity"),
        ("users/Tomyshh", {"id": 123, "login": "Tomyshh"}, "Reviewer"),
        (
            f"{ROOT}/environments/prod/deployment_protection_rules?per_page=100",
            {"total_count": 1, "custom_deployment_protection_rules": []},
            "incomplete",
        ),
        (
            f"{ROOT}/environments/prod/deployment_protection_rules?per_page=100",
            {},
            "array",
        ),
    ],
)
def test_invalid_or_incomplete_live_state(
    config: policy.Configuration, target: str, value: Any, expected: str
) -> None:
    api = FakeApi()
    api.overrides[target] = value
    with pytest.raises(policy.PolicyError, match=expected):
        snapshot(api, config)


def test_branch_policy_404_only_tolerated_for_unrestricted_environment(
    config: policy.Configuration,
) -> None:
    api = converged(config)
    api.overrides[
        f"{ROOT}/environments/prod/deployment-branch-policies?per_page=100"
    ] = None
    with pytest.raises(policy.PolicyError, match="object"):
        snapshot(api, config)


def test_existing_variable_preserved_or_conflict_fails(
    config: policy.Configuration,
) -> None:
    api = FakeApi()
    path = f"{ROOT}/actions/variables/AWS_DEPLOY_ROLE_ARN"
    api.variables[path] = config.variables["AWS_DEPLOY_ROLE_ARN"] or ""
    plan = policy.build_plan(config, snapshot(api, config))
    assert len(plan.operations) == 18
    api.variables[path] = "arn:aws:iam::660601648321:role/another-public-role"
    with pytest.raises(policy.PolicyError, match="existing value differs") as caught:
        policy.build_plan(config, snapshot(api, config))
    assert "another-public-role" not in str(caught.value)
    assert not api.write_count


def test_stronger_timer_self_review_and_additional_required_reviewers_preserved(
    config: policy.Configuration,
) -> None:
    api = converged(config)
    public = api.environments[PUBLIC]
    public["protection_rules"][0]["prevent_self_review"] = True
    public["protection_rules"].append({"type": "wait_timer", "wait_timer": 30})
    api.environments["prod"]["protection_rules"].append(
        {
            "type": "required_reviewers",
            "prevent_self_review": True,
            "reviewers": [{"type": "Team", "reviewer": {"id": 123}}],
        }
    )
    plan = policy.build_plan(config, snapshot(api, config))
    assert not plan.operations
    assert any("preserving existing" in message for message in plan.warnings)
    public["can_admins_bypass"] = False
    assert not policy.build_plan(config, snapshot(api, config)).operations


@pytest.mark.parametrize(
    "mutation,expected",
    [
        (lambda a: a.custom[PUBLIC].append({"id": 1}), "custom deployment"),
        (
            lambda a: a.environments[PUBLIC]["protection_rules"].append(
                {"type": "future_rule"}
            ),
            "unknown protection",
        ),
        (
            lambda a: a.environments[PUBLIC]["protection_rules"].append(
                {"type": "branch_policy"}
            ),
            "duplicate",
        ),
        (
            lambda a: a.environments[PUBLIC]["protection_rules"].append(
                {"type": "wait_timer", "wait_timer": True}
            ),
            "wait timer",
        ),
        (
            lambda a: a.environments[PUBLIC]["protection_rules"][0].update(
                prevent_self_review=None
            ),
            "self-review",
        ),
        (
            lambda a: a.environments[PUBLIC]["protection_rules"][0]["reviewers"][0][
                "reviewer"
            ].update(id=222),
            "reviewers differ",
        ),
        (
            lambda a: a.environments[PUBLIC]["protection_rules"][0]["reviewers"][
                0
            ].update(type="Robot"),
            "identity",
        ),
        (
            lambda a: a.environments[PUBLIC]["protection_rules"][0].update(
                reviewers=[]
            ),
            "reviewer list",
        ),
        (
            lambda a: a.environments[PUBLIC].update(
                deployment_branch_policy={
                    "protected_branches": True,
                    "custom_branch_policies": False,
                }
            ),
            "protected-branch",
        ),
        (
            lambda a: a.branches[PUBLIC].append({"type": "branch", "name": "prod"}),
            "custom refs differ",
        ),
        (lambda a: a.branches[PUBLIC].clear(), "custom refs differ"),
        (
            lambda a: a.environments[PUBLIC].update(deployment_branch_policy=None),
            "stale custom refs",
        ),
    ],
)
def test_unexpected_existing_protections_fail_closed(
    config: policy.Configuration, mutation: Any, expected: str
) -> None:
    api = converged(config)
    mutation(api)
    # Expose stale policies explicitly instead of mimicking GitHub's 404 for disabled mode.
    if expected == "stale custom refs":
        api.overrides[
            f"{ROOT}/environments/{PUBLIC}/deployment-branch-policies?per_page=100"
        ] = {
            "total_count": len(api.branches[PUBLIC]),
            "branch_policies": api.branches[PUBLIC],
        }
    with pytest.raises(policy.PolicyError, match=expected):
        policy.build_plan(config, snapshot(api, config))
    assert api.write_count == 0


def test_strict_admin_bypass_never_overwritten(config: policy.Configuration) -> None:
    api = FakeApi()
    api.environments["prod"]["can_admins_bypass"] = False
    with pytest.raises(policy.PolicyError, match="admin-bypass"):
        policy.build_plan(config, snapshot(api, config))


def test_private_repository_reports_unavailable_required_reviewer_plan(
    config: policy.Configuration,
) -> None:
    api = FakeApi()
    api.repository["private"] = True
    plan = policy.build_plan(config, snapshot(api, config))
    assert any("Enterprise" in warning for warning in plan.warnings)


class Process:
    def __init__(
        self,
        output: bytes,
        code: int = 0,
        error: BaseException | None = None,
        gone: bool = False,
    ) -> None:
        self.output, self.returncode, self.error, self.gone = output, code, error, gone
        self.killed = self.waited = False
        self.input: bytes | None = None

    async def communicate(self, payload: bytes | None) -> tuple[bytes, bytes]:
        self.input = payload
        if self.error:
            raise self.error
        return self.output, b"private-token-never-echo"

    def kill(self) -> None:
        self.killed = True
        if self.gone:
            raise ProcessLookupError()

    async def wait(self) -> int:
        self.waited = True
        return self.returncode


def mock_process(monkeypatch: pytest.MonkeyPatch, process: Process) -> list[Any]:
    calls: list[Any] = []

    async def create(*args: Any, **kwargs: Any) -> Process:
        calls.append((args, kwargs))
        return process

    monkeypatch.setattr(asyncio, "create_subprocess_exec", create)
    return calls


@pytest.mark.parametrize(
    "output,code,missing,expected",
    [
        (b'HTTP/2.0 200 OK\r\nHeader: value\r\n\r\n{"id":1}', 0, False, {"id": 1}),
        (b"HTTP/2.0 204 No Content\n\n", 0, False, None),
        (b'HTTP/2.0 404 Not Found\n\n{"message":"private"}', 1, True, None),
    ],
)
def test_gh_response_parsing(
    monkeypatch: pytest.MonkeyPatch,
    output: bytes,
    code: int,
    missing: bool,
    expected: Any,
) -> None:
    process = Process(output, code)
    calls = mock_process(monkeypatch, process)
    result = asyncio.run(policy.GhApi().request("GET", ROOT, missing_ok=missing))
    assert result == expected
    assert calls[0][0][:6] == (
        "gh",
        "api",
        "--hostname",
        "github.com",
        "--method",
        "GET",
    )
    assert process.input is None


@pytest.mark.parametrize(
    "output,code,expected",
    [
        (b"garbage", 1, "unavailable"),
        (b"HTTP/2.0 403 Forbidden\n\nsecret", 1, "HTTP 403"),
        (b"HTTP/2.0 303 See Other\n\nconcurrent branch policy", 1, "HTTP 303"),
        (b"HTTP/2.0 200 OK\n\nno-json", 0, "malformed JSON"),
    ],
)
def test_gh_failure_redacts_payload_and_stderr(
    monkeypatch: pytest.MonkeyPatch, output: bytes, code: int, expected: str
) -> None:
    mock_process(monkeypatch, Process(output, code))
    with pytest.raises(policy.PolicyError, match=expected) as caught:
        asyncio.run(policy.GhApi().request("GET", ROOT))
    assert "private-token" not in str(caught.value)
    assert "secret" not in str(caught.value)


@pytest.mark.parametrize(
    "error,gone", [(TimeoutError(), False), (asyncio.CancelledError(), True)]
)
def test_timeout_and_cancel_reap_subprocess(
    monkeypatch: pytest.MonkeyPatch, error: BaseException, gone: bool
) -> None:
    process = Process(b"", error=error, gone=gone)
    mock_process(monkeypatch, process)
    with pytest.raises(type(error)):
        asyncio.run(policy.GhApi().request("GET", ROOT))
    assert process.killed and process.waited


def test_gh_blocks_unapproved_writes_and_secret_endpoints(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    process = Process(b"HTTP/2.0 201 Created\n\n{}")
    calls = mock_process(monkeypatch, process)
    with pytest.raises(policy.PolicyError, match="Write blocked"):
        asyncio.run(policy.GhApi().request("POST", ROOT, {}))
    for endpoint in ("repos/other/project", f"{ROOT}/actions/secrets", "users/another"):
        with pytest.raises(policy.PolicyError, match="scope"):
            asyncio.run(policy.GhApi().request("GET", endpoint))
    assert not calls
    body: policy.Object = {"name": "MOKAID_DESKTOP_ONLY", "value": "false"}
    asyncio.run(
        policy.GhApi(allow_writes=True).request(
            "POST", f"{ROOT}/actions/variables", body
        )
    )
    assert process.input == policy.canonical(body).encode()
    assert calls[0][0][-2:] == ("--input", "-")


def test_help_version_and_default_readonly(capsys: pytest.CaptureFixture[str]) -> None:
    args = policy.parser().parse_args([])
    assert args.apply is False
    assert args.config == Path(policy.__file__).with_name("desired.json")
    for option in ("--help", "--version"):
        with pytest.raises(SystemExit) as caught:
            policy.parser().parse_args([option])
        assert caught.value.code == 0
    assert policy.VERSION in capsys.readouterr().out


def test_cli_validates_before_network(monkeypatch: pytest.MonkeyPatch) -> None:
    def forbidden(*args: Any, **kwargs: Any) -> None:
        pytest.fail("Network API initialized before validation")

    monkeypatch.setattr(policy, "GhApi", forbidden)
    args = policy.parser().parse_args(["--apply"])
    with pytest.raises(policy.PolicyError, match="requires"):
        asyncio.run(policy.run(args))


def test_cli_default_plan_and_reviewed_apply(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    document: dict[str, Any],
    tmp_path: Path,
) -> None:
    api = FakeApi()
    flags: list[bool] = []

    def factory(*, allow_writes: bool) -> FakeApi:
        flags.append(allow_writes)
        return api

    monkeypatch.setattr(policy, "GhApi", factory)
    source = tmp_path / "desired-fixture.json"
    source.write_text(json.dumps(document), encoding="utf-8")
    arguments = ["--config", str(source)]
    assert asyncio.run(policy.run(policy.parser().parse_args(arguments))) == 0
    result = json.loads(capsys.readouterr().out)
    assert flags == [False] and api.write_count == 0
    assert (
        asyncio.run(
            policy.run(
                policy.parser().parse_args(
                    [*arguments, "--apply", "--expect-plan", result["plan_sha256"]]
                )
            )
        )
        == 0
    )
    assert flags == [False, True] and api.write_count == 19
    output = capsys.readouterr()
    assert "applied and verified" in output.err
    assert "Applying" not in output.out


@pytest.mark.parametrize(
    "failure,code",
    [
        (policy.PolicyError("safe error"), 1),
        (OSError("missing gh"), 1),
        (KeyboardInterrupt(), 130),
        (TimeoutError(), 1),
        (json.JSONDecodeError("invalid", "", 0), 1),
    ],
)
def test_main_expected_errors(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    failure: BaseException,
    code: int,
) -> None:
    async def fail(arguments: argparse.Namespace) -> int:
        raise failure

    monkeypatch.setattr(policy, "run", fail)
    monkeypatch.setattr("sys.argv", ["reconcile.py"])
    assert policy.main() == code
    assert capsys.readouterr().err
