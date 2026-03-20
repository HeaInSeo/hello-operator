#!/usr/bin/env python3
"""
Vendored from github.com/HeaInSeo/kube-slint.
Source commit: 904bc10a0afa6db6fda36e6ad1bc05a5528f879b
Sync rule: update this copy only when hello-operator intentionally adopts a new
RC baseline evaluator from kube-slint.
"""

"""
slint-gate minimal evaluator (v1)

Inputs:
- measurement summary JSON (kube-slint summary)
- policy YAML
- optional baseline JSON

Output:
- slint-gate-summary.json (machine-readable gate result)
"""

import argparse
import json
import math
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Tuple

import yaml

SCHEMA_VERSION = "slint.gate.v1"

GATE_PASS = "PASS"
GATE_WARN = "WARN"
GATE_FAIL = "FAIL"
GATE_NO_GRADE = "NO_GRADE"

EVAL_EVALUATED = "evaluated"
EVAL_PARTIAL = "partially_evaluated"
EVAL_NOT = "not_evaluated"

MEAS_OK = "ok"
MEAS_MISSING = "missing"
MEAS_CORRUPT = "corrupt"
MEAS_INSUFFICIENT = "insufficient"

BASE_PRESENT = "present"
BASE_ABSENT_FIRST = "absent_first_run"
BASE_UNAVAILABLE = "unavailable"
BASE_CORRUPT = "corrupt"

POLICY_OK = "ok"
POLICY_MISSING = "missing"
POLICY_INVALID = "invalid"

REASON_THRESHOLD_MISS = "THRESHOLD_MISS"
REASON_REGRESSION_DETECTED = "REGRESSION_DETECTED"
REASON_BASELINE_ABSENT_FIRST_RUN = "BASELINE_ABSENT_FIRST_RUN"
REASON_BASELINE_UNAVAILABLE = "BASELINE_UNAVAILABLE"
REASON_BASELINE_CORRUPT = "BASELINE_CORRUPT"
REASON_MEASUREMENT_INPUT_MISSING = "MEASUREMENT_INPUT_MISSING"
REASON_MEASUREMENT_INPUT_CORRUPT = "MEASUREMENT_INPUT_CORRUPT"
REASON_POLICY_MISSING = "POLICY_MISSING"
REASON_POLICY_INVALID = "POLICY_INVALID"
REASON_RELIABILITY_INSUFFICIENT = "RELIABILITY_INSUFFICIENT"


def now_utc_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def add_reason(reasons: List[str], code: str) -> None:
    if code not in reasons:
        reasons.append(code)


def safe_read_json(path: Path) -> Tuple[Dict[str, Any], str]:
    if not path.exists():
        return {}, "missing"
    try:
        with path.open("r", encoding="utf-8") as f:
            data = json.load(f)
        if not isinstance(data, dict):
            return {}, "corrupt"
        return data, "ok"
    except Exception:
        return {}, "corrupt"


def safe_read_yaml(path: Path) -> Tuple[Dict[str, Any], str]:
    if not path.exists():
        return {}, "missing"
    try:
        with path.open("r", encoding="utf-8") as f:
            data = yaml.safe_load(f)
        if not isinstance(data, dict):
            return {}, "invalid"
        return data, "ok"
    except Exception:
        return {}, "invalid"


def to_result_value_map(summary: Dict[str, Any]) -> Dict[str, float]:
    values: Dict[str, float] = {}
    for item in summary.get("results", []) if isinstance(summary.get("results"), list) else []:
        if not isinstance(item, dict):
            continue
        sid = item.get("id")
        val = item.get("value")
        if isinstance(sid, str) and isinstance(val, (int, float)):
            values[sid] = float(val)
    return values


def compare(value: float, op: str, target: float) -> bool:
    if op == "<=":
        return value <= target
    if op == "<":
        return value < target
    if op == ">=":
        return value >= target
    if op == ">":
        return value > target
    if op in ("==", "="):
        return value == target
    raise ValueError(f"unsupported operator: {op}")


