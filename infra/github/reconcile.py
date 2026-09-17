"""Plan and explicitly apply a bounded, non-secret GitHub environment policy.

No third-party runtime dependencies. gh owns authentication; this process never
reads tokens, repository secrets, secret contents, or arbitrary Actions variables.
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import hashlib
import ipaddress
import json
import re
import sys
from contextlib import suppress
from dataclasses import dataclass, field, replace
from pathlib import Path
from typing import Literal, Protocol, TypeAlias, cast
from urllib.parse import quote

Json: TypeAlias = "None | bool | int | float | str | list[Json] | dict[str, Json]"
Object: TypeAlias = dict[str, Json]
Method: TypeAlias = Literal["GET", "PUT", "POST", "PATCH"]
REPOSITORY = "Yapio-Ltd/mokaid"
API_ROOT = f"repos/{REPOSITORY}"
VERSION = "1.1.0"
PRODUCTION_VPC = ipaddress.IPv4Network("10.10.0.0/16")
STABLE_SIGNING = "desktop-signing-stable"
SIGNING_TAG_REFS = (("tag", "desktop-v*"),)
STABLE_SIGNING_REFS = (("branch", "main"), *SIGNING_TAG_REFS)
ENVIRONMENTS = {
    "prod",
    "desktop-signing-stable",
    "desktop-signing-beta",
    "desktop-public-stable",
    "desktop-public-beta",
}
ROLE_KEYS = {
    "AWS_DEPLOY_ROLE_ARN",
    "MOKAID_SIGNING_AWS_ROLE_ARN",
    "MOKAID_PUBLISH_AWS_ROLE_ARN",
}
SECRET_REFERENCE_KEYS = {
    "MOKAID_MACOS_SIGNING_SECRET_ARN",
    "MOKAID_WINDOWS_SIGNING_SECRET_ARN",
}
ALLOWED_VARIABLES = (
    ROLE_KEYS
    | SECRET_REFERENCE_KEYS
    | {
        "MOKAID_AWS_REGION",
        "MOKAID_DOWNLOADS_BUCKET",
        "MOKAID_DOWNLOADS_DISTRIBUTION_ID",
        "MOKAID_UPDATE_PUBLIC_KEY",
        "MOKAID_DESKTOP_ONLY",
        "MOKAID_TRUSTED_ALB_CIDRS",
    }
)


class PolicyError(Exception):
    """A configuration, API, or concurrency condition requires operator review."""


def object_value(value: Json, label: str) -> Object:
    """Narrow decoded JSON without accepting malformed API shapes."""
    if not isinstance(value, dict):
        raise PolicyError(f"{label}: expected an object")
    return value


def array_value(value: Json, label: str) -> list[Json]:
    """Validate a JSON list at a boundary."""
    if not isinstance(value, list):
        raise PolicyError(f"{label}: expected an array")
    return value


def canonical(value: Json) -> str:
    """Stable representation for reviewed plan fingerprints."""
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True)


def valid_trusted_alb_cidrs(value: str) -> bool:
    """Match the ECS preflight's bounded, canonical production-network format."""
    entries = value.split(",")
    if len(value) > 512 or not 1 <= len(entries) <= 16:
        return False
    networks: list[ipaddress.IPv4Network] = []
    for entry in entries:
        try:
            network = ipaddress.IPv4Network(entry, strict=True)
        except ValueError:
            return False
        if (
            str(network) != entry
            or network.prefixlen < 24
            or not network.subnet_of(PRODUCTION_VPC)
            or any(network.overlaps(previous) for previous in networks)
        ):
            return False
        networks.append(network)
    return True


