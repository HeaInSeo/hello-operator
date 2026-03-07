# kube-slint Consumer UX Test Report

**Date:** 2026-03-07
**Validator:** hello-operator (consumer-side validation repo)
**kube-slint version tested:** v1.0.0-rc.1 (go.mod: 58c0d88, 2026-03-02)
**slint-gate version tested:** 678b50c (2026-03-07, hack/slint_gate.py)
**Environment:** ko + Tilt + kind (kind-tilt-study, k8s v1.31.0, RHEL 8)

---

## 1. Purpose

This report documents the consumer-side experience of attaching kube-slint's
latest guardrail flow to hello-operator. The goal is not architectural
correctness but honest friction measurement.

hello-operator is a temporary consumer-side validation project. Every friction
point, path mismatch, and confusing UX is intentionally preserved and reported
rather than silently fixed.

---

## 2. Current kube-slint Integration State

### Go module import

```
github.com/HeaInSeo/kube-slint v1.0.0-rc.1.0.20260302080738-58c0d8811314
```

go.mod pins to commit 58c0d88. The latest kube-slint is at 678b50c (2026-03-07),
which includes Gap G fix (SnapshotFetcher) and the new slint-gate tooling.
The pin has not been updated yet; all integration below uses the old version.

### Test code integration points

| File | Integration |
|---|---|
| test/e2e/sli_integration_test.go | Mock test: httptest.Server + custom MetricsFetcher injected into harness.SessionConfig |
| test/e2e/sli_e2e_test.go | E2E test: curlpod direct fetch + manual snapshotFetcher workaround (Gap G) |

### Kubernetes resources

| File | Purpose |
|---|---|
| config/rbac/sli_checker_serviceaccount.yaml | SA: sli-checker (kustomize namePrefix → hello-operator-sli-checker) |
| config/rbac/sli_checker_clusterrolebinding.yaml | CRB: sli-checker → metrics-reader ClusterRole |

### Tiltfile integration

```
local_resource('sli-mock-test', auto_init=False)   # Phase 1: no cluster needed
local_resource('sli-e2e-test', auto_init=False)    # Phase 2/3: real cluster
```

### New additions (this cycle)

```
.slint/policy.yaml              # minimum viable policy
hack/run-slint-gate.sh          # bridge: find latest summary → slint_gate.py
artifacts/.gitkeep              # placeholder for generated artifacts
```

---

## 3. Actual Measurement Summary Path

### Where summaries are written

```
/tmp/sli-results/sli-summary.{runId}.{testCase}.json
```

Concrete example:
```
/tmp/sli-results/sli-summary.local-1772888598.hello-sample-create.json
```

Properties:
- **Location:** /tmp (outside the project directory)
- **Filename:** dynamic, includes runId (UNIX timestamp) and testCase string
- **No fixed path:** the harness never writes a stable "latest" filename
- **Not committed:** /tmp is ephemeral, cleared on reboot

### What slint_gate.py expects by default

```
artifacts/sli-summary.json
```

Properties:
- **Location:** inside project directory
- **Filename:** fixed
- **Expected to be committed or available as CI artifact**

### Gap: path mismatch

This is the most significant friction found in this cycle.

The harness and the gate evaluator use incompatible path conventions.
There is no built-in mechanism to bridge them.

Required workaround: `hack/run-slint-gate.sh` finds the latest
sli-summary file by glob pattern, copies it to `artifacts/sli-summary.json`,
then invokes slint_gate.py.

The bridge script hardcodes the testCase string `hello-sample-create`.
A consumer with a different testCase would need to change this string manually.
This is a portability risk.

Root cause assignment: **kube-slint** — the harness ArtifactsDir + filename
convention does not produce a stable, consumer-addressable path.

---

## 4. `.slint/policy.yaml` Placement

### Placement result

`.slint/policy.yaml` was placed at the root of the hello-operator repo.

