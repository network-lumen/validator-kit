#!/usr/bin/env bash
set -euo pipefail

# Download and verify an official Lumen release binary.
#
# Usage:
#   ./scripts/install/download_lumend.sh
#   LUMEN_RELEASE_TAG=v1.6.0 ./scripts/install/download_lumend.sh
#   LUMEN_TARGET=/usr/local/bin/lumend sudo -E ./scripts/install/download_lumend.sh
#
# LUMEN_RELEASE_URL is an exact archive URL override. When it is set,
# LUMEN_CHECKSUM_URL must also point to the authoritative SHA256SUMS file.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

RELEASE_TAG="${LUMEN_RELEASE_TAG:-v1.4.3}"
TARGET="${LUMEN_TARGET:-${REPO_ROOT}/bin/lumend}"
PLATFORM_OS="$(uname -s)"
PLATFORM_ARCH="$(uname -m)"

case "$PLATFORM_OS" in
  Linux) ;;
  *)
    echo "ERROR: unsupported operating system '$PLATFORM_OS'; only Linux is supported." >&2
    exit 1
    ;;
esac

case "$PLATFORM_ARCH" in
  x86_64) RELEASE_ARCH="amd64" ;;
  aarch64) RELEASE_ARCH="arm64" ;;
  *)
    echo "ERROR: unsupported architecture '$PLATFORM_ARCH'; supported Linux architectures are x86_64 and aarch64." >&2
    exit 1
    ;;
esac

for required_command in awk chmod cp curl mktemp mv rm sha256sum tar uname; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    echo "ERROR: required command '$required_command' is not available." >&2
    exit 1
  fi
done

ARCHIVE_NAME="linux-${RELEASE_ARCH}-${RELEASE_TAG}.tar.gz"
BINARY_NAME="linux-${RELEASE_ARCH}-${RELEASE_TAG}"
DEFAULT_BASE_URL="https://github.com/network-lumen/blockchain/releases/download/${RELEASE_TAG}"
DEFAULT_RELEASE_URL="${DEFAULT_BASE_URL}/${ARCHIVE_NAME}"

if [[ -n "${LUMEN_RELEASE_URL:-}" ]]; then
  RELEASE_URL="$LUMEN_RELEASE_URL"
  if [[ -z "${LUMEN_CHECKSUM_URL:-}" ]]; then
    echo "ERROR: LUMEN_RELEASE_URL is an exact archive override and requires LUMEN_CHECKSUM_URL." >&2
    exit 1
  fi
  CHECKSUM_URL="$LUMEN_CHECKSUM_URL"
else
  RELEASE_URL="$DEFAULT_RELEASE_URL"
  CHECKSUM_URL="${LUMEN_CHECKSUM_URL:-${DEFAULT_BASE_URL}/SHA256SUMS}"
fi

run_isolated_version() {
  local binary="$1"
  local isolated_home
  local status

  isolated_home="$(mktemp -d)"
  if (
    export HOME="$isolated_home"
    export XDG_CONFIG_HOME="$isolated_home/.config"
    export XDG_DATA_HOME="$isolated_home/.local/share"
    export XDG_CACHE_HOME="$isolated_home/.cache"
    "$binary" version
  ); then
    status=0
  else
    status=$?
  fi
  rm -rf -- "$isolated_home"
  return "$status"
}

TARGET_DIR="$(dirname "$TARGET")"
if [[ -e "$TARGET" ]]; then
  EXISTING_VERSION="unavailable"
  if [[ -x "$TARGET" ]]; then
    EXISTING_VERSION="$(run_isolated_version "$TARGET" 2>&1 || true)"
    EXISTING_VERSION="${EXISTING_VERSION//$'\n'/ }"
  fi
  echo "Existing binary: $TARGET"
  echo "Existing version: $EXISTING_VERSION"
  echo "Requested release: $RELEASE_TAG"
  read -r -p "Overwrite existing binary after verification? [y/N]: " ANSWER
  ANSWER="${ANSWER:-N}"
  if [[ ! "$ANSWER" =~ ^[Yy]$ ]]; then
    echo "Aborting without changes."
    exit 0
  fi
