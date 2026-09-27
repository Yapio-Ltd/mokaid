"""Summarize a saved Jev routing evaluation offline, without provider calls.

Usage: python3 summarize.py /absolute/path/to/results-directory
Incomplete runs are reported to stdout without writing summary.json unless
--allow-incomplete is supplied. The original manifest/results are never edited.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import statistics
from collections import Counter
from datetime import UTC, datetime
from itertools import combinations
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
SCORE_KEYS = (
    "mode_correct", "routing_correct", "usable_correct",
    "harmful_no_fit_assignment", "usable_harmful_no_fit_assignment",
    "unnecessary_custom",
)
VALID_STATUSES = {"ok", "error", "not_attempted"}


def ratio(numerator: int, denominator: int) -> dict[str, Any]:
    return {"count": numerator, "denominator": denominator,
            "rate": round(numerator / denominator, 6) if denominator else None}


def timing(values: list[float]) -> dict[str, Any]:
    """Nearest-rank p95; the aggregate is summed observations, not elapsed time."""
    ordered = sorted(values)
    return {
        "n": len(ordered),
        "median_seconds": round(statistics.median(ordered), 4) if ordered else None,
        "p95_seconds": ordered[math.ceil(0.95 * len(ordered)) - 1] if ordered else None,
        "max_seconds": ordered[-1] if ordered else None,
        "sum_observed_seconds": round(sum(ordered), 4),
    }


def decision_view(row: dict[str, Any] | None, raw: bool = False) -> dict[str, Any] | None:
    if row is None:
        return None
    decision = ((row.get("result") or {}).get("recommendation") if raw
                else row.get("decision")) or {}
    view = {"status": row["status"], "mode": decision.get("mode"),
            "agent_id": decision.get("agent_id"),
            "fallback_required": bool(decision.get("fallback_required", False))}
    if not raw and "full_fit" in decision:
        view["selected_full_fit"] = decision["full_fit"].get(decision.get("agent_id"))
    return view


def decision_key(row: dict[str, Any], raw: bool = False) -> tuple[Any, ...]:
    decision = decision_view(row, raw) or {}
    return tuple(decision.get(k) for k in ("mode", "agent_id", "fallback_required"))


def score_metrics(rows: list[dict[str, Any]], field: str = "score") -> dict[str, Any]:
    attempted = [r for r in rows if r["status"] != "not_attempted"]
    successful = [r for r in rows if r["status"] == "ok"]
    # Missing raw scores are not silently treated as incorrect model decisions.
    scored = [r for r in successful if isinstance(r.get(field), dict)]
    unscored = len(successful) - len(scored)
    result = {"successful_with_score": len(scored),
              "successful_missing_score": unscored}
    for key in SCORE_KEYS:
        count = sum(bool(r[field].get(key, False)) for r in scored)
        result[key] = {
            "among_successful": ratio(count, len(successful)),
            "among_successful_scored": ratio(count, len(scored)),
            "among_all_attempted": ratio(count, len(attempted)),
        }
        if unscored:
            for denominator in ("among_successful", "among_all_attempted"):
                result[key][denominator].update(rate=None, unscored_successes=unscored)
    return result


def basic_metrics(rows: list[dict[str, Any]], expected_count: int) -> dict[str, Any]:
    counts = Counter(r["status"] for r in rows)
    return {
        "scheduled": expected_count, "recorded": len(rows),
        "attempted": counts["ok"] + counts["error"],
        "successful": counts["ok"], "errors": counts["error"],
        "not_attempted": counts["not_attempted"],
        "pending_unrecorded": expected_count - len(rows),
        "eventual_success_among_attempted": ratio(counts["ok"], counts["ok"] + counts["error"]),
        "normalized_score": score_metrics(rows),
    }


def cost_and_usage(rows: list[dict[str, Any]]) -> dict[str, Any]:
    measured = [r for r in rows if isinstance(r.get("usage"), dict)]
    costs = [r["estimated_cost_usd"] for r in rows if isinstance(r.get("estimated_cost_usd"), (int, float))]
    calls = [call for r in rows for call in r.get("model_calls", [])]
    return {
        "records_with_usage": len(measured),
        "prompt_tokens": sum(r["usage"].get("prompt_tokens", 0) for r in measured),
        "completion_tokens": sum(r["usage"].get("completion_tokens", 0) for r in measured),
        "total_tokens": sum(r["usage"].get("total_tokens", 0) for r in measured),
        "records_with_cost_estimate": len(costs),
        "estimated_cost_usd": round(sum(costs), 8) if costs else None,
        "recorded_model_calls": len(calls),
        "models": dict(Counter(c["model"] for c in calls)),
        "cost_basis": "Application price table estimate, not provider invoice; absent data is unknown, not free.",
    }


def availability_and_timing(rows: list[dict[str, Any]], provider: str) -> dict[str, Any]:
    attempted = [r for r in rows if r["status"] != "not_attempted"]
    successful = [r for r in rows if r["status"] == "ok"]
    attempts = [a for r in rows for a in r.get("attempts", [])]
    successful_api_times = [
        r["attempts"][-1]["seconds"] for r in successful
        if r.get("attempts") and r["attempts"][-1].get("http_status") == 200
    ]
    first_success = sum(r["status"] == "ok" and len(r.get("attempts", [])) == 1 for r in attempted)
    return {
        "first_http_attempt_success": ratio(first_success, len(attempted)) if provider == "jev" else None,
        "first_http_attempt_scope": "HTTP attempts exposed only for Jev; Haiku dispatcher fallback calls are not individual HTTP telemetry.",
        "http_attempts_recorded": len(attempts),
        "http_status_counts": dict(Counter(str(a.get("http_status", "unknown")) for a in attempts)),
        "http_429_attempts": sum(a.get("http_status") == 429 for a in attempts),
        "cases_with_429": sum(any(a.get("http_status") == 429 for a in r.get("attempts", [])) for r in rows),
        "cases_with_retries": sum(len(r.get("attempts", [])) > 1 for r in rows),
        "retry_attempts": sum(max(0, len(r.get("attempts", [])) - 1) for r in rows),
        "successful_api_attempt_seconds": timing(successful_api_times) if provider == "jev" else None,
        "successful_workflow_wall_seconds_including_retries": timing([r["seconds"] for r in successful if "seconds" in r]),
        "all_attempted_workflow_wall_seconds_including_retries": timing([r["seconds"] for r in attempted if "seconds" in r]),
        "timing_scope": "Jev supplies only routing; Haiku generates the full proposal. Recorded case wall times include internal retries, exclude queue wait and Jev one-second pacing. Summed observations are not elapsed run time.",
    }


def provider_summary(provider: str, rows: list[dict[str, Any]], cases: list[dict[str, Any]], expected_total: int) -> dict[str, Any]:
    primary = [r for r in rows if not r.get("repeat_of")]
    result = basic_metrics(primary, len(cases))
    result["including_repeats_counts_and_scores"] = basic_metrics(rows, expected_total)
    result["timing_and_availability"] = availability_and_timing(primary, provider)
    result["usage_primary"] = cost_and_usage(primary)
    result["usage_including_repeats"] = cost_and_usage(rows)
    result["availability_including_repeats"] = availability_and_timing(rows, provider)
    result["error_types"] = dict(Counter(r.get("error_type", str(r.get("http_status", "unspecified"))) for r in primary if r["status"] == "error"))
    result["not_attempted_reasons"] = dict(Counter(r.get("reason", "unspecified") for r in primary if r["status"] == "not_attempted"))
    result["fallback_required_successes"] = sum(bool((r.get("decision") or {}).get("fallback_required")) for r in primary if r["status"] == "ok")
    if provider == "haiku":
        result["raw_score"] = score_metrics(primary, "raw_score")
        valid = [r for r in primary if r["status"] == "ok"]
        result["full_schema_valid"] = ratio(sum(r.get("full_schema_valid") is True for r in valid), len(valid))
        needs_profile = [r for r in valid if (r.get("decision") or {}).get("mode") in {"custom_agent", "user_choice"}]
        missing_profiles = [r for r in needs_profile if not isinstance(
            (r.get("result") or {}).get("recommendation", {}).get("custom_agent"), dict)]
        result["proposal_completeness"] = {
            "required_custom_profiles_present": ratio(len(needs_profile) - len(missing_profiles), len(needs_profile)),
            "missing_required_custom_profile_count": len(missing_profiles),
            "missing_required_custom_profiles": [
                {"id": r["id"], "language": r["language"], "family": r["family"],
                 "normalized_mode": r["decision"]["mode"], "raw_mode": r["result"]["recommendation"].get("mode"),
                 "routing_correct": r["score"]["routing_correct"],
                 "full_schema_valid": r.get("full_schema_valid"),
                 "issue": "The routing mode needs a specialist profile, but custom_agent is absent or null. This is proposal incompleteness, not a routing mismatch."}
                for r in missing_profiles
            ],
            "scope": "Primary successful Haiku records only. custom_agent and user_choice require a custom profile after normalization. Presence is separate from routing accuracy and does not establish profile quality. The Pydantic schema permits null profiles, so schema validity does not guarantee this cross-field invariant.",
        }
        result["normalization_changes"] = [
            {"id": r["id"], "raw": decision_view(r, True), "normalized": decision_view(r),
             "raw_routing_correct": r.get("raw_score", {}).get("routing_correct"),
             "normalized_routing_correct": r["score"]["routing_correct"]}
            for r in valid if decision_key(r, True) != decision_key(r)
        ]
        constrained = {c["id"]: c["expected"]["confidence_max"] for c in cases if "confidence_max" in c["expected"]}
        result["vague_confidence_policy_violations"] = [
            r["id"] for r in valid if r["id"] in constrained
            and (r.get("result", {}).get("recommendation", {}).get("confidence", 101) > constrained[r["id"]])
        ]
    for group_key in ("language", "category"):
        result["by_" + group_key] = {}
        for group in sorted({c[group_key] for c in cases}):
            relevant = [r for r in primary if r[group_key] == group]
            result["by_" + group_key][group] = basic_metrics(relevant, sum(c[group_key] == group for c in cases))
    result["by_family"] = {
        family: basic_metrics([r for r in primary if r["family"] == family], sum(c["family"] == family for c in cases))
        for family in sorted({c["family"] for c in cases})
    }
    return result


def repeated_decisions(rows: list[dict[str, Any]], expected_repeats: int) -> dict[str, Any]:
    by_id = {r["id"]: r for r in rows}
    repeats = [r for r in rows if r.get("repeat_of")]
    pairs = [(by_id.get(r["repeat_of"]), r) for r in repeats]
    successful = [(a, b) for a, b in pairs if a and a["status"] == b["status"] == "ok"]
    same = sum(decision_key(a) == decision_key(b) for a, b in successful)
    return {
        "scheduled_repeats": expected_repeats,
        "recorded_repeats": len(repeats),
        "attempted_repeats": sum(r["status"] != "not_attempted" for r in repeats),
        "successful_repeats": sum(r["status"] == "ok" for r in repeats),
        "both_successful_pairs": len(successful),
        "same_decision_and_gate": ratio(same, len(successful)),
        "pairs": [
            {"original_id": b["repeat_of"], "repeat_id": b["id"],
             "original": decision_view(a), "repeat": decision_view(b),
             "same_decision_and_gate": decision_key(a) == decision_key(b) if a and a["status"] == b["status"] == "ok" else None}
            for a, b in pairs
        ],
    }


def paired_comparison(a_name: str, b_name: str, indexed: dict[tuple[str, str], dict[str, Any]], cases: list[dict[str, Any]]) -> dict[str, Any]:
    pairs = [(c, indexed.get((a_name, c["id"])), indexed.get((b_name, c["id"]))) for c in cases]
    both = [(c, a, b) for c, a, b in pairs if a and b and a["status"] == b["status"] == "ok"]
    outcomes: Counter[str] = Counter()
    mismatches = []
    for c, a, b in both:
        a_ok, b_ok = bool(a["score"]["usable_correct"]), bool(b["score"]["usable_correct"])
        outcomes["both_correct" if a_ok and b_ok else "a_only_correct" if a_ok else "b_only_correct" if b_ok else "neither_correct"] += 1
        if decision_key(a) != decision_key(b) or a_ok != b_ok:
            mismatches.append({"id": c["id"], "family": c["family"], "language": c["language"], "expected": c["expected"],
                               a_name: decision_view(a), b_name: decision_view(b),
                               "a_usable_correct": a_ok, "b_usable_correct": b_ok})
    return {
        "a": a_name, "b": b_name, "scheduled_pairs": len(cases),
        "both_successful": len(both),
        "a_only_successful": sum(bool(a and a["status"] == "ok") and not (b and b["status"] == "ok") for _, a, b in pairs),
        "b_only_successful": sum(bool(b and b["status"] == "ok") and not (a and a["status"] == "ok") for _, a, b in pairs),
        "paired_usable_outcomes": {k: outcomes[k] for k in ("both_correct", "a_only_correct", "b_only_correct", "neither_correct")},
        "a_usable_correct_among_both_successful": ratio(outcomes["both_correct"] + outcomes["a_only_correct"], len(both)),
        "b_usable_correct_among_both_successful": ratio(outcomes["both_correct"] + outcomes["b_only_correct"], len(both)),
        "decision_mismatches": mismatches,
        "interpretation": "Paired descriptive comparison only; translated cases are correlated within 24 families, so 72 independent trials must not be assumed.",
    }


def summarize(directory: Path, cases_path: Path) -> dict[str, Any]:
    manifest = json.loads((directory / "manifest.json").read_text())
    dataset_bytes = cases_path.read_bytes()
    dataset = json.loads(dataset_bytes)
    dataset_hash = hashlib.sha256(dataset_bytes).hexdigest()
    if dataset_hash != manifest["dataset_sha256"]:
        raise ValueError("Dataset hash differs from the frozen run manifest.")
    results_bytes = (directory / "results.jsonl").read_bytes()
    # A partial final JSONL line signals a run still writing; do not silently skip it.
    rows = [json.loads(line) for line in results_bytes.decode().splitlines() if line.strip()]
    providers = manifest["providers"]
    cases = dataset["cases"][:manifest["unique_cases"]]
    case_by_id = {c["id"]: c for c in cases}
    indexed: dict[tuple[str, str], dict[str, Any]] = {}
    for row in rows:
        key = row["provider"], row["id"]
        if key in indexed:
            raise ValueError(f"Duplicate provider/case record: {key}")
        if row["provider"] not in providers or row["status"] not in VALID_STATUSES:
            raise ValueError(f"Unknown provider/status: {key}")
        case_id = row.get("repeat_of") or row["id"]
        if case_id not in case_by_id:
            raise ValueError(f"Unknown case: {key}")
        if any(row[k] != case_by_id[case_id][k] for k in ("family", "language", "category")):
            raise ValueError(f"Case metadata mismatch: {key}")
        indexed[key] = row
    expected_repeats = manifest["cases_with_repeats"] - len(cases)
    complete = all(
        sum(r["provider"] == p for r in rows) == manifest["cases_with_repeats"]
        and all((p, c["id"]) in indexed for c in cases)
        for p in providers
    )
    summaries = {p: provider_summary(p, [r for r in rows if r["provider"] == p], cases, manifest["cases_with_repeats"]) for p in providers}
    failures = []
    for row in rows:
        if row.get("repeat_of") or (row["status"] == "ok" and row["score"]["usable_correct"]):
            continue
        case = case_by_id[row["id"]]
        failures.append({
            "provider": row["provider"], "id": row["id"], "family": row["family"],
            "language": row["language"], "category": row["category"],
            "failure_kind": "routing_or_gate" if row["status"] == "ok" else row["status"],
            "instruction": case["payload"]["instruction"], "expected": case["expected"],
            "actual": decision_view(row), "score": row["score"],
            "raw_score": row.get("raw_score"),
            "returned_reason": (row.get("result") or {}).get("recommendation", {}).get("reason"),
            "error_type": row.get("error_type"), "http_status": row.get("http_status"),
            "reason": row.get("reason"),
        })
    return {
        "summary_version": "1.0.0", "complete": complete,
        "generated_at": datetime.now(UTC).isoformat(),
        "manifest": manifest, "dataset_sha256": dataset_hash,
        "results_sha256": hashlib.sha256(results_bytes).hexdigest(),
        "observed_records": len(rows), "expected_records": len(providers) * manifest["cases_with_repeats"],
        "primary_cases": len(cases), "scenario_families": len({c["family"] for c in cases}),
        "metric_definitions": {
            "primary": "All headline accuracy metrics exclude records with repeat_of. Repeat records are analyzed separately.",
            "attempted": "Successful plus error records; excludes explicit not_attempted and unrecorded pending cases.",
            "raw_routing": "score.routing_correct evaluates selected mode and ID before the fallback usability gate. For Haiku this is already after Phoenix-like normalization; raw_score reports the original recommendation separately.",
            "usable": "score.usable_correct also requires no fallback_required. It does not claim Jev can generate a complete task or custom profile.",
            "rates": "Each metric includes explicit count and denominator. Error records lower all-attempted correctness; transport failures are not described as wrong model decisions. If successful records lack a score, affected full-denominator rates are unknown (null); among_successful_scored uses only observed scores.",
            "p95": "Nearest-rank percentile among the observations specified by each field.",
        },
        "limitations": [
            "Synthetic model-authored, independently agent-reviewed policy labels; not human-validated production ground truth.",
            "24 scenario families have correlated EN/FR/HE variants; 72 observations are not independent scenarios.",
            "Partial-fit requests explicitly ask for both options; this is an exploratory policy-compliance set.",
            "Unchanged Haiku dispatcher and purpose-built Jev prompt are different workflows, including different injection instructions.",
            "Haiku generates complete dispatch proposals, while Jev supplies routing only; latency and costs are not equivalent end-to-end comparisons.",
            "Jev gateway default model version is undisclosed; observed community-gateway behavior must not be attributed to a known TypeSafe model version.",
            "Jev cost is unknown without usage/pricing data. Haiku cost is an application-table estimate, not an invoice.",
            "A complete run may include cases not attempted because the documented availability circuit opened.",
        ],
        "providers": summaries,
        "repeats": {p: repeated_decisions([r for r in rows if r["provider"] == p], expected_repeats) for p in providers},
        "paired_primary_comparisons": [paired_comparison(a, b, indexed, cases) for a, b in combinations(providers, 2)],
        "failures": failures,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--cases", type=Path, default=HERE / "cases.json")
    parser.add_argument("--allow-incomplete", action="store_true")
    args = parser.parse_args()
    result = summarize(args.directory, args.cases)
    if not result["complete"] and not args.allow_incomplete:
        print(json.dumps({"complete": False, "observed_records": result["observed_records"],
                          "expected_records": result["expected_records"],
                          "message": "Run is incomplete; summary.json was not written."}))
        return 2
    output = args.directory / "summary.json"
    output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"complete": result["complete"], "summary": str(output.resolve()),
                      "primary_counts": {p: {k: s[k] for k in ("attempted", "successful", "errors", "not_attempted", "pending_unrecorded")}
                                         for p, s in result["providers"].items()}}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