The placement feels natural. It mirrors the `.slint/` convention from kube-slint
itself, and the directory name implies a clear boundary between operator code
and guardrail configuration.

### Minimum viable policy used

```yaml
schema_version: "slint.policy.v1"
thresholds:
  - name: "workqueue_depth_end_max"
    metric: "workqueue_depth_end"
    operator: "<="
    value: 5
    severity: "fail"
  - name: "reconcile_total_delta_min"
    metric: "reconcile_total_delta"
    operator: ">="
    value: 1
    severity: "fail"
regression:
  enabled: false
first_run:
  default_result: "warn"
  evaluate_thresholds: true
  evaluate_regression: false
baseline:
  required: false
  on_unavailable: "warn"
  on_corrupt: "no_grade"
fail_on:
  - "threshold_miss"
```

### Observation

Writing a minimum viable policy is straightforward if you already know which
metric IDs exist. The schema is clean and the field names are unambiguous.

However, knowing which metric IDs are safe to reference requires reading the
sli-summary.json output first. There is no documented list of available metric
IDs per SLI preset in the kube-slint README. The consumer must run the test
once and inspect the output before writing a meaningful policy.

---

## 5. slint-gate Integration

### Method

slint_gate.py is located in the kube-slint repo at `hack/slint_gate.py`.
It is not published as a pip package or standalone binary.

The bridge script `hack/run-slint-gate.sh` references it by resolving the
kube-slint repo path relative to hello-operator:

```bash
KUBE_SLINT_DIR="$(cd "${REPO_ROOT}/../kube-slint" && pwd)"
SLINT_GATE_PY="${KUBE_SLINT_DIR}/hack/slint_gate.py"
```

This assumes kube-slint is checked out next to hello-operator on disk.
This assumption holds on the current development machine but would break in CI
unless kube-slint is also cloned.

Dependency: python3 + pyyaml (pip install pyyaml). Both available on this host.

### Friction: slint_gate.py is not independently distributable

A real consumer cannot do `pip install kube-slint-gate`. They must:
1. Clone or download kube-slint separately
2. Know where hack/slint_gate.py is located
3. Install pyyaml manually

This is a meaningful adoption barrier for CI use.

Root cause assignment: **kube-slint** — no standalone distribution of the gate
evaluator.

---

## 6. Scenario Results

All scenarios were run against the sli-summary produced by TestHelloSLIMock
(mock test, no real cluster needed).

### Scenario 1: first-run, no baseline

**Command:** `bash hack/run-slint-gate.sh`
**Policy:** `.slint/policy.yaml` (regression disabled)

```
gate_result       : PASS
evaluation_status : evaluated
measurement_status: ok
baseline_status   : absent_first_run
reasons           : []
checks:
  [pass] workqueue_depth_end_max | observed=0.0 | expected=<= 5
  [pass] reconcile_total_delta_min | observed=3.0 | expected=>= 1
  [pass] reliability-minimum | observed=Complete | expected=>= partial
overall_message   : Policy checks passed.
```

**Assessment:** Clear and correct. PASS with baseline_status=absent_first_run is
unambiguous. A developer would understand this output without reading the docs.
**Rating: Easy**

---

### Scenario 2: measurement summary missing

**Command:** slint_gate.py with non-existent summary path

```
gate_result       : NO_GRADE
evaluation_status : not_evaluated
measurement_status: missing
reasons           : ['MEASUREMENT_INPUT_MISSING']
overall_message   : Policy or measurement input unavailable; gate not evaluated.
```

**Assessment:** Correct behavior. NO_GRADE is appropriate. The reason code is
clear. However, the message does not tell the consumer what path was expected
and where the file should come from. A first-time consumer seeing this in CI
would not immediately know they need to run the SLI test first and copy the
output to the expected path.
**Rating: Manageable**

---

### Scenario 3: policy file missing

**Command:** slint_gate.py with non-existent policy path

```
gate_result       : NO_GRADE
evaluation_status : not_evaluated
policy_status     : missing
reasons           : ['POLICY_MISSING']
overall_message   : Policy or measurement input unavailable; gate not evaluated.
```