fi

echo "Lumen binary installation"
echo
echo "Release:  $RELEASE_TAG"
echo "Platform: linux/$RELEASE_ARCH"
echo "Archive:  $ARCHIVE_NAME"

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

ARCHIVE_PATH="$TMP_DIR/$ARCHIVE_NAME"
CHECKSUMS_PATH="$TMP_DIR/SHA256SUMS"

echo "-> Downloading archive..."
if ! curl --fail --location --silent --show-error "$RELEASE_URL" -o "$ARCHIVE_PATH"; then
  echo "ERROR: failed to download release archive." >&2
  exit 1
fi

echo "-> Downloading checksum manifest..."
if ! curl --fail --location --silent --show-error "$CHECKSUM_URL" -o "$CHECKSUMS_PATH"; then
  echo "ERROR: failed to download checksum manifest." >&2
  exit 1
fi

EXPECTED_SHA256="$(awk -v archive="$ARCHIVE_NAME" '
  $2 == archive || $2 == "*" archive {
    if (found) exit 2
    print $1
    found = 1
  }
  END {
    if (!found) exit 3
  }
' "$CHECKSUMS_PATH")" || {
  echo "ERROR: checksum entry for '$ARCHIVE_NAME' is missing or ambiguous." >&2
  exit 1
}

if [[ ! "$EXPECTED_SHA256" =~ ^[[:xdigit:]]{64}$ ]]; then
  echo "ERROR: checksum entry for '$ARCHIVE_NAME' is malformed." >&2
  exit 1
fi

if ! printf '%s  %s\n' "$EXPECTED_SHA256" "$ARCHIVE_NAME" | (
  cd "$TMP_DIR"
  sha256sum --check --status -
); then
  echo "ERROR: SHA256 checksum verification failed for '$ARCHIVE_NAME'." >&2
  exit 1
fi
echo "Checksum: verified"

echo "-> Extracting expected binary..."
if ! tar -xzf "$ARCHIVE_PATH" -C "$TMP_DIR" -- "$BINARY_NAME"; then
  echo "ERROR: archive does not contain expected binary '$BINARY_NAME'." >&2
  exit 1
fi

CANDIDATE="$TMP_DIR/$BINARY_NAME"
if [[ ! -f "$CANDIDATE" || ! -x "$CANDIDATE" ]]; then
  echo "ERROR: expected binary '$BINARY_NAME' is missing or not executable." >&2
  exit 1
fi

VERSION_OUTPUT="$(run_isolated_version "$CANDIDATE" 2>&1)" || {
  echo "ERROR: extracted binary failed to report its version." >&2
  exit 1
}
VERSION_NO_V="${RELEASE_TAG#v}"
VERSION_PATTERN="(^|[^[:alnum:]])v?${VERSION_NO_V//./\.}([^[:alnum:]]|$)"
if [[ ! "$VERSION_OUTPUT" =~ $VERSION_PATTERN ]]; then
  echo "ERROR: extracted binary version does not match release '$RELEASE_TAG'." >&2
  echo "       Reported: ${VERSION_OUTPUT//$'\n'/ }" >&2
  exit 1
fi
REPORTED_VERSION="${VERSION_OUTPUT//$'\n'/ }"
echo "Version:   $REPORTED_VERSION"

if [[ ! -d "$TARGET_DIR" ]]; then
  mkdir -p "$TARGET_DIR"
fi
if [[ ! -w "$TARGET_DIR" ]]; then
  echo "ERROR: destination directory '$TARGET_DIR' is not writable." >&2
  exit 1
fi

STAGED_TARGET="$(mktemp "${TARGET}.tmp.XXXXXX")"
cleanup_staged() {
  rm -f "$STAGED_TARGET"
}
trap 'cleanup_staged; cleanup' EXIT

cp "$CANDIDATE" "$STAGED_TARGET"
chmod 0755 "$STAGED_TARGET"
mv -f "$STAGED_TARGET" "$TARGET"

echo "Binary:    $BINARY_NAME"
echo "Installed: $TARGET"
echo
echo "Binary installation complete."
