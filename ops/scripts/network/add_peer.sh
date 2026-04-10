#!/usr/bin/env bash
set -euo pipefail

############################################################
# Lumen — Append a persistent peer to the config
#
# This helper keeps the repo's source-of-truth in sync
# (`config/peers.txt`) and, if a local node home exists,
# updates `$HOME/.lumen/config/config.toml` accordingly.
#
# You can either pass the peer on the CLI:
#   add_peer.sh --peer "nodeid@100.64.0.1:26656"
# or let the script prompt you interactively.
############################################################

usage() {
  cat <<EOF
Usage: $(basename "$0") [--peer <id@host:port>] [--home DIR] [--service NAME] [--no-restart]

Options:
  --peer      CometBFT peer string, e.g. "abcd1234@100.64.0.1:26656".
              If omitted, you will be prompted interactively.
  --home      Node home directory (default: \$HOME/.lumen).
  --service   systemd service name to restart (default: lumend).
  --no-restart
              Do not offer to restart the systemd service.
  -h, --help  Show this help and exit.
EOF
}

PEER=""
HOME_DIR="$HOME/.lumen"
SERVICE_NAME="lumend"
RESTART=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --peer)
      [[ $# -ge 2 ]] || { echo "Missing value for --peer"; usage; exit 1; }
      PEER="$2"
      shift
      ;;
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
# Resolve repo paths
# -----------------------------------------------------------------------------

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PEERS_FILE="$REPO_ROOT/config/peers.txt"

mkdir -p "$(dirname "$PEERS_FILE")"

normalize_peer_list() {
  local file="$1"
  awk '
    BEGIN { list = "" }
    {
      gsub(/\r/, "")
      gsub(/,/, "\n", $0)
      n = split($0, parts, /\n/)
      for (i = 1; i <= n; i++) {
        entry = parts[i]
        gsub(/^[ \t]+|[ \t]+$/, "", entry)
        if (entry != "") {
          if (list == "") { list = entry }
          else { list = list "," entry }
        }
      }
    }
    END { print list }
  ' "$file"
}

# -----------------------------------------------------------------------------
# Peer input
# -----------------------------------------------------------------------------

if [[ -z "$PEER" ]]; then
  read -rp "CometBFT peer (id@host:port): " PEER
fi

# Trim whitespace / newlines
PEER="$(echo -n "$PEER" | tr -d '[:space:]')"

if [[ "$PEER" != *@*:* ]]; then
  echo "❌ Invalid peer format. Expected id@host:port"
  exit 1
fi

# -----------------------------------------------------------------------------
# Load existing peers from config/peers.txt and normalize both multiline
# and comma-delimited formats into one CSV string.
# -----------------------------------------------------------------------------

EXISTING=""
if [[ -f "$PEERS_FILE" ]]; then
  EXISTING="$(normalize_peer_list "$PEERS_FILE")"
fi

if [[ -n "$EXISTING" ]]; then
  # Normalise to a comma-delimited list with no spaces
  EXISTING="$(echo -n "$EXISTING" | tr -d ' ')"
fi

NEW="$EXISTING"

if [[ -z "$EXISTING" ]]; then
  NEW="$PEER"
elif [[ ",$EXISTING," == *",$PEER,"* ]]; then
  echo "Peer already present in $PEERS_FILE"
else
  NEW="$EXISTING,$PEER"
fi

printf '%s\n' "$NEW" >"$PEERS_FILE"
echo "✔ Updated $PEERS_FILE"
echo "   persistent_peers = \"$NEW\""

# -----------------------------------------------------------------------------
# Update local node config, if present (non-seed only)
# -----------------------------------------------------------------------------

CFG_TOML="$HOME_DIR/config/config.toml"
IS_SEED_MODE=0
if [[ -f "$CFG_TOML" ]] && grep -Eq '^[[:space:]]*seed_mode[[:space:]]*=[[:space:]]*true' "$CFG_TOML"; then
  IS_SEED_MODE=1
fi

if [[ -f "$CFG_TOML" ]]; then
  if [[ "$IS_SEED_MODE" -eq 1 ]]; then
    echo "Seed node detected: peers.txt updated, local config untouched"
  else
    # Use sed to replace the persistent_peers line
    sed -i "s|^persistent_peers *=.*|persistent_peers = \"$NEW\"|" "$CFG_TOML"
    echo "✔ Updated $CFG_TOML"

    # Also ensure max_num_inbound_peers is at least the number of peers.
    # This is mainly relevant on the validator, where defaults may be 0.
    PEER_COUNT=0
    IFS=',' read -r -a PEER_ARR <<<"$NEW"
    for _ in "${PEER_ARR[@]}"; do
      if [[ -n "${_}" ]]; then
        PEER_COUNT=$((PEER_COUNT + 1))
      fi
    done

    if grep -q '^max_num_inbound_peers' "$CFG_TOML"; then
      CURRENT_INBOUND=$(grep '^max_num_inbound_peers' "$CFG_TOML" | sed 's/[^0-9]//g' || echo "0")
      if [[ -z "$CURRENT_INBOUND" ]]; then
        CURRENT_INBOUND=0
      fi
      if (( PEER_COUNT > 0 && CURRENT_INBOUND < PEER_COUNT )); then
        sed -i "s|^max_num_inbound_peers *=.*|max_num_inbound_peers = $PEER_COUNT|" "$CFG_TOML"
        echo "✔ Bumped max_num_inbound_peers to $PEER_COUNT in $CFG_TOML"
      fi
    fi
  fi
else
  echo "ℹ No local config at $CFG_TOML (skipping node home update)"
fi

# -----------------------------------------------------------------------------
# Optionally restart systemd service (non-seed only)
# -----------------------------------------------------------------------------

if [[ "$RESTART" -eq 1 && "$IS_SEED_MODE" -ne 1 ]] && command -v systemctl >/dev/null 2>&1; then
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

echo "Done. Current peers string:"
echo "  $NEW"
