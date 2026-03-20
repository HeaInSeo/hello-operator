# hello-operator Codex Operating Rules

## 1. Operating Goal

This repo exists to validate how easily `kube-slint` attaches to a consumer operator repository.

It is not primarily maintained as a generic sample operator. It is the canonical consumer validation repo and should preserve honest integration friction, reporting, and repeatable consumer-side evidence.

## 2. Source Of Truth Hierarchy

1. `AGENTS.md`
2. This file
3. `docs/KUBE_SLINT_DX_AUDIT.md` as audit/evidence, not rule-setting authority
4. `docs/KUBE_SLINT_CONSUMER_UX_TEST_REPORT.md` as audit/evidence, not rule-setting authority
5. `docs/PROGRESS_LOG.md`
6. `Tiltfile`
7. `hack/run-slint-gate.sh`
8. `.slint/policy.yaml`
9. `test/e2e/sli_*`
10. `README.md`
11. Kubebuilder-generated defaults and generic sample-operator guidance

Rules:

- Repo behavior and operating rules come from `AGENTS.md` and this file first.
- Consumer-friction evidence comes from the audit/report documents.
- Current runnable integration shape is validated by `Tiltfile`, `hack/run-slint-gate.sh`, `.slint/policy.yaml`, and `test/e2e/sli_*`.
- README is an entry point and may contain Kubebuilder defaults, but it is not the final authority if it conflicts with the consumer-validation docs.

## 3. Repo Operating Model

- `tmux` window = one repo.
- `worktree` = one parallel change unit.
- Parallel agents may explore and compare evidence, but only the main thread should integrate writes.

Recommended `tmux` layout:

- Window 1: `kube-slint`
- Window 2: `hello-operator`
- Window 3: scratch or coordination

## 4. Agent Responsibilities

- Consumer integration / friction audit agent
  - Read the audit/report docs, SLI tests, Tiltfile, and gate bridge script first.
  - Focus on adoption friction, packaging gaps, path mismatches, and assumptions.
  - Prefer reporting over silent local workarounds.
- Docs / reporting agent
  - Keep README, AGENTS, progress log, and audit/report authority aligned.
  - Preserve enough Kubebuilder context for the fixture to stay usable, but do not let that context redefine repo identity.

## 5. When To Stop At Docs And Reporting

Do not change product behavior when the task is:

- repo identity cleanup
- source-of-truth clarification
- DX audit/report consolidation
- Codex operating-rules setup
- tmux/worktree/agent workflow setup

In those cases, document the issue, preserve current behavior, and record the next recommended validation step.

## 6. Progress Log And Audit Rules

- `docs/PROGRESS_LOG.md` tracks actual work stages and environment history.
- `docs/KUBE_SLINT_DX_AUDIT.md` records deeper integration friction analysis.
- `docs/KUBE_SLINT_CONSUMER_UX_TEST_REPORT.md` records concrete consumer-side validation results.
- If a newer report supersedes an older one, lower the older document's authority explicitly instead of erasing it.

## 7. Repeated Skill Candidates

Design-first skill candidates for future Codex workflows:

- `repo-scan`: repo-identity and source-of-truth scan
- `workflow-audit`: CI/Tilt/test path audit from the consumer side
- `consumer-friction-check`: repeatable kube-slint attachment review
- `progress-log-update`: disciplined reporting update flow

If formal skills are later added, keep them skeleton-only until repetition proves stable value.

## 8. Today’s Consolidation Result

- This repo is explicitly fixed as the canonical consumer validation repo for `kube-slint`.
- Kubebuilder defaults remain as fixture scaffolding, not as the governing repo identity.
- Audit/report docs remain important evidence, but they no longer outrank the repo rule documents.

## 9. Codex Config Caution

`.codex/config.toml` is intentionally left without active keys until a verified Codex config schema is available locally. Do not add guessed keys.

## 10. Recommended Procedure

1. Read `AGENTS.md`.
2. Read `docs/KUBE_SLINT_DX_AUDIT.md` and `docs/KUBE_SLINT_CONSUMER_UX_TEST_REPORT.md`.
3. Check `Tiltfile`, `hack/run-slint-gate.sh`, `.slint/policy.yaml`, and `test/e2e/sli_*` for current runnable integration shape.
4. Decide whether the task is reporting-only or needs real validation.
5. Keep parallel exploration read-only and integrate writes in the main thread.
6. Report facts, intent, file changes, and unresolved friction separately.
