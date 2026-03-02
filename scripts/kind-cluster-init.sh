#!/usr/bin/env bash
# kind-cluster-init.sh
#
# Purpose:
#   Recreate the tilt-study kind cluster using rootful podman.
#   This is required because rootless podman cannot delegate cgroup v2
#   controllers in this environment (user.slice/cgroup.subtree_control
#   requires root to initialize). Rootful podman bypasses this constraint.
#
# Prerequisites:
#   - sudo access (administrative privileges required)
#   - ./bin/kind available (run scripts/install-tools.sh first)
#   - Rootful podman socket: /run/podman/podman.sock (requires root)
#
# Usage:
#   cd <repo-root>
#   bash scripts/kind-cluster-init.sh
#
# After running this script:
#   export PATH=$(pwd)/bin:$PATH
#   tilt ci    # or: tilt up --host 0.0.0.0 --port 10350

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
KIND_BIN="${REPO_ROOT}/bin/kind"
CLUSTER_NAME="tilt-study"
KUBECONFIG_PATH="${HOME}/.kube/config"

if [[ ! -x "${KIND_BIN}" ]]; then
  echo "ERROR: ${KIND_BIN} not found. Run scripts/install-tools.sh first."
  exit 1
fi

echo "Checking for existing cluster..."
# Use rootful podman to query kind clusters
if sudo env KIND_EXPERIMENTAL_PROVIDER=podman DOCKER_HOST=unix:///run/podman/podman.sock \
    "${KIND_BIN}" get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "Cluster '${CLUSTER_NAME}' already exists. Skipping creation."
else
  echo "Creating kind cluster '${CLUSTER_NAME}' via rootful podman..."
  sudo env \
    KIND_EXPERIMENTAL_PROVIDER=podman \
    DOCKER_HOST=unix:///run/podman/podman.sock \
    "${KIND_BIN}" create cluster --name "${CLUSTER_NAME}"
  echo "Cluster created."
fi

echo "Exporting kubeconfig to /tmp/kind-${CLUSTER_NAME}.yaml..."
sudo env KUBECONFIG=/root/.kube/config \
    "${KIND_BIN}" export kubeconfig \
    --name "${CLUSTER_NAME}" \
    --kubeconfig "/tmp/kind-${CLUSTER_NAME}.yaml"
sudo chmod 644 "/tmp/kind-${CLUSTER_NAME}.yaml"

echo "Merging kubeconfig into ${KUBECONFIG_PATH}..."
mkdir -p "${HOME}/.kube"
if [[ -f "${KUBECONFIG_PATH}" ]]; then
  KUBECONFIG="${KUBECONFIG_PATH}:/tmp/kind-${CLUSTER_NAME}.yaml" \
    kubectl config view --flatten > /tmp/merged-kubeconfig.yaml
  cp /tmp/merged-kubeconfig.yaml "${KUBECONFIG_PATH}"
else
  cp "/tmp/kind-${CLUSTER_NAME}.yaml" "${KUBECONFIG_PATH}"
fi

echo "Switching kubectl context to kind-${CLUSTER_NAME}..."
kubectl config use-context "kind-${CLUSTER_NAME}"

echo "Verifying cluster access..."
kubectl cluster-info
kubectl get nodes

echo ""
echo "Setup complete. Cluster 'kind-${CLUSTER_NAME}' is ready."
echo "Run: export PATH=$(pwd)/bin:\$PATH && tilt ci"
