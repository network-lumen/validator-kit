#!/usr/bin/env bash
set -euo pipefail
umask 077

# Pinned to an upstream Cosmovisor release. Never replace this with @latest.
COSMOVISOR_VERSION="v1.7.3"
TARGET="/usr/local/bin/cosmovisor"

usage() {
  cat <<EOF
Usage: sudo ./scripts/install/install_cosmovisor.sh [--target PATH]

Reuse an existing Cosmovisor when available. Otherwise install the pinned
release ${COSMOVISOR_VERSION} with Go, verify it, and place it at PATH
(default: ${TARGET}).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      [[ $# -ge 2 ]] || { echo "ERROR: --target requires a path." >&2; exit 2; }
      TARGET="$2"
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown option '$1'." >&2; usage >&2; exit 2 ;;
  esac
done

EXISTING_PATH="$(command -v cosmovisor 2>/dev/null || true)"
if [[ -n "$EXISTING_PATH" ]]; then
  EXISTING_PATH="$(realpath -- "$EXISTING_PATH")"
  [[ -x "$EXISTING_PATH" ]] || {
    echo "ERROR: resolved Cosmovisor is not executable: $EXISTING_PATH" >&2
    exit 1
  }
  EXISTING_VERSION="$($EXISTING_PATH version 2>&1 || true)"
  [[ -n "$EXISTING_VERSION" ]] || {
    echo "ERROR: existing Cosmovisor could not execute: $EXISTING_PATH" >&2
    exit 1
  }
  echo "→ Found existing Cosmovisor"
  echo "→ Cosmovisor: $EXISTING_PATH"
  echo "→ Version: ${EXISTING_VERSION//$'\n'/ }"
  echo "→ Reusing existing installation"
  printf 'COSMOVISOR_PATH=%s\n' "$EXISTING_PATH"
  exit 0
fi

if [[ "$EUID" -ne 0 ]]; then
  echo "ERROR: Cosmovisor installation requires root privileges for the target path." >&2
  exit 1
fi
command -v go >/dev/null 2>&1 || {
  echo "ERROR: Go is required to install Cosmovisor ${COSMOVISOR_VERSION}." >&2
  exit 1
}
command -v install >/dev/null 2>&1 || { echo "ERROR: install command is unavailable." >&2; exit 1; }

TARGET_DIR="$(dirname "$TARGET")"
mkdir -p "$TARGET_DIR"
if [[ -e "$TARGET" ]]; then
  [[ -x "$TARGET" ]] || { echo "ERROR: existing Cosmovisor path is not executable: $TARGET" >&2; exit 1; }
  EXISTING_VERSION="$($TARGET version 2>&1 || true)"
  VERSION_NO_V="${COSMOVISOR_VERSION#v}"
  VERSION_PATTERN="(^|[^[:alnum:]])v?${VERSION_NO_V//./\.}([^[:alnum:]]|$)"
  if [[ "$EXISTING_VERSION" =~ $VERSION_PATTERN ]]; then
    echo "Cosmovisor ${COSMOVISOR_VERSION} already installed: $TARGET"
    exit 0
  fi
  echo "ERROR: existing Cosmovisor version does not match ${COSMOVISOR_VERSION}: $TARGET" >&2
  echo "       Reported: ${EXISTING_VERSION//$'\n'/ }" >&2
  exit 1
fi

BUILD_DIR="$(mktemp -d)"
cleanup() { rm -rf -- "$BUILD_DIR"; }
trap cleanup EXIT
mkdir -p "$BUILD_DIR/bin"

echo "Installing Cosmovisor ${COSMOVISOR_VERSION} from cosmossdk.io/tools/cosmovisor"
GOTOOLCHAIN=local GOBIN="$BUILD_DIR/bin" \
  go install "cosmossdk.io/tools/cosmovisor/cmd/cosmovisor@${COSMOVISOR_VERSION}"

CANDIDATE="$BUILD_DIR/bin/cosmovisor"
[[ -x "$CANDIDATE" ]] || { echo "ERROR: Go installation did not produce cosmovisor." >&2; exit 1; }
VERSION_OUTPUT="$("$CANDIDATE" version 2>&1 || true)"
VERSION_NO_V="${COSMOVISOR_VERSION#v}"
VERSION_PATTERN="(^|[^[:alnum:]])v?${VERSION_NO_V//./\.}([^[:alnum:]]|$)"
if [[ ! "$VERSION_OUTPUT" =~ $VERSION_PATTERN ]]; then
  echo "ERROR: installed Cosmovisor version does not match ${COSMOVISOR_VERSION}." >&2
  echo "       Reported: ${VERSION_OUTPUT//$'\n'/ }" >&2
  exit 1
fi

install -m 0755 "$CANDIDATE" "$TARGET"
echo "Cosmovisor installed: $TARGET (${VERSION_OUTPUT//$'\n'/ })"
printf 'COSMOVISOR_PATH=%s\n' "$TARGET"
