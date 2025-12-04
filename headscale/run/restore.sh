#!/usr/bin/env bash
set -euo pipefail

# Restore a Headscale state snapshot created by run/backup.sh.
#
# Usage (from deploy/headscale):
#   ./run/restore.sh /path/to/headscale_state_YYYYMMDD_HHMMSS.tar.gz
#
# This will:
#   - stop the headscale service
#   - wipe the existing data in the headscale-data volume
#   - restore the contents of the archive into that volume
#   - start headscale again

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HEADSCALE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$HEADSCALE_DIR"

if [[ $# -lt 1 ]]; then
  echo "Usage: restore.sh /path/to/headscale_state_*.tar.gz"
  exit 1
fi

ARCHIVE="$1"
if [[ ! -f "$ARCHIVE" ]]; then
  echo "Archive not found: $ARCHIVE"
  exit 1
fi

if docker compose version >/dev/null 2>&1; then
  COMPOSE_CMD=(docker compose)
elif docker-compose version >/dev/null 2>&1; then
  COMPOSE_CMD=(docker-compose)
else
  echo "docker compose / docker-compose not found in PATH"
  exit 1
fi

PROJECT_NAME="${COMPOSE_PROJECT_NAME:-headscale}"
VOLUME_NAME="${PROJECT_NAME}_headscale-data"

echo "=== Headscale restore ==="
echo "Project  : $PROJECT_NAME"
echo "Volume   : $VOLUME_NAME"
echo "Archive  : $ARCHIVE"
echo

echo "[1/4] Stopping headscale stack..."
"${COMPOSE_CMD[@]}" down headscale >/dev/null 2>&1 || true

echo "[2/4] Ensuring volume exists..."
docker volume create "$VOLUME_NAME" >/dev/null 2>&1 || true

ARCHIVE_DIR="$(cd "$(dirname "$ARCHIVE")" && pwd)"
ARCHIVE_BASENAME="$(basename "$ARCHIVE")"

echo "[3/4] Restoring snapshot into volume..."
docker run --rm \
  -v "${VOLUME_NAME}:/data" \
  -v "${ARCHIVE_DIR}:/backup" \
  busybox sh -c "rm -rf /data/* && cd /data && tar xzf /backup/${ARCHIVE_BASENAME}"

echo "[4/4] Starting headscale..."
"${COMPOSE_CMD[@]}" up -d headscale

echo
echo "✅ Restore complete. Headscale is running with the restored state."

