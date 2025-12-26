#!/usr/bin/env bash
set -euo pipefail

###############################################
# Lumen — Export validator backup + snapshot
#
# This script bundles:
# - the validator bootstrap backup (first-node.bak)
# - the latest chain snapshot (if available)
# into a single tar.gz archive that you can copy
# off the server for disaster recovery.
#
# Usage:
#   deploy/scripts/network/export_backup.sh [HOME_DIR] [SNAP_DIR] [OUT_DIR]
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
HOME_DIR="${1:-${DEFAULT_HOME}/.lumen}"
SNAP_DIR="${2:-${DEFAULT_HOME}/snapshots}"
OUT_DIR="${3:-${DEFAULT_HOME}/exports}"

BACKUP_DIR="$HOME_DIR/first-node.bak"

echo "HOME_DIR  = $HOME_DIR"
echo "SNAP_DIR  = $SNAP_DIR"
echo "OUT_DIR   = $OUT_DIR"
echo

if [[ ! -d "$BACKUP_DIR" ]]; then
  echo "❌ Validator backup not found at $BACKUP_DIR"
  echo "Run bootstrap.sh first on this host."
  exit 1
fi

SNAPSHOT=""
if [[ -d "$SNAP_DIR" ]]; then
  SNAPSHOT="$(find "$SNAP_DIR" -maxdepth 1 -type f -name 'block_*.tar.gz' | sort | tail -n1 || true)"
fi

mkdir -p "$OUT_DIR"
TS="$(date +%Y%m%d_%H%M%S)"
ARCHIVE="$OUT_DIR/lumen_validator_backup_$TS.tar.gz"

TMP_DIR="$(mktemp -d)"
mkdir -p "$TMP_DIR/backup"

echo "→ Copying validator backup..."
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
rm -rf "$TMP_DIR"

echo
echo "✅ Done."
echo "Archive ready to copy off-host:"
echo "  $ARCHIVE"
