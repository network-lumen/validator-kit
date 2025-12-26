#!/usr/bin/env bash
set -euo pipefail

############################################################
# Lumen — Enable state sync on a node
#
# This helper:
#  - discovers the latest height from a trusted RPC server
#  - picks a trust height (latest - N, configurable)
#  - fetches the corresponding block hash
#  - writes the [statesync] section in config.toml
#
# It assumes the node has no local state yet (LastBlockHeight = 0),
# i.e. you should run it after `join.sh` and *before* the first
# full sync, or after deleting $HOME/data.
############################################################

usage() {
  cat <<EOF
Usage: $(basename "$0") [--home DIR] [--rpc URL[,URL2]] [--last N] [--trust-period DUR]

Options:
  --home DIR        Node home directory (default: \$HOME/.lumen).
  --rpc URLS        Comma-separated RPC servers to trust for state sync
                    (e.g. "http://100.64.0.1:26657").
  --last N          How many blocks behind the latest height to trust
                    (default: 100).
  --trust-period D  Trust period for light client (default: 168h0m0s).
  -h, --help        Show this help and exit.
EOF
}

HOME_DIR="$HOME/.lumen"
RPC_SERVERS=""
LAST=100
TRUST_PERIOD="168h0m0s"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --home)
      [[ $# -ge 2 ]] || { echo "Missing value for --home"; usage; exit 1; }
      HOME_DIR="$2"
      shift
      ;;
    --rpc)
      [[ $# -ge 2 ]] || { echo "Missing value for --rpc"; usage; exit 1; }
      RPC_SERVERS="$2"
      shift
      ;;
    --last)
      [[ $# -ge 2 ]] || { echo "Missing value for --last"; usage; exit 1; }
      LAST="$2"
      shift
      ;;
    --trust-period)
      [[ $# -ge 2 ]] || { echo "Missing value for --trust-period"; usage; exit 1; }
      TRUST_PERIOD="$2"
      shift
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

CFG_TOML="$HOME_DIR/config/config.toml"

if [[ ! -f "$CFG_TOML" ]]; then
  echo "❌ config.toml not found at $CFG_TOML"
  exit 1
fi

if [[ -d "$HOME_DIR/data" && -n "$(ls -A "$HOME_DIR/data" 2>/dev/null || true)" ]]; then
  echo "⚠ WARNING: $HOME_DIR/data is not empty."
  echo "State sync is only attempted when the node has no local state (LastBlockHeight = 0)."
  echo "Consider stopping the node and removing '$HOME_DIR/data' before using this helper."
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "❌ curl is required (install it with your package manager)."
  exit 1
fi

if command -v jq >/dev/null 2>&1; then
  JQ_BIN="$(command -v jq)"
else
  echo "❌ jq is required (e.g. 'sudo apt install jq')."
  exit 1
fi

if [[ -z "$RPC_SERVERS" ]]; then
  echo "No RPC provided, skipping state sync. Bootstrap will rely on seeds + PEX."
  exit 0
fi

# CometBFT requires at least 2 RPC servers for the light client.
# In small private setups it's acceptable to repeat the same URL twice.
if [[ "$RPC_SERVERS" != *,* ]]; then
  RPC_SERVERS="$RPC_SERVERS,$RPC_SERVERS"
fi

# Use the first RPC as the source for height/hash discovery
PRIMARY_RPC="${RPC_SERVERS%%,*}"

echo "→ Querying latest height from $PRIMARY_RPC ..."
LATEST_RAW="$(curl -fsS "$PRIMARY_RPC/status")" || { echo "❌ Failed to query /status from $PRIMARY_RPC"; exit 1; }
LATEST_HEIGHT="$("$JQ_BIN" -r '.result.sync_info.latest_block_height // "0"' <<<"$LATEST_RAW")"

if [[ -z "$LATEST_HEIGHT" || "$LATEST_HEIGHT" == "0" ]]; then
  echo "❌ Got latest_block_height = 0 from $PRIMARY_RPC; is the node running and synced?"
  exit 1
fi

echo "Current latest height: $LATEST_HEIGHT"
read -rp "Blocks to go back from latest height (trust window) [$LAST]: " INPUT_LAST
if [[ -n "$INPUT_LAST" ]]; then
  LAST="$INPUT_LAST"
fi

if ! [[ "$LAST" =~ ^[0-9]+$ ]]; then
  echo "❌ Invalid --last value: $LAST"
  exit 1
fi

TRUST_HEIGHT=$((LATEST_HEIGHT - LAST))
if (( TRUST_HEIGHT <= 0 )); then
  TRUST_HEIGHT=1
fi

echo "→ Using trust_height = $TRUST_HEIGHT"

COMMIT_RAW="$(curl -fsS "$PRIMARY_RPC/commit?height=$TRUST_HEIGHT")" || { echo "❌ Failed to query /commit at height $TRUST_HEIGHT"; exit 1; }
TRUST_HASH="$("$JQ_BIN" -r '.result.signed_header.commit.block_id.hash // ""' <<<"$COMMIT_RAW")"

if [[ -z "$TRUST_HASH" || "$TRUST_HASH" == "null" ]]; then
  echo "❌ Could not extract trust_hash from /commit response."
  exit 1
fi

echo "→ trust_hash = $TRUST_HASH"

echo "Updating [statesync] section in $CFG_TOML ..."

sed -i "s|^\[statesync\]|[statesync]|" "$CFG_TOML"
sed -i "s|^enable *=.*|enable = true|" "$CFG_TOML"
sed -i "s|^rpc_servers *=.*|rpc_servers = \"$RPC_SERVERS\"|" "$CFG_TOML"
sed -i "s|^trust_height *=.*|trust_height = $TRUST_HEIGHT|" "$CFG_TOML"
sed -i "s|^trust_hash *=.*|trust_hash = \"$TRUST_HASH\"|" "$CFG_TOML"
sed -i "s|^trust_period *=.*|trust_period = \"$TRUST_PERIOD\"|" "$CFG_TOML"

echo "✔ State sync configuration written to $CFG_TOML"
echo
echo "Summary:"
echo "  enable       = true"
echo "  rpc_servers  = $RPC_SERVERS"
echo "  trust_height = $TRUST_HEIGHT"
echo "  trust_hash   = $TRUST_HASH"
echo "  trust_period = $TRUST_PERIOD"
echo
echo "Next steps:"
echo "  - Ensure '$HOME_DIR/data' is empty (no previous state)."
echo "  - Start the node (systemd or 'lumend start')."
echo "  - On first startup, it should perform state sync instead of replaying all blocks."