**Assessment:** Correct. The message is the same as Scenario 2, which is slightly
confusing (same message for two different failure modes). A consumer would need
to check `policy_status` vs `measurement_status` to distinguish the two.
**Rating: Manageable**

---

### Scenario 4: threshold miss

**Policy:** reconcile_total_delta <= 0 (actual value is 3)

```
gate_result       : FAIL
evaluation_status : evaluated
reasons           : ['THRESHOLD_MISS']
checks:
  [fail] reconcile_total_delta_max | observed=3.0 | expected=<= 0
overall_message   : Policy violation detected (threshold/regression).
```

**Assessment:** Clear and correct. The check shows exactly what was observed vs
expected. A CI step would fail the job appropriately. Observed value is shown,
which is helpful for debugging a false positive threshold.
**Rating: Easy**

---

### Scenario 5: regression enabled, no baseline (first-run)

**Policy:** regression.enabled=true, tolerance_percent=5

```
gate_result       : WARN
evaluation_status : partially_evaluated
baseline_status   : absent_first_run
reasons           : ['BASELINE_ABSENT_FIRST_RUN']
checks:
  [pass] workqueue_depth_end_max | observed=0.0 | expected=<= 5
overall_message   : Policy evaluated with non-blocking warnings.
```

**Assessment:** Correct first-run behavior. WARN is non-blocking. The consumer
understands they are in first-run mode and regression will be evaluated once a
baseline exists. However, there is no guidance on how to produce or store a
baseline. The consumer is left wondering: where do I save this run's output as
the baseline, and what command do I run next time?
**Rating: Manageable (but baseline lifecycle is undocumented for consumers)**

---

### Scenario 6: skip metric referenced in policy threshold

**Policy:** reconcile_success_delta >= 1 (this metric is "skip" in sli-summary due to label mismatch)

```
gate_result       : NO_GRADE
evaluation_status : partially_evaluated
reasons           : ['MEASUREMENT_INPUT_MISSING']
checks:
  [no_grade] reconcile_success_delta_min | observed=None | message=metric missing or invalid threshold target
overall_message   : Policy could not be fully evaluated.
```

**Assessment:** This is the most confusing result of all scenarios.

The consumer writes `reconcile_success_delta` in the policy — a completely
reasonable choice for an operator quality gate. The metric name is valid and
appears in the DefaultV3Specs documentation. But in practice this metric is
always "skip" because of a label mismatch (Gap A):
- controller-runtime exposes: `controller_runtime_reconcile_total{controller="hello",result="success"}`
- DefaultV3Specs filters by: `controller_runtime_reconcile_total{result="success"}`

The gate returns NO_GRADE with reason MEASUREMENT_INPUT_MISSING. There is no
indication that the metric was intentionally skipped during collection, or that
this is a known limitation of the default SLI preset.

To understand why, the consumer must:
1. Notice the NO_GRADE result
2. Open artifacts/sli-summary.json
3. Find reconcile_success_delta with status="skip" and reason="missing input metrics"
4. Then look at inputsMissing to understand the label mismatch
5. Then read the DX audit document to find the Gap A explanation

This is a 5-step debugging chain for a problem that looks like a configuration
error but is actually a library limitation.

**Rating: Painful**

---

## 7. Friction and Bug Inventory

### F-1: sli-summary path mismatch (Painful)

**Symptom:** The harness writes to `/tmp/sli-results/sli-summary.{runId}.{testCase}.json`
but slint_gate.py defaults to `artifacts/sli-summary.json`.

**Workaround:** `hack/run-slint-gate.sh` copies the latest file.

**Problem with workaround:** The testCase string (`hello-sample-create`) is
hardcoded in the script. Any operator with a different testCase name must edit
the script manually.

**Belongs to:** kube-slint — the harness should support writing a stable
fixed-name "latest" artifact alongside the per-run file.

