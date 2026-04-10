#!/usr/bin/env bash
set -euo pipefail

############################################################
# Lumen — Remove a persistent peer from the config
#
# This helper edits the repo's source-of-truth
# (`config/peers.txt`) and, if a local node home exists,
# updates `$HOME/.lumen/config/config.toml` accordingly.
#
# You can either pass the peer on the CLI:
#   remove_peer.sh --peer "nodeid@100.64.0.1:26656"
# or let the script show the current list and pick one.
############################################################

usage() {
  cat <<EOF
Usage: $(basename "$0") [--peer <id@host:port>] [--home DIR] [--service NAME] [--no-restart]

Options:
  --peer      CometBFT peer string, e.g. "abcd1234@100.64.0.1:26656".
              If omitted, you will be prompted to select from the current list.
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

if [[ ! -f "$PEERS_FILE" ]]; then
  echo "❌ No peers file at $PEERS_FILE"
  exit 1
fi

RAW="$(normalize_peer_list "$PEERS_FILE")"

if [[ -z "$RAW" ]]; then
  echo "ℹ peers.txt is empty, nothing to remove."
  exit 0
fi

IFS=',' read -r -a PEERS_ARR <<<"$RAW"

if [[ "${#PEERS_ARR[@]}" -eq 0 ]]; then
  echo "ℹ No peers found in $PEERS_FILE."
  exit 0
fi

# -----------------------------------------------------------------------------
# Interactive selection if no --peer
# -----------------------------------------------------------------------------

if [[ -z "$PEER" ]]; then
  echo "Current peers:"
  for i in "${!PEERS_ARR[@]}"; do
    printf "  [%d] %s\n" "$((i+1))" "${PEERS_ARR[$i]}"
  done
  echo
  read -rp "Select index to remove: " IDX
  if ! [[ "$IDX" =~ ^[0-9]+$ ]] || (( IDX < 1 || IDX > ${#PEERS_ARR[@]} )); then
    echo "❌ Invalid index"
    exit 1
  fi
  PEER="${PEERS_ARR[$((IDX-1))]}"
else
  PEER="$(echo -n "$PEER" | tr -d '[:space:]')"
fi

# -----------------------------------------------------------------------------
# Build new list without the peer
# -----------------------------------------------------------------------------

NEW_LIST=()
FOUND=0
for p in "${PEERS_ARR[@]}"; do
  if [[ "$p" == "$PEER" ]]; then
    FOUND=1
    continue
  fi
  NEW_LIST+=("$p")
done

if [[ "$FOUND" -eq 0 ]]; then
  echo "ℹ Peer not found in $PEERS_FILE: $PEER"
  exit 0
fi

NEW_JOINED=""
if [[ "${#NEW_LIST[@]}" -gt 0 ]]; then
  NEW_JOINED="${NEW_LIST[*]}"
  # Replace spaces between elements with commas
  NEW_JOINED="${NEW_JOINED// /,}"
fi

printf '%s\n' "$NEW_JOINED" >"$PEERS_FILE"
echo "✔ Updated $PEERS_FILE"
echo "   persistent_peers = \"${NEW_JOINED}\""

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
    sed -i "s|^persistent_peers *=.*|persistent_peers = \"${NEW_JOINED}\"|" "$CFG_TOML"
    echo "✔ Updated $CFG_TOML"
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
echo "  ${NEW_JOINED}"
