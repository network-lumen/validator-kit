#!/usr/bin/env bash
set -euo pipefail
umask 077

###############################################
# Lumen — Export validator backup + snapshot
#
# This script bundles:
# - the validator backup (first-node.bak or validator-node.bak)
# - the latest chain snapshot (if available)
# into a single tar.gz archive that you can copy
# off the server for disaster recovery.
# The archive uses the stable path backup/first-node.bak even when the source
# directory is validator-node.bak, preserving the existing export format.
#
# Usage:
#   ./scripts/network/export_backup.sh [HOME_DIR] [SNAP_DIR] [OUT_DIR]
#
# Run it as the same user that owns the node home, or pass an explicit
# HOME_DIR/SNAP_DIR/OUT_DIR if you run it with sudo.
#
# Defaults (based on the current $HOME):
#   HOME_DIR = $HOME/.lumen
#   SNAP_DIR = $HOME/snapshots
#   OUT_DIR  = $HOME/exports
###############################################

DEFAULT_HOME="${HOME:-/root}"
HOME_DIR="${1:-${LUMEN_HOME:-${DEFAULT_HOME}/.lumen}}"
OPERATOR_HOME="$(dirname -- "$HOME_DIR")"
SNAP_DIR="${2:-${LUMEN_SNAPSHOT_DIR:-${OPERATOR_HOME}/snapshots}}"
OUT_DIR="${3:-${LUMEN_BACKUP_DIR:-${OPERATOR_HOME}/exports}}"

BACKUP_DIR=""
for candidate in "$HOME_DIR/first-node.bak" "$HOME_DIR/validator-node.bak"; do
  if [[ -d "$candidate" ]]; then
    BACKUP_DIR="$candidate"
    break
  fi
done

echo "HOME_DIR  = $HOME_DIR"
echo "SNAP_DIR  = $SNAP_DIR"
echo "OUT_DIR   = $OUT_DIR"
echo

if [[ -z "$BACKUP_DIR" ]]; then
  echo "❌ Validator backup not found under $HOME_DIR"
  echo "Expected first-node.bak or validator-node.bak."
  exit 1
fi

SNAPSHOT=""
if [[ -d "$SNAP_DIR" ]]; then
  SNAPSHOT="$(find "$SNAP_DIR" -maxdepth 1 -type f -name 'block_*.tar.gz' | sort | tail -n1 || true)"
fi

mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"
TS="$(date +%Y%m%d_%H%M%S)"
ARCHIVE="$OUT_DIR/lumen_validator_backup_$TS.tar.gz"

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT
mkdir -p "$TMP_DIR/backup"

echo "→ Copying validator backup..."
# Keep the archive path stable so restore procedures do not depend on which
# workflow created the source backup.
cp -r "$BACKUP_DIR" "$TMP_DIR/backup/first-node.bak"

if [[ -n "$SNAPSHOT" ]]; then
  echo "→ Including latest snapshot: $(basename "$SNAPSHOT")"
  mkdir -p "$TMP_DIR/backup/snapshots"
  cp "$SNAPSHOT" "$TMP_DIR/backup/snapshots/"
else
  echo "ℹ No snapshots found in $SNAP_DIR (continuing without snapshot)."
fi

echo "→ Creating archive: $ARCHIVE"
tar -czf "$ARCHIVE" -C "$TMP_DIR" backup
chmod 600 "$ARCHIVE"

echo
echo "✅ Done."
echo "Archive ready to copy off-host:"
echo "  $ARCHIVE"
echo "Archive contains sensitive account/PQC and validator key material; store it securely."