---

### F-2: slint_gate.py not independently distributable (Manageable)

**Symptom:** A consumer cannot `pip install` the gate evaluator. They must
clone kube-slint, know the path, and install pyyaml manually.

**Workaround:** Reference by relative path from local kube-slint clone.

**Problem with workaround:** Breaks in CI unless kube-slint is also cloned.

**Belongs to:** kube-slint — no packaging for the evaluator.

---

### F-3: skip metric silently becomes NO_GRADE in policy (Painful)

**Symptom:** reconcile_success_delta and reconcile_error_delta are "skip" in
sli-summary due to label mismatch (Gap A). When referenced in policy, they
produce NO_GRADE with reason MEASUREMENT_INPUT_MISSING — with no explanation
linking back to the skip status in the measurement summary.

**Workaround:** Do not reference skip metrics in policy. Use reconcile_total_delta
instead.

**Problem:** The consumer cannot know this without reading the sli-summary and
the DX audit. The metric names look valid.

**Belongs to:** kube-slint — slint_gate.py could detect that the metric ID
appears in sli-summary but with status="skip" and emit a more specific reason
code such as `METRIC_WAS_SKIPPED_IN_COLLECTION`.

---

### F-4: baseline lifecycle not documented (Manageable)

**Symptom:** After the first run, the consumer sees WARN with
BASELINE_ABSENT_FIRST_RUN but has no guidance on how to promote the current
run as the baseline for the next run.

**Workaround:** Manually copy artifacts/sli-summary.json to a
"baseline.json" path and pass it to slint_gate.py with --baseline.

**Belongs to:** kube-slint — no baseline update workflow documented for
consumers.

---

### F-5: curlpod image pre-loading required for kind (Manageable)

**Symptom:** `curlimages/curl:latest` triggers `imagePullPolicy: Always` and
causes ImagePullBackOff in the kind node (no internet). Requires pre-loading
`curlimages/curl:kind-cached`.

**Workaround:** Documented in Gap F of KUBE_SLINT_DX_AUDIT.md; image
pre-loaded via kind-image-load.sh.

**Belongs to:** kube-slint — CurlImage should default to a non-latest tag or
document the kind pre-load requirement explicitly.

---

### F-6: snapshotFetcher workaround still required in E2E test (Manageable)

**Symptom:** go.mod is pinned to 58c0d88. SnapshotFetcher (Gap G fix) was
added in 4d3867c. Without updating, the E2E test must manually implement
snapshotFetcher by calling curlpod twice (before/after CR apply).

**Status:** kube-slint fixed this in 4d3867c. hello-operator has not updated
go.mod yet. The workaround remains in sli_e2e_test.go as adoption evidence.

**Belongs to:** hello-operator (pending go.mod update).

---

### F-7: RBAC serviceaccount name depends on kustomize namePrefix (Manageable)

**Symptom:** sli_checker_serviceaccount.yaml declares `name: sli-checker`.
After kustomize `namePrefix: hello-operator-`, it becomes
`hello-operator-sli-checker`. The test code hardcodes the post-prefix name.
A consumer without namePrefix knowledge would get auth failures and see
misleading permission errors.

**Belongs to:** hello-operator (documentation gap) / kube-slint (no guidance
on RBAC naming conventions with kustomize).

---

## 8. What Was Easy

1. **`slint_gate.py` output is readable.** All fields are named clearly.
   A developer can understand the gate result without reading documentation.

2. **Threshold evaluation is unambiguous.** PASS/FAIL with observed vs expected
   values is exactly what a developer needs when debugging a policy violation.

3. **Policy file format is clean.** The YAML schema is small and readable.
   Writing the minimum viable policy took under 5 minutes once metric IDs were
   known.

4. **First-run / no baseline behavior is correct and non-blocking.** PASS with
   baseline_status=absent_first_run does not confuse or alarm.

5. **Policy missing / summary missing → NO_GRADE (not crash, not FAIL).**
   The gate degrades gracefully. A missing input does not produce a false
   positive failure.

