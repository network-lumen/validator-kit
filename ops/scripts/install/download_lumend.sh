#!/usr/bin/env bash
set -euo pipefail

# download_lumend.sh
# -------------------
# Small helper to fetch a lumend binary from the official GitHub releases
# and place it under deploy/bin/lumend (or another target you provide).
#
# Usage:
#   ./scripts/install/download_lumend.sh
#   LUMEN_RELEASE_URL=... ./scripts/install/download_lumend.sh
#   LUMEN_TARGET=./bin/lumend ./scripts/install/download_lumend.sh
#
# Defaults:
#   - RELEASE_TAG: v1.4.0
#   - linux/amd64 tarball URL:
#       https://github.com/network-lumen/blockchain/releases/download/v1.4.0/linux-amd64-v1.4.0.tar.gz
#   - TARGET: deploy/bin/lumend (relative to repo root)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
BIN_DIR="${REPO_ROOT}/bin"
mkdir -p "${BIN_DIR}"

RELEASE_TAG="${LUMEN_RELEASE_TAG:-v1.4.0}"
DEFAULT_URL="https://github.com/network-lumen/blockchain/releases/download/${RELEASE_TAG}/linux-amd64-${RELEASE_TAG}.tar.gz"
RELEASE_URL="${LUMEN_RELEASE_URL:-$DEFAULT_URL}"
TARGET="${LUMEN_TARGET:-${BIN_DIR}/lumend}"

echo "==> lumen binary downloader"
echo "Release tag : ${RELEASE_TAG}"
echo "Source URL  : ${RELEASE_URL}"
echo "Target path : ${TARGET}"

if [[ -x "${TARGET}" ]]; then
  echo "Target ${TARGET} already exists and is executable."
  read -r -p "Overwrite existing binary? [y/N]: " ANSWER
  ANSWER="${ANSWER:-N}"
  if [[ ! "${ANSWER}" =~ ^[Yy]$ ]]; then
    echo "Aborting without changes."
    exit 0
  fi
fi

TMP_DIR="$(mktemp -d)"
ARCHIVE="${TMP_DIR}/lumend.tar.gz"

cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

echo "-> Downloading archive..."
if ! curl -fL "${RELEASE_URL}" -o "${ARCHIVE}"; then
  echo "ERROR: failed to download from ${RELEASE_URL}" >&2
  exit 1
fi

echo "-> Extracting lumend from archive..."
tar -C "${TMP_DIR}" -xzf "${ARCHIVE}"

CANDIDATE=""
if [[ -f "${TMP_DIR}/lumend" ]]; then
  CANDIDATE="${TMP_DIR}/lumend"
else
  # Some archives ship the binary under a platform-specific name
  # (e.g. linux-amd64-v1.4.0). Prefer any executable that looks
  # like a lumend binary, otherwise fall back to the first executable.
  CANDIDATE="$(find "${TMP_DIR}" -maxdepth 2 -type f -perm -u+x \( -name 'lumend' -o -name '*lumend*' \) -print -quit || true)"
  if [[ -z "${CANDIDATE}" ]]; then
    CANDIDATE="$(find "${TMP_DIR}" -maxdepth 2 -type f -perm -u+x -print -quit || true)"
  fi
fi

if [[ -z "${CANDIDATE}" ]]; then
  echo "ERROR: could not locate 'lumend' inside the archive." >&2
  exit 1
fi

echo "-> Installing to ${TARGET}"
cp "${CANDIDATE}" "${TARGET}"
chmod +x "${TARGET}"

echo "Done. You can now point scripts and services to:"
echo "  ${TARGET}"
