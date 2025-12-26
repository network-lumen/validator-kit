#!/usr/bin/env bash
set -euo pipefail

# Headscale state snapshot (for backups / migration)
# --------------------------------------------------
# This script creates a tar.gz archive of the Headscale
# data volume (SQLite DB, keys, cache) that you can copy
# off-host (USB key, offline backup, etc.).
#
# Usage (from deploy/headscale):
#   ./run/backup.sh                 # saves into ./backups/
#   ./run/backup.sh /path/to/dir    # custom target directory
#
# The archive name will be:
#   headscale_state_YYYYMMDD_HHMMSS.tar.gz

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HEADSCALE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$HEADSCALE_DIR"

if docker compose version >/dev/null 2>&1; then
  COMPOSE_CMD=(docker compose)
elif docker-compose version >/dev/null 2>&1; then
  COMPOSE_CMD=(docker-compose)
else
  echo "docker compose / docker-compose not found in PATH"
  exit 1
fi

TARGET_DIR="${1:-$HEADSCALE_DIR/backups}"
mkdir -p "$TARGET_DIR"

PROJECT_NAME="${COMPOSE_PROJECT_NAME:-headscale}"
VOLUME_NAME="${PROJECT_NAME}_headscale-data"

TS="$(date +%Y%m%d_%H%M%S)"
ARCHIVE="$TARGET_DIR/headscale_state_${TS}.tar.gz"

echo "=== Headscale backup ==="
echo "Project       : $PROJECT_NAME"
echo "Volume        : $VOLUME_NAME"
echo "Target folder : $TARGET_DIR"
echo "Archive       : $ARCHIVE"
echo

echo "[1/3] Stopping headscale container (for clean SQLite state)..."
"${COMPOSE_CMD[@]}" stop headscale >/dev/null 2>&1 || true

echo "[2/3] Creating snapshot from volume..."
docker run --rm \
  -v "${VOLUME_NAME}:/data" \
  -v "${TARGET_DIR}:/backup" \
  busybox sh -c "cd /data && tar czf /backup/$(basename "$ARCHIVE") ."

echo "[3/3] Restarting headscale (if it was up)..."
"${COMPOSE_CMD[@]}" start headscale >/dev/null 2>&1 || true

echo
echo "✅ Backup complete."
echo "Snapshot archived at:"
echo "  $ARCHIVE"

