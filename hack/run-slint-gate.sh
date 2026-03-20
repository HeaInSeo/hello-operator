#!/usr/bin/env bash
# hack/run-slint-gate.sh
#
# Bridge script: find the latest sli-summary and run slint_gate.py.
#
# Friction note: kube-slint harness writes sli-summary with a dynamic filename:
#   artifacts/sli-summary.{runId}.{testCase}.json
# slint_gate.py expects a fixed path: artifacts/sli-summary.json
# This script bridges the gap by normalizing the latest summary inside artifacts/.
#
# This workaround is hello-operator-specific and must be documented.
# The filename pattern defaults to the hello-operator fixture testcase identifier.
# Override with SLI_TEST_CASE or the first positional argument if needed.
#
# Usage:
#   bash hack/run-slint-gate.sh [test_case]
#   test_case defaults to ${SLI_TEST_CASE:-hello-sample-create}
#
# Dependencies:
#   - python3
#   - pyyaml (pip install pyyaml)
#   - vendored slint_gate.py at hack/third_party/slint_gate.py
#
# Optional override:
#   - SLINT_GATE_PY=/path/to/slint_gate.py bash hack/run-slint-gate.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEFAULT_SLINT_GATE_PY="${REPO_ROOT}/hack/third_party/slint_gate.py"
SLINT_GATE_PY="${SLINT_GATE_PY:-${DEFAULT_SLINT_GATE_PY}}"

TEST_CASE="${1:-${SLI_TEST_CASE:-hello-sample-create}}"
ARTIFACTS_DIR="${REPO_ROOT}/artifacts"
SLI_DIR="${ARTIFACTS_DIR}"
POLICY_FILE="${REPO_ROOT}/.slint/policy.yaml"
OUTPUT_FILE="${ARTIFACTS_DIR}/slint-gate-summary.json"
FIXED_SUMMARY="${ARTIFACTS_DIR}/sli-summary.json"

# Sanity checks
if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 not found in PATH"
  echo "  slint-gate evaluator requires python3 to run the vendored evaluator."
  echo "  Install Python 3 first, then rerun this script."
  exit 1
fi

if ! python3 -c "import yaml" >/dev/null 2>&1; then
  echo "ERROR: missing Python dependency: pyyaml"
  echo "  slint-gate reads .slint/policy.yaml, so the vendored evaluator needs 'import yaml'."
  echo "  Install it with one of:"
  echo "    python3 -m pip install pyyaml"
  echo "    pip3 install pyyaml"
  echo "  Then rerun: bash hack/run-slint-gate.sh"
  exit 1
fi

if [ ! -f "${SLINT_GATE_PY}" ]; then
  echo "ERROR: slint_gate.py not found at ${SLINT_GATE_PY}"
  echo "  Default vendored path: ${DEFAULT_SLINT_GATE_PY}"
  echo "  Override with SLINT_GATE_PY=/path/to/slint_gate.py if needed."
  exit 1
fi

if [ ! -f "${POLICY_FILE}" ]; then
  echo "ERROR: .slint/policy.yaml not found at ${POLICY_FILE}"
  echo "  Create it first (see .slint/policy.yaml)."
  exit 1
fi

# Find latest sli-summary for the given test case
LATEST=$(ls -t "${SLI_DIR}"/sli-summary.*."${TEST_CASE}".json 2>/dev/null | head -1 || true)

if [ -z "${LATEST}" ]; then
  echo "WARNING: no sli-summary found in ${SLI_DIR} for test_case=${TEST_CASE}"
  echo "  Run 'go test ./test/e2e/ -run TestHelloSLIMock' first to generate a summary."
  echo "  Proceeding without measurement summary (slint_gate will produce NO_GRADE)."
  FIXED_SUMMARY_ARG="artifacts/sli-summary.json"  # intentionally missing for NO_GRADE test
else
  mkdir -p "${ARTIFACTS_DIR}"
  cp "${LATEST}" "${FIXED_SUMMARY}"
  echo "Copied: ${LATEST}"
  echo "     -> ${FIXED_SUMMARY}"
  FIXED_SUMMARY_ARG="${FIXED_SUMMARY}"
fi

echo ""
echo "Running slint_gate.py..."
echo "  --measurement-summary ${FIXED_SUMMARY_ARG}"
echo "  --policy              ${POLICY_FILE}"
echo "  --output              ${OUTPUT_FILE}"
echo ""

python3 "${SLINT_GATE_PY}" \
  --measurement-summary "${FIXED_SUMMARY_ARG}" \
  --policy "${POLICY_FILE}" \
  --output "${OUTPUT_FILE}"

echo ""
echo "Output: ${OUTPUT_FILE}"
echo ""
python3 -c "
import json, sys
with open('${OUTPUT_FILE}') as f:
    d = json.load(f)
print('gate_result       :', d.get('gate_result'))
print('evaluation_status :', d.get('evaluation_status'))
print('measurement_status:', d.get('measurement_status'))
print('baseline_status   :', d.get('baseline_status'))
print('reasons           :', d.get('reasons'))
print()
for c in d.get('checks', []):
    print(f'  [{c[\"status\"]:8s}] {c[\"name\"]} | observed={c[\"observed\"]} | expected={c[\"expected\"]}')
print()
print('overall_message   :', d.get('overall_message'))
"