def validate_variable(name: str, value: Json) -> str | None:
    """Allow only recognizable public identifiers, never arbitrary strings."""
    if name not in ALLOWED_VARIABLES:
        raise PolicyError(f"Variable {name!r} is not in the non-secret allowlist")
    if value is None:
        return None  # Unresolved is unmanaged, never an empty or deleted variable.
    if not isinstance(value, str) or not value or len(value) > 1024:
        raise PolicyError(
            f"Variable {name}: invalid public identifier (value redacted)"
        )
    valid = False
    if name in ROLE_KEYS:
        valid = bool(
            re.fullmatch(r"arn:aws:iam::660601648321:role/[A-Za-z0-9_+=,.@/-]+", value)
        )
    elif name in SECRET_REFERENCE_KEYS:
        valid = bool(
            re.fullmatch(
                r"arn:aws:secretsmanager:il-central-1:660601648321:secret:[A-Za-z0-9/_+=.@-]+",
                value,
            )
        )
    elif name == "MOKAID_AWS_REGION":
        valid = value == "il-central-1"
    elif name == "MOKAID_DOWNLOADS_BUCKET":
        valid = bool(re.fullmatch(r"mokaid[a-z0-9.-]{1,56}[a-z0-9]", value))
    elif name == "MOKAID_DOWNLOADS_DISTRIBUTION_ID":
        valid = bool(re.fullmatch(r"[A-Z0-9]{8,32}", value))
    elif name == "MOKAID_DESKTOP_ONLY":
        valid = value == "false"  # Enabling rollout is a different reviewed workflow.
    elif name == "MOKAID_TRUSTED_ALB_CIDRS":
        valid = valid_trusted_alb_cidrs(value)
    elif name == "MOKAID_UPDATE_PUBLIC_KEY":
        try:
            valid = len(base64.b64decode(value, validate=True)) == 32
        except ValueError:
            valid = False
    if not valid:
        raise PolicyError(
            f"Variable {name}: invalid public identifier or unsafe rollout value (value redacted)"
        )
    return value


def validated_variables(value: Json) -> dict[str, str | None]:
    """Validate every desired key, including unresolved entries."""
    return {
        key: validate_variable(key, item)
        for key, item in object_value(value, "variables").items()
    }


def refs(value: Json, label: str) -> tuple[tuple[str, str], ...]:
    """Normalize branch/tag rules; never confuse a tag with a same-named branch."""
    result: list[tuple[str, str]] = []
    for item in array_value(value, label):
        rule = object_value(item, label)
        kind, name = rule.get("type", "branch"), rule.get("name")
        if kind not in ("branch", "tag") or not isinstance(name, str) or not name:
            raise PolicyError(f"{label}: invalid deployment ref rule")
        result.append((str(kind), name))
    if len(set(result)) != len(result):
        raise PolicyError(f"{label}: duplicate deployment rules")
    return tuple(sorted(result))


@dataclass(frozen=True)
class DesiredEnvironment:
    """Minimum protections and exact allowed deployment refs for one environment."""

    name: str
    allowed_refs: tuple[tuple[str, str], ...]
    require_reviewer: bool
    prevent_self_review: bool
    wait_timer: int
    variables: dict[str, str | None]


@dataclass(frozen=True)
class Configuration:
    """Version-controlled policy, restricted to the explicitly owned repository."""

    default_branch: str
    reviewer_login: str
    reviewer_id: int
    variables: dict[str, str | None]
    environments: tuple[DesiredEnvironment, ...]

    @classmethod
    def parse(cls, document: Json) -> Configuration:
        """Reject typoed fields, broadened refs, unsafe values, and absent gates."""
        data = object_value(document, "configuration")
        if set(data) != {
            "schema_version",
            "repository",
            "default_branch",
            "reviewer",
            "repository_variables",
            "environments",
        }:
            raise PolicyError("Unknown or missing top-level configuration field")
        if (
            data["schema_version"] != 1
            or data["repository"] != REPOSITORY
            or data["default_branch"] != "main"
        ):
            raise PolicyError("Unsupported schema, repository, or default branch")
        reviewer = object_value(data["reviewer"], "reviewer")
        if reviewer != {"login": "Tomyshh", "id": 113070134}:
            raise PolicyError(
                "Reviewer identity must be reviewed in source before changing it"
            )
        environments = object_value(data["environments"], "environments")
        if set(environments) != ENVIRONMENTS:
            raise PolicyError(
                "Exactly the five managed environments must be configured"
            )
        parsed: list[DesiredEnvironment] = []
        for name, raw in environments.items():
            env = object_value(raw, name)
            if set(env) != {
                "refs",
                "require_reviewer",
                "prevent_self_review",
                "wait_timer",
                "variables",
            }:
                raise PolicyError(f"{name}: unknown or missing configuration field")
            required = name.startswith("desktop-")
            if (
                type(env["require_reviewer"]) is not bool
                or env["require_reviewer"] != required
            ):
                raise PolicyError(
                    f"{name}: required reviewer policy differs from the release contract"
                )
            if type(env["prevent_self_review"]) is not bool:
                raise PolicyError(f"{name}: prevent_self_review must be boolean")
            wait = env["wait_timer"]
            if type(wait) is not int or not 0 <= wait <= 43200:
                raise PolicyError(
                    f"{name}: wait_timer is outside GitHub's permitted range"
                )
            allowed = refs(env["refs"], name)
            expected = (
                (("branch", "main"), ("branch", "prod"))
                if name == "prod"
                else (
                    STABLE_SIGNING_REFS
                    if name == STABLE_SIGNING
                    else (
                        SIGNING_TAG_REFS
                        if name == "desktop-signing-beta"
                        else (("branch", "main"),)
                    )
                )
            )
            if allowed != expected:
                raise PolicyError(
                    f"{name}: refs differ from the reviewed workflow contract"
                )
            parsed.append(
                DesiredEnvironment(
                    name,
                    allowed,
                    required,
                    bool(env["prevent_self_review"]),
                    wait,
                    validated_variables(env["variables"]),
                )
            )
        return cls(
            "main",
            "Tomyshh",
            113070134,
            validated_variables(data["repository_variables"]),
            tuple(parsed),
        )


