#!/usr/bin/env bash
# kind-init.sh
#
# Purpose:
#   Load env vars for kind + ko workflow into the *current shell*.
#
# Usage:
#   source kind-init.sh
#   # or:
#   . kind-init.sh
#
# NOTE:
#   If you run: ./kind-init.sh
#   the exports only apply to the child process and will NOT persist.

# Must be sourced, not executed.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "ERROR: This script must be sourced:" >&2
  echo "  source kind-init.sh" >&2
  exit 1
fi

# Optional sanity check: run from repo root
if [[ ! -f "go.mod" ]]; then
  echo "ERROR: run from repo root (go.mod not found)." >&2
  echo "Tip: cd to the repo root, then: source kind-init.sh" >&2
  return 1
fi

# kind + ko settings (edit if needed)
export KO_DOCKER_REPO="kind.local"
export KIND_CLUSTER_NAME="tilt-study"
export KUBECONTEXT="kind-tilt-study"

echo "OK: kind env loaded"
echo "  KO_DOCKER_REPO=$KO_DOCKER_REPO"
echo "  KIND_CLUSTER_NAME=$KIND_CLUSTER_NAME"
echo "  KUBECONTEXT=$KUBECONTEXT"