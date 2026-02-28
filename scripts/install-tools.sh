#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="${ROOT_DIR}/bin"

TILT_VERSION="${TILT_VERSION:-v0.35.0}"
KO_VERSION="${KO_VERSION:-v0.17.1}"
KIND_VERSION="${KIND_VERSION:-v0.24.0}"

OS="$(uname | tr '[:upper:]' '[:lower:]')"
case "$(uname)" in
  Linux) OS_TITLE="Linux" ;;
  Darwin) OS_TITLE="Darwin" ;;
  *)
    echo "Unsupported OS: $(uname)" >&2
    exit 1
    ;;
esac
ARCH_RAW="$(uname -m)"
case "${ARCH_RAW}" in
  x86_64|amd64)
    ARCH="x86_64"
    ARCH_KIND="amd64"
    ;;
  aarch64|arm64)
    ARCH="arm64"
    ARCH_KIND="arm64"
    ;;
  *)
    echo "Unsupported architecture: ${ARCH_RAW}" >&2
    exit 1
    ;;
esac

mkdir -p "${BIN_DIR}"

download() {
  local url="$1"
  local out="$2"
  curl -fL --retry 3 --retry-delay 1 -o "${out}" "${url}"
}

install_tilt() {
  local tmp
  tmp="$(mktemp)"
  local version_no_v="${TILT_VERSION#v}"
  local url="https://github.com/tilt-dev/tilt/releases/download/${TILT_VERSION}/tilt.${version_no_v}.${OS}.${ARCH}.tar.gz"
  echo "[install] tilt ${TILT_VERSION} from ${url}"
  download "${url}" "${tmp}"
  tar -xzf "${tmp}" -C "${BIN_DIR}" tilt
  rm -f "${tmp}"
  chmod +x "${BIN_DIR}/tilt"
}

install_ko() {
  local tmp dir
  tmp="$(mktemp)"
  dir="$(mktemp -d)"
  local url="https://github.com/ko-build/ko/releases/download/${KO_VERSION}/ko_${KO_VERSION#v}_${OS_TITLE}_${ARCH}.tar.gz"
  echo "[install] ko ${KO_VERSION} from ${url}"
  download "${url}" "${tmp}"
  tar -xzf "${tmp}" -C "${dir}"
  mv "${dir}/ko" "${BIN_DIR}/ko"
  rm -rf "${tmp}" "${dir}"
  chmod +x "${BIN_DIR}/ko"
}

install_kind() {
  local url="https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-${OS}-${ARCH_KIND}"
  echo "[install] kind ${KIND_VERSION} from ${url}"
  download "${url}" "${BIN_DIR}/kind"
  chmod +x "${BIN_DIR}/kind"
}

ensure_gitignore_bin() {
  local gi="${ROOT_DIR}/.gitignore"
  if ! grep -qx 'bin/' "${gi}" 2>/dev/null; then
    echo "[update] append 'bin/' to .gitignore"
    echo 'bin/' >> "${gi}"
  else
    echo "[skip] .gitignore already contains 'bin/'"
  fi
}

install_tilt
install_ko
install_kind
ensure_gitignore_bin

echo "[done] local tools installed in ${BIN_DIR}"
echo "Run: export PATH=\"${BIN_DIR}:\$PATH\""
echo "Verify: tilt version && ko version && kind --version"
