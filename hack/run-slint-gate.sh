#!/usr/bin/env bash
# hack/run-slint-gate.sh
#
# Bridge script: find the latest sli-summary and run slint_gate.py.
#
# Friction note: kube-slint harness writes sli-summary with a dynamic filename:
#   /tmp/sli-results/sli-summary.{runId}.{testCase}.json
# slint_gate.py expects a fixed path: artifacts/sli-summary.json
# This script bridges the gap by copying the latest file to artifacts/.
#
# This workaround is hello-operator-specific and must be documented.
# The filename pattern is hardcoded to "hello-sample-create" (the TestCase value
# in sli_integration_test.go and sli_e2e_test.go).
# A generic consumer would need to adjust this.
#
# Usage:
#   bash hack/run-slint-gate.sh [test_case]
#   test_case defaults to "hello-sample-create"
#
# Dependencies:
#   - python3
#   - pyyaml (pip install pyyaml)
#   - kube-slint repo at ../kube-slint relative to this repo

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
KUBE_SLINT_DIR="$(cd "${REPO_ROOT}/../kube-slint" && pwd)"
SLINT_GATE_PY="${KUBE_SLINT_DIR}/hack/slint_gate.py"

TEST_CASE="${1:-hello-sample-create}"
SLI_DIR="/tmp/sli-results"
ARTIFACTS_DIR="${REPO_ROOT}/artifacts"
POLICY_FILE="${REPO_ROOT}/.slint/policy.yaml"
OUTPUT_FILE="${ARTIFACTS_DIR}/slint-gate-summary.json"
FIXED_SUMMARY="${ARTIFACTS_DIR}/sli-summary.json"

# Sanity checks
if [ ! -f "${SLINT_GATE_PY}" ]; then
  echo "ERROR: slint_gate.py not found at ${SLINT_GATE_PY}"
  echo "  Expected kube-slint repo at: ${KUBE_SLINT_DIR}"
  echo "  Friction: slint_gate.py is not distributed separately from kube-slint repo."
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
