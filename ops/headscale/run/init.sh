#!/usr/bin/env bash
set -euo pipefail

# Initialise Headscale for Lumen:
# - ensure a user/namespace exists (default: lumen)
# - create one pre-auth key for the validator
# - create N pre-auth keys for sentry nodes
#
# Usage:
#   ./run/init.sh                  # user=lumen, 1 sentry
#   ./run/init.sh --sentries 3     # user=lumen, 3 sentries
#   ./run/init.sh --user mynet --sentries 2
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HEADSCALE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HEADSCALE_CONTAINER="${HEADSCALE_CONTAINER:-headscale}"

USER_NAME="lumen"
SENTRY_COUNT=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)
      USER_NAME="$2"
      shift 2
      ;;
    --sentries)
      SENTRY_COUNT="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: init.sh [--user NAME] [--sentries N]"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: init.sh [--user NAME] [--sentries N]"
      exit 1
      ;;
  esac
done

if ! docker ps --format '{{.Names}}' | grep -qx "$HEADSCALE_CONTAINER"; then
  echo "Headscale container '$HEADSCALE_CONTAINER' is not running."
  echo "Start it first with:"
  echo "  cd \"$HEADSCALE_DIR\" && ./run/up.sh"
  exit 1
fi

echo "=== Headscale init ==="
echo "User/namespace : $USER_NAME"
echo "Sentry keys    : $SENTRY_COUNT"
echo

echo "[1/3] Ensuring user '$USER_NAME' exists"
if ! OUTPUT="$(docker exec "$HEADSCALE_CONTAINER" headscale users create "$USER_NAME" 2>&1)"; then
  if echo "$OUTPUT" | grep -qi "already exists"; then
    echo "User '$USER_NAME' already exists, continuing."
  else
    echo "$OUTPUT"
    exit 1
  fi
else
  echo "$OUTPUT"
fi

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
KEYS_FILE="$HEADSCALE_DIR/headscale_keys_${USER_NAME}_${TIMESTAMP}.txt"

echo "[2/3] Creating pre-auth key for validator"
VAL_KEY="$(docker exec "$HEADSCALE_CONTAINER" headscale preauthkeys create --user "$USER_NAME" --expiration 24h | tail -n1)"

{
  echo "# Headscale auth keys for user '$USER_NAME' ($TIMESTAMP)"
  echo "validator=$VAL_KEY"
} >"$KEYS_FILE"

echo "[3/3] Creating pre-auth keys for sentry nodes"
for i in $(seq 1 "$SENTRY_COUNT"); do
  KEY="$(docker exec "$HEADSCALE_CONTAINER" headscale preauthkeys create --user "$USER_NAME" --expiration 24h | tail -n1)"
  echo "sentry${i}=$KEY" >>"$KEYS_FILE"
done

echo
echo "Done."
echo "Keys written to:"
echo "  $KEYS_FILE"
echo
echo "Example usage on a node with Tailscale client installed:"
echo "  sudo tailscale up --login-server http://127.0.0.1:8080 --authkey <one-of-the-keys>"
