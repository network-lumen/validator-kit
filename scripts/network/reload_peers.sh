#!/usr/bin/env bash
set -euo pipefail

############################################################
# Lumen — Reload persistent_peers from config/peers.txt
#
# Reads the repo source-of-truth (config/peers.txt), rewrites
# the local node's config.toml persistent_peers line, and can
# optionally restart the lumend systemd service.
#
# Useful when you edit peers.txt (or pull it from Git) and
# want the running node to pick up the new list.
############################################################

usage() {
  cat <<EOF
Usage: $(basename "$0") [--home DIR] [--service NAME] [--no-restart]

Options:
  --home      Node home directory (default: \$HOME/.lumen).
  --service   systemd service name to restart (default: lumend).
  --no-restart
              Do not offer to restart the systemd service.
  -h, --help  Show this help and exit.
EOF
}

HOME_DIR="$HOME/.lumen"
SERVICE_NAME="lumend"
RESTART=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --home)
      [[ $# -ge 2 ]] || { echo "Missing value for --home"; usage; exit 1; }
      HOME_DIR="$2"
      shift
      ;;
    --service)
      [[ $# -ge 2 ]] || { echo "Missing value for --service"; usage; exit 1; }
      SERVICE_NAME="$2"
      shift
      ;;
    --no-restart)
      RESTART=0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
  shift
done

# -----------------------------------------------------------------------------
# Resolve paths
# -----------------------------------------------------------------------------

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PEERS_FILE="$REPO_ROOT/config/peers.txt"
CFG_TOML="$HOME_DIR/config/config.toml"

if [[ ! -f "$PEERS_FILE" ]]; then
  echo "❌ Missing peers file: $PEERS_FILE"
  exit 1
fi

if [[ ! -f "$CFG_TOML" ]]; then
  echo "❌ Local config.toml not found at $CFG_TOML"
  exit 1
fi

RAW="$(head -n1 "$PEERS_FILE" | tr -d '\r\n ')"
PEERS="$RAW"

printf '%s\n' "Reloading persistent_peers from $PEERS_FILE"
echo "  → \"$PEERS\""

sed -i "s|^persistent_peers *=.*|persistent_peers = \"$PEERS\"|" "$CFG_TOML"
echo "✔ Updated $CFG_TOML"

# -----------------------------------------------------------------------------
# Optionally restart systemd service
# -----------------------------------------------------------------------------

if [[ "$RESTART" -eq 1 ]] && command -v systemctl >/dev/null 2>&1; then
  if systemctl list-unit-files | grep -q "^${SERVICE_NAME}.service"; then
    read -rp "Restart systemd service '${SERVICE_NAME}' now? [Y/n] " ANSWER
    ANSWER="${ANSWER:-Y}"
    if [[ "$ANSWER" =~ ^[Yy]$ ]]; then
      if sudo systemctl restart "$SERVICE_NAME"; then
        echo "✔ Restarted ${SERVICE_NAME}.service"
      else
        echo "⚠ Failed to restart ${SERVICE_NAME}.service (run manually)"
      fi
    else
      echo "ℹ Skipping restart."
    fi
  else
    echo "ℹ systemd service '${SERVICE_NAME}.service' not found (skipping restart)"
  fi
fi

echo "Done. Current persistent_peers in $CFG_TOML:"
grep -E '^persistent_peers' "$CFG_TOML" || true