class Api(Protocol):
    """Narrow, mockable API boundary. DELETE and secrets APIs are intentionally absent."""

    async def request(
        self,
        method: Method,
        endpoint: str,
        body: Object | None = None,
        *,
        missing_ok: bool = False,
    ) -> Json:
        """Execute a GitHub REST request or return None for an allowed 404."""
        ...


@dataclass
class GhApi:
    """Bounded asynchronous gh subprocesses; authentication is never echoed."""

    allow_writes: bool = False
    limit: asyncio.Semaphore = field(default_factory=lambda: asyncio.Semaphore(4))

    async def request(
        self,
        method: Method,
        endpoint: str,
        body: Object | None = None,
        *,
        missing_ok: bool = False,
    ) -> Json:
        """Use explicit methods and stdin JSON to avoid gh's implicit POST behavior."""
        if method != "GET" and not self.allow_writes:
            raise PolicyError("Write blocked: --apply was not supplied")
        if (
            not (
                endpoint.startswith(API_ROOT + "/")
                or endpoint == API_ROOT
                or endpoint == "users/Tomyshh"
            )
            or "/secrets" in endpoint
        ):
            raise PolicyError(
                "Endpoint is outside the allowed repository/non-secret API scope"
            )
        args = [
            "gh",
            "api",
            "--hostname",
            "github.com",
            "--method",
            method,
            endpoint,
            "--include",
            "-H",
            "Accept: application/vnd.github+json",
            "-H",
            "X-GitHub-Api-Version: 2022-11-28",
        ]
        if body is not None:
            args.extend(["--input", "-"])
        async with self.limit:
            process = await asyncio.create_subprocess_exec(
                *args,
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            try:
                output, _error = await asyncio.wait_for(
                    process.communicate(
                        canonical(body).encode() if body is not None else None
                    ),
                    timeout=45,
                )
            except (TimeoutError, asyncio.CancelledError):
                with suppress(ProcessLookupError):
                    process.kill()
                await process.wait()
                raise
        text = output.decode("utf-8").replace("\r\n", "\n")
        header, _, content = text.partition("\n\n")
        match = re.match(r"HTTP/\S+ (\d{3})", header)
        status = int(match[1]) if match else 0
        if status == 404 and missing_ok:
            return None
        if process.returncode != 0 or not 200 <= status < 300:
            raise PolicyError(
                f"GitHub {method} {endpoint}: HTTP {status or 'unavailable'}. Check gh authentication, permissions and plan support; no downgrade or automatic write retry was attempted."
            )
        if not content.strip():
            return None
        try:
            return cast(Json, json.loads(content))
        except json.JSONDecodeError as error:
            raise PolicyError("GitHub returned malformed JSON") from error


@dataclass(frozen=True)
class Snapshot:
    """Only the metadata needed to detect drift; no secrets or unlisted variable values."""

    repository: Object
    reviewer: Object
    environments: dict[str, Object | None]
    branches: dict[str, list[Json]]
    custom_rules: dict[str, list[Json]]
    variables: dict[str, str | None]

    def fingerprint(self) -> str:
        """Include observed state so a stale approved plan cannot overwrite changes."""
        return hashlib.sha256(
            canonical(
                cast(
                    Json,
                    {
                        "repository": self.repository,
                        "reviewer": self.reviewer,
                        "environments": self.environments,
                        "branches": self.branches,
                        "custom_rules": self.custom_rules,
                        "variables": self.variables,
                    },
                )
            ).encode()
        ).hexdigest()


async def collect(api: Api, config: Configuration) -> Snapshot:
    """Read the whole relevant state before any mutation and reject incomplete pages."""
    repository, reviewer = await asyncio.gather(
        api.request("GET", API_ROOT), api.request("GET", "users/Tomyshh")
    )
    repo, person = object_value(repository, "repository"), object_value(
        reviewer, "reviewer"
    )
    if (
        repo.get("full_name") != REPOSITORY
        or repo.get("default_branch") != config.default_branch
    ):
        raise PolicyError(
            "Repository identity/default branch changed; review workflow and OIDC restrictions"
        )
    if (
        person.get("login") != config.reviewer_login
        or person.get("id") != config.reviewer_id
    ):
        raise PolicyError("Reviewer login/id no longer matches the reviewed identity")
    environments: dict[str, Object | None] = {}
    branches: dict[str, list[Json]] = {}
    custom_rules: dict[str, list[Json]] = {}
    variables: dict[str, str | None] = {}

    async def read_variable(base: str, name: str) -> None:
        raw = await api.request("GET", f"{base}/{name}", missing_ok=True)
        value = object_value(raw, name).get("value") if raw is not None else None
        variables[f"{base}/{name}"] = validate_variable(name, value)

    async def read_environment(desired: DesiredEnvironment) -> None:
        base = f"{API_ROOT}/environments/{quote(desired.name, safe='')}"
        raw = await api.request("GET", base, missing_ok=True)
        environments[desired.name] = (
            object_value(raw, desired.name) if raw is not None else None
        )
        branches[desired.name], custom_rules[desired.name] = [], []
        if raw is None:
            for name in desired.variables:
                variables[f"{base}/variables/{name}"] = None
            return
        unrestricted = (
            object_value(raw, desired.name).get("deployment_branch_policy") is None
        )
        policies, custom = await asyncio.gather(
            api.request(
                "GET",
                f"{base}/deployment-branch-policies?per_page=100",
                missing_ok=unrestricted,
            ),
            api.request("GET", f"{base}/deployment_protection_rules?per_page=100"),
        )
        if policies is None and unrestricted:
            # GitHub returns 404 until custom deployment refs are enabled.
            policies = {"total_count": 0, "branch_policies": []}
        for payload, key, target in (
            (policies, "branch_policies", branches),
            (custom, "custom_deployment_protection_rules", custom_rules),
        ):
            result = object_value(payload, desired.name)
            items = array_value(result.get(key), key)
            if result.get("total_count") != len(items):
                raise PolicyError(
                    f"{desired.name}: incomplete {key} response; refusing partial policy state"
                )
            target[desired.name] = items
        await asyncio.gather(
            *(read_variable(f"{base}/variables", name) for name in desired.variables)
        )

    await asyncio.gather(
        *(read_environment(env) for env in config.environments),
        *(
            read_variable(f"{API_ROOT}/actions/variables", name)
            for name in config.variables
        ),
    )
    # Strip unrelated metadata; repository.updated_at changes on ordinary pushes.
    repo = {
        key: repo.get(key)
        for key in ("full_name", "default_branch", "private", "permissions")
    }
    person = {key: person.get(key) for key in ("login", "id")}
    return Snapshot(repo, person, environments, branches, custom_rules, variables)


@dataclass(frozen=True)
class Operation:
    """One bounded REST mutation whose full public payload is reviewable."""

    method: Method
    endpoint: str
    body: Object

    def json(self) -> Object:
        """Serialize without command strings or authentication details."""
        return {"method": self.method, "endpoint": self.endpoint, "body": self.body}


@dataclass(frozen=True)
class Plan:
    """Immutable reviewed operations and the exact observed starting state."""

    baseline: str
    operations: tuple[Operation, ...]
    warnings: tuple[str, ...]
    stable_signing_main: bool = False

    def digest(self) -> str:
        """Bind approval to both changes and their observed preconditions."""
        return hashlib.sha256(
            canonical(
                {
                    "baseline": self.baseline,
                    "stable_signing_main": self.stable_signing_main,
                    "operations": [op.json() for op in self.operations],
                }
            ).encode()
        ).hexdigest()

    def json(self) -> Object:
        """Machine-readable plan; operational messages go to stderr."""
        return {
            "repository": REPOSITORY,
            "stable_signing_main": self.stable_signing_main,
            "plan_sha256": self.digest(),
            "operations": [op.json() for op in self.operations],
            "warnings": list(self.warnings),
        }


def build_plan(
    config: Configuration, state: Snapshot, *, stable_signing_main: bool = False
) -> Plan:
    """Only add protections or preserve stronger ones; reject ambiguous drift."""
    operations: list[Operation] = []
    main_rule = Operation(
        "POST",
        f"{API_ROOT}/environments/{STABLE_SIGNING}/deployment-branch-policies",
        {"type": "branch", "name": "main"},
    )
    warnings = [
        "Branch protection/rulesets and administrator bypass are not managed by this tool.",
        "No signing readiness is inferred. MOKAID_DESKTOP_ONLY stays false.",
    ]
    if state.repository.get("private") is not False:
        warnings.append(
            "Private repositories need GitHub Enterprise for required reviewers; API failures are fatal, never downgraded."
        )

    def variable_ops(base: str, desired: dict[str, str | None]) -> None:
        for name, wanted in sorted(desired.items()):
            if wanted is None:
                warnings.append(f"Unresolved/unmanaged variable: {base}/{name}")
                continue
            path = f"{base}/{name}"
            current = state.variables[path]
            if current == wanted:
                continue
            if current is not None:
                raise PolicyError(
                    f"{path}: existing value differs (redacted). No automatic replacement; review configuration/state."
                )
            operations.append(Operation("POST", base, {"name": name, "value": wanted}))

    for desired in config.environments:
        name = desired.name
        base = f"{API_ROOT}/environments/{name}"
        current = state.environments[name]
        if stable_signing_main and name == STABLE_SIGNING:
            if current is None or type(current.get("can_admins_bypass")) is not bool:
                raise PolicyError(
                    "Stable main migration requires an existing environment with known bypass controls"
                )
        if state.custom_rules[name]:
            raise PolicyError(
                f"{name}: custom deployment protections exist; no automatic changes"
            )
        old_refs = refs(cast(Json, state.branches[name]), name)
        reviewers: list[Json] = []
        wait, prevent = 0, False
        if current is not None:
            seen_types: set[str] = set()
            for raw in array_value(current.get("protection_rules"), name):
                rule = object_value(raw, name)
                kind = rule.get("type")
                if not isinstance(kind, str) or kind in seen_types:
                    raise PolicyError(f"{name}: malformed or duplicate protection rule")
                seen_types.add(kind)
                if kind == "wait_timer":
                    if (
                        type(rule.get("wait_timer")) is not int
                        or not 0 <= cast(int, rule["wait_timer"]) <= 43200
                    ):
                        raise PolicyError(f"{name}: invalid existing wait timer")
                    wait = cast(int, rule["wait_timer"])
                elif kind == "required_reviewers":
                    if type(rule.get("prevent_self_review")) is not bool:
                        raise PolicyError(
                            f"{name}: malformed existing self-review policy"
                        )
                    prevent = rule.get("prevent_self_review") is True
                    for raw_reviewer in array_value(rule.get("reviewers"), name):
                        reviewer = object_value(raw_reviewer, name)
                        identity = object_value(reviewer.get("reviewer"), name)
                        if (
                            reviewer.get("type") not in ("User", "Team")
                            or type(identity.get("id")) is not int
                            or cast(int, identity["id"]) <= 0
                        ):
                            raise PolicyError(f"{name}: malformed reviewer identity")
                        reviewers.append(
                            {"type": reviewer.get("type"), "id": identity.get("id")}
                        )
                    if not 1 <= len(reviewers) <= 6:
                        raise PolicyError(f"{name}: malformed reviewer list")
                elif kind != "branch_policy":
                    raise PolicyError(
                        f"{name}: unknown protection type; refusing to replace it"
                    )
        expected_reviewers: list[Json] = (
            [{"type": "User", "id": config.reviewer_id}]
            if desired.require_reviewer
            else []
        )
        if reviewers and expected_reviewers and reviewers != expected_reviewers:
            raise PolicyError(
                f"{name}: reviewers differ; approval lists are OR, not additive security"
            )
        if reviewers and not expected_reviewers:
            warnings.append(
                f"{name}: preserving existing additional reviewer requirement"
            )
        wanted: Object = {
            "wait_timer": max(wait, desired.wait_timer),
            "prevent_self_review": prevent or desired.prevent_self_review,
            "reviewers": reviewers or expected_reviewers,
            "deployment_branch_policy": {
                "protected_branches": False,
                "custom_branch_policies": True,
            },
        }
        mode = current.get("deployment_branch_policy") if current else None
        if stable_signing_main and name == STABLE_SIGNING and mode is None:
            raise PolicyError(
                "Stable main migration requires the existing custom branch policy mode"
            )
        if mode is not None and mode != wanted["deployment_branch_policy"]:
            raise PolicyError(
                f"{name}: protected-branch policy cannot be safely compared to custom refs"
            )
        migrate_main = (
            stable_signing_main
            and name == STABLE_SIGNING
            and old_refs == SIGNING_TAG_REFS
            and desired.allowed_refs == STABLE_SIGNING_REFS
        )
        if mode is not None and old_refs != desired.allowed_refs and not migrate_main:
            raise PolicyError(
                f"{name}: existing custom refs differ (including narrower/empty policies); no broadening/removal. Review partial applies manually."
            )
        if mode is None and old_refs:
            raise PolicyError(
                f"{name}: unexpected stale custom refs while all branches are enabled"
            )
        old: Object = {
            "wait_timer": wait,
            "prevent_self_review": prevent,
            "reviewers": reviewers,
            "deployment_branch_policy": mode,
        }
        if current is None or old != wanted:
            if current and current.get("can_admins_bypass") is False:
                raise PolicyError(
                    f"{name}: strict admin-bypass control exists but has no documented PUT field; refusing a potentially weakening update"
                )
            operations.append(Operation("PUT", base, wanted))
        if mode is None:
            for kind, pattern in desired.allowed_refs:
                operations.append(
                    Operation(
                        "POST",
                        f"{base}/deployment-branch-policies",
                        {"type": kind, "name": pattern},
                    )
                )
        elif migrate_main:
            operations.append(main_rule)
        variable_ops(f"{base}/variables", desired.variables)
    variable_ops(f"{API_ROOT}/actions/variables", config.variables)
    if stable_signing_main:
        if operations and operations != [main_rule]:
            raise PolicyError(
                "Stable main migration permits only the single main branch POST or a no-op; other drift must be reviewed separately"
            )
        warnings.append(
            "Explicit stable-only main migration: no environment PUT, ref removal, variable mutation, workflow dispatch or artifact upload is authorized."
        )
    return Plan(
        state.fingerprint(), tuple(operations), tuple(warnings), stable_signing_main
    )


def verify_stable_main_preservation(
    before: Snapshot, after: Snapshot, *, added: bool
) -> None:
    """Verify exact preservation beyond minimum desired controls after the POST.

    Only the new main rule and the target environment's server-owned updated_at
    may change. Existing rule identities, stronger controls, other environments
    and every observed public variable must remain identical. A no-op permits
    no changes at all. A mismatch never triggers a repair or retry.
    """
    normalized = after
    if added:
        previous = object_value(before.environments[STABLE_SIGNING], STABLE_SIGNING)
        current = dict(object_value(after.environments[STABLE_SIGNING], STABLE_SIGNING))
        if "updated_at" in previous:
            current["updated_at"] = previous["updated_at"]
        else:
            current.pop("updated_at", None)
        branches = [
            rule
            for rule in after.branches[STABLE_SIGNING]
            if refs([rule], STABLE_SIGNING) != (("branch", "main"),)
        ]
        normalized = replace(
            after,
            environments={**after.environments, STABLE_SIGNING: current},
            branches={**after.branches, STABLE_SIGNING: branches},
        )
    if normalized.fingerprint() != before.fingerprint():
        raise PolicyError(
            "Stable main migration read-back did not preserve the reviewed state; inspect immediately, no automatic repair or retry"
        )


async def execute(
    api: Api, config: Configuration, plan: Plan, expected_digest: str
) -> Plan:
    """Re-read immediately before writes and verify exact convergence afterwards."""
    if plan.digest() != expected_digest:
        raise PolicyError(
            "Plan fingerprint does not match --expect-plan; review a fresh --plan"
        )
    fresh = await collect(api, config)
    permissions = object_value(fresh.repository.get("permissions"), "permissions")
    if permissions.get("admin") is not True:
        raise PolicyError(
            "Applying environment controls requires repository Administration: write"
        )
    if fresh.fingerprint() != plan.baseline:
        raise PolicyError("GitHub state changed after planning; no writes performed")
    if plan.stable_signing_main:
        checked = build_plan(config, fresh, stable_signing_main=True)
        if checked.digest() != plan.digest():
            raise PolicyError("Stable main migration differs from the reviewed plan")
    for operation in plan.operations:
        print(f"Applying {operation.method} {operation.endpoint}", file=sys.stderr)
        await api.request(operation.method, operation.endpoint, operation.body)
    after = await collect(api, config)
    verified = build_plan(config, after, stable_signing_main=plan.stable_signing_main)
    if verified.operations:
        raise PolicyError(
            "Post-apply verification did not converge; inspect state, do not blindly retry"
        )
    if plan.stable_signing_main:
        verify_stable_main_preservation(fresh, after, added=bool(plan.operations))
    return verified


def parser() -> argparse.ArgumentParser:
    """Consistent noninteractive CLI; default mode is read-only."""
    result = argparse.ArgumentParser(description=__doc__)
    mode = result.add_mutually_exclusive_group()
    mode.add_argument("--plan", action="store_true", help="Read-only plan (default)")
    mode.add_argument(
        "--apply",
        action="store_true",
        help="Apply the exact reviewed plan; requires --expect-plan",
    )
    result.add_argument(
        "--stable-signing-main",
        action="store_true",
        help="Only add branch main to the already protected stable signing environment; reject all other mutations",
    )
    result.add_argument(
        "--expect-plan",
        metavar="SHA256",
        help="Digest from a previously reviewed --plan",
    )
    result.add_argument(
        "--config",
        type=Path,
        default=Path(__file__).with_name("desired.json"),
        help="Reviewed non-secret desired JSON",
    )
    result.add_argument("--version", action="version", version=VERSION)
    return result


async def run(arguments: argparse.Namespace) -> int:
    """Load policy before authentication/network; print JSON only to stdout."""
    if arguments.apply and not re.fullmatch(
        r"[a-f0-9]{64}", arguments.expect_plan or ""
    ):
        raise PolicyError(
            "--apply requires --expect-plan SHA256 from the reviewed read-only plan"
        )
    config = Configuration.parse(
        cast(Json, json.loads(arguments.config.read_text(encoding="utf-8")))
    )
    api = GhApi(allow_writes=arguments.apply)
    planned = build_plan(
        config,
        await collect(api, config),
        stable_signing_main=arguments.stable_signing_main,
    )
    print(json.dumps(planned.json(), indent=2))
    if arguments.apply:
        await execute(api, config, planned, arguments.expect_plan)
        print(
            "Configuration applied and verified. No release was published.",
            file=sys.stderr,
        )
    return 0


def main() -> int:
    """Convert expected failures into concise diagnostics without leaking API bodies."""
    try:
        return asyncio.run(run(parser().parse_args()))
    except KeyboardInterrupt:
        print(
            "Interrupted. Re-plan before retrying; partial protected state may remain.",
            file=sys.stderr,
        )
        return 130
    except (PolicyError, OSError, TimeoutError, json.JSONDecodeError) as error:
        print(f"Configuration stopped: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