def reliability_rank(collection_status: str) -> int:
    normalized = str(collection_status).strip().lower()
    if normalized == "complete":
        return 2
    if normalized == "partial":
        return 1
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Evaluate slint-gate policy over summary outputs.")
    parser.add_argument(
        "--measurement-summary",
        default="artifacts/sli-summary.json",
        help="Path to measurement summary JSON",
    )
    parser.add_argument(
        "--policy",
        default=".slint/policy.yaml",
        help="Path to slint policy YAML",
    )
    parser.add_argument(
        "--baseline",
        default="",
        help="Optional baseline summary JSON path",
    )
    parser.add_argument(
        "--output",
        default="slint-gate-summary.json",
        help="Output path for slint-gate summary JSON",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    measurement_path = Path(args.measurement_summary)
    policy_path = Path(args.policy)
    baseline_path = Path(args.baseline) if str(args.baseline).strip() else None
    output_path = Path(args.output)

    summary_out: Dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "gate_result": GATE_NO_GRADE,
        "evaluation_status": EVAL_NOT,
        "measurement_status": MEAS_OK,
        "baseline_status": BASE_ABSENT_FIRST,
        "policy_status": POLICY_OK,
        "reasons": [],
        "evaluated_at": now_utc_iso(),
        "input_refs": {
            "measurement_summary": str(measurement_path),
            "policy_file": str(policy_path),
            "baseline_file": str(baseline_path) if baseline_path else None,
        },
        "checks": [],
        "overall_message": "",
    }

    reasons: List[str] = summary_out["reasons"]
    checks: List[Dict[str, Any]] = summary_out["checks"]

    policy, policy_state = safe_read_yaml(policy_path)
    if policy_state == "missing":
        summary_out["policy_status"] = POLICY_MISSING
        add_reason(reasons, REASON_POLICY_MISSING)
    elif policy_state == "invalid":
        summary_out["policy_status"] = POLICY_INVALID
        add_reason(reasons, REASON_POLICY_INVALID)
    else:
        summary_out["policy_status"] = POLICY_OK

    measurement, meas_state = safe_read_json(measurement_path)
    if meas_state == "missing":
        summary_out["measurement_status"] = MEAS_MISSING
        add_reason(reasons, REASON_MEASUREMENT_INPUT_MISSING)
    elif meas_state == "corrupt":
        summary_out["measurement_status"] = MEAS_CORRUPT
        add_reason(reasons, REASON_MEASUREMENT_INPUT_CORRUPT)
    else:
        summary_out["measurement_status"] = MEAS_OK

    baseline: Dict[str, Any] = {}
    if baseline_path is None:
        summary_out["baseline_status"] = BASE_ABSENT_FIRST
    else:
        baseline, base_state = safe_read_json(baseline_path)
        if base_state == "missing":
            summary_out["baseline_status"] = BASE_UNAVAILABLE
            add_reason(reasons, REASON_BASELINE_UNAVAILABLE)
        elif base_state == "corrupt":
            summary_out["baseline_status"] = BASE_CORRUPT
            add_reason(reasons, REASON_BASELINE_CORRUPT)
        else:
            summary_out["baseline_status"] = BASE_PRESENT

    can_evaluate = summary_out["policy_status"] == POLICY_OK and summary_out["measurement_status"] == MEAS_OK
    if not can_evaluate:
        summary_out["gate_result"] = GATE_NO_GRADE
        summary_out["evaluation_status"] = EVAL_NOT
        summary_out["overall_message"] = "Policy or measurement input unavailable; gate not evaluated."
        write_output(output_path, summary_out)
        print(output_path)
        return 0

    current_values = to_result_value_map(measurement)
    baseline_values = to_result_value_map(baseline) if summary_out["baseline_status"] == BASE_PRESENT else {}

    fail_on = set(policy.get("fail_on", [])) if isinstance(policy.get("fail_on"), list) else set()
    if not fail_on:
        fail_on = {"threshold_miss", "regression_detected"}

    thresholds = policy.get("thresholds", [])
    if not isinstance(thresholds, list):
        thresholds = []

    threshold_failed = False
    any_no_grade = False
    any_warn = False

    for rule in thresholds:
        if not isinstance(rule, dict):
            continue
        name = str(rule.get("name", "unnamed-threshold"))
        metric = str(rule.get("metric", "")).strip()
        op = str(rule.get("operator", "")).strip()
        target = rule.get("value")

        check = {
            "name": name,
            "category": "threshold",
            "status": "no_grade",
            "metric": metric,
            "observed": None,
            "expected": f"{op} {target}",
            "message": "",
        }

        if metric == "" or metric not in current_values or not isinstance(target, (int, float)):
            check["status"] = "no_grade"
            check["message"] = "metric missing or invalid threshold target"
            add_reason(reasons, REASON_MEASUREMENT_INPUT_MISSING)
            any_no_grade = True
            checks.append(check)
            continue

        observed = current_values[metric]
        check["observed"] = observed
        try:
            matched = compare(observed, op, float(target))
        except Exception:
            check["status"] = "no_grade"
            check["message"] = "invalid operator"
            add_reason(reasons, REASON_POLICY_INVALID)
            any_no_grade = True
            checks.append(check)
            continue

        if matched:
            check["status"] = "pass"
            check["message"] = "within threshold"
        else:
            check["status"] = "fail"
            check["message"] = "threshold miss"
            add_reason(reasons, REASON_THRESHOLD_MISS)
            if "threshold_miss" in fail_on:
                threshold_failed = True
        checks.append(check)

    regression_cfg = policy.get("regression", {})
    if not isinstance(regression_cfg, dict):
        regression_cfg = {}
    regression_enabled = bool(regression_cfg.get("enabled", False))
    tolerance_percent = float(regression_cfg.get("tolerance_percent", 0))

    if regression_enabled:
        if summary_out["baseline_status"] == BASE_ABSENT_FIRST:
            add_reason(reasons, REASON_BASELINE_ABSENT_FIRST_RUN)
            any_warn = True
            any_no_grade = True
        elif summary_out["baseline_status"] in (BASE_UNAVAILABLE, BASE_CORRUPT):
            any_no_grade = True
        else:
            for rule in thresholds:
                if not isinstance(rule, dict):
                    continue
                metric = str(rule.get("metric", "")).strip()
                if metric == "":
                    continue
                check = {
                    "name": f"regression:{metric}",
                    "category": "regression",
                    "status": "no_grade",
                    "metric": metric,
                    "observed": current_values.get(metric),
                    "expected": f"abs(delta_percent) <= {tolerance_percent}",
                    "message": "",
                }
                if metric not in current_values or metric not in baseline_values:
                    check["status"] = "no_grade"
                    check["message"] = "metric missing in current/baseline"
                    any_no_grade = True
                    checks.append(check)
                    continue

                current = current_values[metric]
                base = baseline_values[metric]
                if base == 0:
                    delta_pct = math.inf if current != 0 else 0.0
                else:
                    delta_pct = ((current - base) / abs(base)) * 100.0

                check["observed"] = delta_pct
                if abs(delta_pct) > tolerance_percent:
                    check["status"] = "fail"
                    check["message"] = "regression detected"
                    add_reason(reasons, REASON_REGRESSION_DETECTED)
                    if "regression_detected" in fail_on:
                        threshold_failed = True
                else:
                    check["status"] = "pass"
                    check["message"] = "within regression tolerance"
                checks.append(check)

    reliability_cfg = policy.get("reliability", {})
    if not isinstance(reliability_cfg, dict):
        reliability_cfg = {}
    reliability_required = bool(reliability_cfg.get("required", False))
    min_level = str(reliability_cfg.get("min_level", "partial")).strip().lower()
    required_rank = 1 if min_level == "partial" else 2

    collection_status = ""
    reliability = measurement.get("reliability")
    if isinstance(reliability, dict):
        collection_status = str(reliability.get("collectionStatus", ""))
    actual_rank = reliability_rank(collection_status)

    rel_check = {
        "name": "reliability-minimum",
        "category": "reliability",
        "status": "pass",
        "metric": "reliability.collectionStatus",
        "observed": collection_status or None,
        "expected": f">= {min_level}",
        "message": "reliability requirement satisfied",
    }
    if reliability_required and actual_rank < required_rank:
        rel_check["status"] = "warn"
        rel_check["message"] = "reliability below required level"
        add_reason(reasons, REASON_RELIABILITY_INSUFFICIENT)
        summary_out["measurement_status"] = MEAS_INSUFFICIENT
        any_warn = True
    checks.append(rel_check)

    if not checks:
        summary_out["evaluation_status"] = EVAL_NOT
    elif any(c.get("status") == "no_grade" for c in checks) or any_no_grade:
        summary_out["evaluation_status"] = EVAL_PARTIAL
    else:
        summary_out["evaluation_status"] = EVAL_EVALUATED

    if threshold_failed:
        summary_out["gate_result"] = GATE_FAIL
    elif any(c.get("status") == "warn" for c in checks) or any_warn:
        summary_out["gate_result"] = GATE_WARN
    elif summary_out["baseline_status"] == BASE_ABSENT_FIRST and regression_enabled:
        summary_out["gate_result"] = GATE_WARN
    elif any(c.get("status") == "no_grade" for c in checks) or any_no_grade:
        summary_out["gate_result"] = GATE_NO_GRADE
    else:
        summary_out["gate_result"] = GATE_PASS

    if summary_out["gate_result"] == GATE_FAIL:
        summary_out["overall_message"] = "Policy violation detected (threshold/regression)."
    elif summary_out["gate_result"] == GATE_WARN:
        summary_out["overall_message"] = "Policy evaluated with non-blocking warnings."
    elif summary_out["gate_result"] == GATE_NO_GRADE:
        summary_out["overall_message"] = "Policy could not be fully evaluated."
    else:
        summary_out["overall_message"] = "Policy checks passed."

    write_output(output_path, summary_out)
    print(output_path)
    return 0


def write_output(path: Path, payload: Dict[str, Any]) -> None:
    with path.open("w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)
        f.write("\n")


if __name__ == "__main__":
    sys.exit(main())
