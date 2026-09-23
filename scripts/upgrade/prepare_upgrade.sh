#!/usr/bin/env bash
set -euo pipefail
umask 077

usage() {
  cat <<'EOF'
Usage: ./scripts/upgrade/prepare_upgrade.sh --name NAME --version VERSION [options]

Prepare a verified Lumen binary for Cosmovisor. This command never stops or
restarts the node and never changes blockchain or validator signing state.

Options:
  --name NAME       Cosmovisor upgrade name.
  --version VERSION Requested Lumen release version.
  --home DIR        Node home (default: $LUMEN_HOME or $HOME/.lumen).
EOF
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DOWNLOADER="$REPO_ROOT/scripts/install/download_lumend.sh"
HOME_DIR="$HOME/.lumen"
[[ -v LUMEN_HOME ]] && HOME_DIR="$LUMEN_HOME"
NAME=""
VERSION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) [[ $# -ge 2 ]] || { echo "ERROR: --name requires a value." >&2; exit 2; }; NAME="$2"; shift 2 ;;
    --version) [[ $# -ge 2 ]] || { echo "ERROR: --version requires a value." >&2; exit 2; }; VERSION="$2"; shift 2 ;;
    --home) [[ $# -ge 2 ]] || { echo "ERROR: --home requires a value." >&2; exit 2; }; HOME_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown option '$1'." >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$NAME" && "$NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] ||
  { echo "ERROR: upgrade name must be 1-64 characters of letters, digits, '.', '_' or '-'." >&2; exit 2; }
[[ "$NAME" != "." && "$NAME" != ".." ]] || { echo "ERROR: invalid upgrade name." >&2; exit 2; }
[[ -n "$VERSION" && "$VERSION" =~ ^v?[0-9]+([.][0-9]+){1,3}([_-][[:alnum:].-]+)?$ ]] ||
  { echo "ERROR: invalid Lumen version '$VERSION'." >&2; exit 2; }
[[ -d "$HOME_DIR" ]] || { echo "ERROR: node home not found: $HOME_DIR" >&2; exit 1; }
[[ -x "$DOWNLOADER" ]] || { echo "ERROR: downloader not found: $DOWNLOADER" >&2; exit 1; }

COSMOVISOR_DIR="$HOME_DIR/cosmovisor"
UPGRADES_DIR="$COSMOVISOR_DIR/upgrades"
UPGRADE_ROOT="$UPGRADES_DIR/$NAME"
TARGET="$UPGRADE_ROOT/bin/lumend"
if [[ -e "$UPGRADE_ROOT" || -L "$UPGRADE_ROOT" ]]; then
  if [[ -x "$TARGET" ]]; then
    version_home="$(mktemp -d)"
    existing_version="$(HOME="$version_home" XDG_CONFIG_HOME="$version_home/.config" XDG_DATA_HOME="$version_home/.local/share" XDG_CACHE_HOME="$version_home/.cache" "$TARGET" version 2>&1 || true)"
    rm -rf -- "$version_home"
    requested_version="${VERSION#v}"
    if [[ "$existing_version" == *"v$requested_version"* || "$existing_version" == *" $requested_version"* ]]; then
      echo "Upgrade already prepared: $UPGRADE_ROOT"
      exit 0
    fi
    echo "ERROR: upgrade directory exists with a different binary version: $UPGRADE_ROOT" >&2
    exit 1
  fi
  echo "ERROR: incomplete upgrade directory already exists: $UPGRADE_ROOT" >&2
  exit 1
fi

STAGE_ROOT=""
cleanup() {
  [[ -n "$STAGE_ROOT" && -d "$STAGE_ROOT" ]] && rm -rf -- "$STAGE_ROOT"
  return 0
}
trap cleanup EXIT

mkdir -p "$UPGRADES_DIR"
STAGE_ROOT="$(mktemp -d "$UPGRADES_DIR/.prepare-$NAME.XXXXXX")"
STAGE_TARGET="$STAGE_ROOT/bin/lumend"
echo "Preparing upgrade '$NAME' with Lumen $VERSION"
LUMEN_RELEASE_TAG="$VERSION" LUMEN_TARGET="$STAGE_TARGET" "$DOWNLOADER"

[[ -x "$STAGE_TARGET" ]] || { echo "ERROR: verified binary was not installed." >&2; exit 1; }
if [[ "$EUID" -eq 0 ]]; then
  chown --reference="$HOME_DIR" -R "$STAGE_ROOT"
fi
chmod 0755 "$STAGE_TARGET"
mv -- "$STAGE_ROOT" "$UPGRADE_ROOT"
STAGE_ROOT=""
echo "READY: $TARGET"
echo "No service or node process was stopped."