---

## 9. What Was Painful

1. **Finding the right sli-summary path.** The harness writes to /tmp with a
   dynamic filename. The gate evaluator expects a fixed path inside the project.
   There is no built-in bridge. A consumer must write their own bridge script.

2. **Understanding why reconcile_success_delta is unavailable.** The label
   mismatch (Gap A) makes the most natural quality signal (success rate)
   silently unavailable. The policy returns NO_GRADE with a generic reason
   instead of a specific explanation.

3. **No guidance on baseline lifecycle.** After first-run, the consumer sees
   WARN but does not know what to do next to establish a baseline.

---

## 10. Generalizability Assessment

### What would generalize to another Kubebuilder operator

- `.slint/policy.yaml` placement and format
- slint_gate.py invocation pattern (once slint_gate.py path is resolved)
- The SessionConfig / NewSession / Start / End API pattern in E2E tests
- RBAC resource structure (SA + CRB)

### What would NOT generalize without changes

- `hack/run-slint-gate.sh` hardcodes `hello-sample-create` as the testCase name
- `hack/run-slint-gate.sh` resolves kube-slint by sibling directory assumption
- Test code hardcodes `hello-operator-sli-checker` (post-namePrefix SA name)
- `/tmp/sli-results` is hardcoded in both test files as ArtifactsDir

For a second operator, a consumer would need to edit at minimum:
- ArtifactsDir in SessionConfig
- testCase name in run-slint-gate.sh
- SA name in sli_e2e_test.go
- Policy metric thresholds

This is 4 manual edits in 3 files. It is reproducible but not discoverable
without this document.

---

## 11. kube-slint Improvement Suggestions

| ID | Issue | Suggestion |
|---|---|---|
| SG-1 | Path mismatch | Harness should support writing a `sli-summary.latest.json` symlink or fixed alias alongside the per-run file |
| SG-2 | slint_gate.py distribution | Publish as standalone package or embed in a Makefile target that fetches it |
| SG-3 | Skip metric → NO_GRADE | slint_gate.py should check if metric appears in results with status="skip" and emit `METRIC_WAS_SKIPPED_IN_COLLECTION` instead of `MEASUREMENT_INPUT_MISSING` |
| SG-4 | Baseline lifecycle | Add a `--save-as-baseline` flag or document the exact workflow for promoting a run to baseline |
| SG-5 | Label mismatch (Gap A) | DefaultV3Specs should document which metrics require exact label matching vs aggregated access |
| SG-6 | CurlImage tag (Gap F) | Default CurlImage should be a pinned non-latest tag; kind pre-load requirement should be in README |

---

## 12. hello-operator Improvement Suggestions

| ID | Issue | Suggestion |
|---|---|---|
| HO-1 | ArtifactsDir in /tmp | Change to `artifacts/` inside project dir; add to .gitignore |
| HO-2 | Bridge script testCase hardcoding | Accept testCase as argument with default; document the naming convention |
| HO-3 | SA name hardcoding in test | Derive from kustomize namePrefix or document the value clearly |
| HO-4 | go.mod pin | Update to 4d3867c or later to remove snapshotFetcher workaround |

---

## 13. Final Evaluation

| Dimension | Rating | Notes |
|---|---|---|
| Adoption ease | Manageable | Go import and basic harness API are clean; path bridging is painful |
| Instrumentation correctness | Easy | SLI signals are collected correctly; mock test is reliable |
| Result understandability | Manageable | PASS/FAIL/WARN are clear; NO_GRADE from skip metric is confusing |
| Friction exposure | Painful | Path mismatch, skip metric → NO_GRADE, baseline lifecycle gap |
| Generalizability | Manageable | Pattern is reusable but requires 4 manual edits for a second operator |

**Overall: Manageable — the integration works, but a real consumer without this
document would spend significant time debugging the path mismatch and the
skip metric NO_GRADE situation.**
