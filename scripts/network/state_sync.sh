#!/usr/bin/env bash
set -euo pipefail

############################################################
# Lumen - Enable state sync on a node after validating its RPC source(s).
#
# State-sync configuration is written only after every supplied RPC passes
# chain, health, height, and trust-hash validation.
############################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--home DIR] [--rpc URL[,URL2]] [--last N] [--trust-period DUR]

Options:
  --home DIR        Node home directory (default: \$HOME/.lumen).
  --rpc URLS        One or two comma-separated RPC servers.
                    A single URL is intentionally written twice for CometBFT.
  --last N          How many blocks behind latest to trust (default: 100).
  --trust-period D  Trust period for the light client (default: 168h0m0s).
  -h, --help        Show this help and exit.
EOF
}

HOME_DIR="$HOME/.lumen"
RPC_INPUT=""
LAST=100
TRUST_PERIOD="168h0m0s"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --home)
      [[ $# -ge 2 ]] || { echo "ERROR: missing value for --home." >&2; usage; exit 1; }
      HOME_DIR="$2"
      shift
      ;;
    --rpc)
      [[ $# -ge 2 ]] || { echo "ERROR: missing value for --rpc." >&2; usage; exit 1; }
      RPC_INPUT="$2"
      shift
      ;;
    --last)
      [[ $# -ge 2 ]] || { echo "ERROR: missing value for --last." >&2; usage; exit 1; }
      LAST="$2"
      shift
      ;;
    --trust-period)
      [[ $# -ge 2 ]] || { echo "ERROR: missing value for --trust-period." >&2; usage; exit 1; }
      TRUST_PERIOD="$2"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
  shift
done

CFG_TOML="$HOME_DIR/config/config.toml"
GENESIS_JSON="$HOME_DIR/config/genesis.json"
if [[ ! -f "$CFG_TOML" ]]; then
  echo "ERROR: config.toml not found at $CFG_TOML." >&2
  exit 1
fi
if [[ ! -f "$GENESIS_JSON" ]]; then
  GENESIS_JSON="$REPO_ROOT/networks/mainnet/genesis.json"
fi
if [[ ! -f "$GENESIS_JSON" ]]; then
  echo "ERROR: cannot determine expected chain ID; genesis.json is missing." >&2
  exit 1
fi

for required_command in awk curl jq mktemp mv rm uname; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    echo "ERROR: required command '$required_command' is unavailable." >&2
    exit 1
  fi
done

if [[ -z "$RPC_INPUT" ]]; then
  echo "No RPC provided, skipping state sync. Bootstrap will rely on seeds and PEX."
  exit 0
fi

if ! [[ "$LAST" =~ ^[0-9]+$ ]]; then
  echo "ERROR: invalid --last value '$LAST'; expected a non-negative integer." >&2
  exit 1
fi

EXPECTED_CHAIN_ID="$(jq -er '.chain_id // empty' "$GENESIS_JSON")" || {
  echo "ERROR: could not read expected chain ID from $GENESIS_JSON." >&2
  exit 1
}
if [[ -z "$EXPECTED_CHAIN_ID" ]]; then
  echo "ERROR: expected chain ID is empty in $GENESIS_JSON." >&2
  exit 1
fi

IFS=',' read -r -a RPCS <<< "$RPC_INPUT"
if (( ${#RPCS[@]} < 1 || ${#RPCS[@]} > 2 )); then
  echo "ERROR: provide one or two comma-separated RPC endpoints." >&2
  exit 1
fi
for i in "${!RPCS[@]}"; do
  RPCS[$i]="${RPCS[$i]%/}"
  if [[ -z "${RPCS[$i]}" ]]; then
    echo "ERROR: RPC endpoint $((i + 1)) is empty." >&2
    exit 1
  fi
done

RPC1="${RPCS[0]}"
RPC_MODE="single endpoint"
if (( ${#RPCS[@]} == 1 )); then
  RPC2="$RPC1"
else
  RPC2="${RPCS[1]}"
  RPC_MODE="dual endpoint"
fi

if [[ -d "$HOME_DIR/data" && -n "$(ls -A "$HOME_DIR/data" 2>/dev/null || true)" ]]; then
  echo "WARNING: $HOME_DIR/data is not empty. State sync requires no local state (LastBlockHeight = 0)."
  echo "Stop the node and clear or move its data only after reviewing the recovery implications."
fi

toml_statesync_value() {
  local key="$1"
  awk -v wanted="$key" '
    /^\[/ { in_statesync = ($0 == "[statesync]"); next }
    in_statesync && $0 ~ "^[[:space:]]*" wanted "[[:space:]]*=" {
      sub("^[[:space:]]*" wanted "[[:space:]]*=[[:space:]]*", "")
      print
      exit
    }
  ' "$CFG_TOML"
}

EXISTING_ENABLE="$(toml_statesync_value enable || true)"
EXISTING_RPC="$(toml_statesync_value rpc_servers || true)"
EXISTING_TRUST_HEIGHT="$(toml_statesync_value trust_height || true)"
EXISTING_TRUST_HASH="$(toml_statesync_value trust_hash || true)"
if [[ -n "$EXISTING_RPC$EXISTING_TRUST_HEIGHT$EXISTING_TRUST_HASH" || "$EXISTING_ENABLE" == "true" ]]; then
  echo "Existing state-sync configuration:"
  echo "  enable       = ${EXISTING_ENABLE:-<unset>}"
  echo "  rpc_servers  = ${EXISTING_RPC:-<unset>}"
  echo "  trust_height = ${EXISTING_TRUST_HEIGHT:-<unset>}"
  echo "  trust_hash   = ${EXISTING_TRUST_HASH:-<unset>}"
  read -r -p "Replace these state-sync values after validation? [y/N]: " REPLACE_EXISTING
  if [[ ! "${REPLACE_EXISTING:-N}" =~ ^[Yy]$ ]]; then
    echo "Aborting without changes."
    exit 0
  fi
fi

query_status() {
  local rpc="$1"
  local raw
  if ! raw="$(curl --fail --silent --show-error --location "$rpc/status")"; then
    echo "ERROR: RPC endpoint '$rpc' did not return /status successfully." >&2
    return 1
  fi
  if ! jq -e '.result.node_info.network and .result.sync_info.latest_block_height and (.result.sync_info.catching_up | type == "boolean")' >/dev/null <<< "$raw"; then
    echo "ERROR: RPC endpoint '$rpc' returned incomplete or malformed /status JSON." >&2
    return 1
  fi

  local chain_id latest catching_up
  chain_id="$(jq -r '.result.node_info.network' <<< "$raw")"
  latest="$(jq -r '.result.sync_info.latest_block_height' <<< "$raw")"
  catching_up="$(jq -r '.result.sync_info.catching_up' <<< "$raw")"
  if [[ "$chain_id" != "$EXPECTED_CHAIN_ID" ]]; then
    echo "ERROR: RPC endpoint '$rpc' belongs to chain '$chain_id', expected '$EXPECTED_CHAIN_ID'." >&2
    return 1
  fi
  if [[ "$catching_up" != "false" ]]; then
    echo "ERROR: RPC endpoint '$rpc' is still catching up and cannot be used as a trusted state-sync source." >&2
    return 1
  fi
  if ! [[ "$latest" =~ ^[0-9]+$ ]] || (( latest <= 0 )); then
    echo "ERROR: RPC endpoint '$rpc' reported invalid latest block height '$latest'." >&2
    return 1
  fi
  printf '%s\n' "$latest"
}

echo "Lumen state sync configuration"
echo
echo "Expected chain: $EXPECTED_CHAIN_ID"
echo "RPC mode:       $RPC_MODE"
echo "RPC 1:          $RPC1"
if [[ "$RPC_MODE" == "single endpoint" ]]; then
  echo "RPC 2:          same as RPC 1 (CometBFT compatibility, not redundancy)"
else
  echo "RPC 2:          $RPC2"
fi

LATEST_HEIGHT="$(query_status "$RPC1")" || exit 1
SECOND_LATEST_HEIGHT="$(query_status "$RPC2")" || exit 1

if [[ -t 0 ]]; then
  read -r -p "Blocks to go back from latest height (trust window) [$LAST]: " INPUT_LAST
  if [[ -n "$INPUT_LAST" ]]; then
    LAST="$INPUT_LAST"
  fi
  if ! [[ "$LAST" =~ ^[0-9]+$ ]]; then
    echo "ERROR: invalid trust offset '$LAST'; expected a non-negative integer." >&2
    exit 1
  fi
fi

if (( LATEST_HEIGHT <= LAST )); then
  echo "ERROR: latest height $LATEST_HEIGHT is not greater than trust offset $LAST." >&2
  exit 1
fi
TRUST_HEIGHT=$((LATEST_HEIGHT - LAST))
if (( TRUST_HEIGHT <= 0 )); then
  echo "ERROR: calculated trust height $TRUST_HEIGHT is invalid." >&2
  exit 1
fi

query_trust_hash() {
  local rpc="$1"
  local raw returned_height hash
  if ! raw="$(curl --fail --silent --show-error --location "$rpc/commit?height=$TRUST_HEIGHT")"; then
    echo "ERROR: RPC endpoint '$rpc' could not return block $TRUST_HEIGHT." >&2
    return 1
  fi
  if ! jq -e '.result.signed_header.header.height and .result.signed_header.commit.block_id.hash' >/dev/null <<< "$raw"; then
    echo "ERROR: RPC endpoint '$rpc' returned no usable commit for height $TRUST_HEIGHT." >&2
    return 1
  fi
  returned_height="$(jq -r '.result.signed_header.header.height' <<< "$raw")"
  hash="$(jq -r '.result.signed_header.commit.block_id.hash' <<< "$raw")"
  if [[ "$returned_height" != "$TRUST_HEIGHT" ]]; then
    echo "ERROR: RPC endpoint '$rpc' returned height '$returned_height', expected '$TRUST_HEIGHT'." >&2
    return 1
  fi
  if ! [[ "$hash" =~ ^[[:xdigit:]]{64}$ ]]; then
    echo "ERROR: RPC endpoint '$rpc' returned malformed trust hash for height $TRUST_HEIGHT." >&2
    return 1
  fi
  printf '%s\n' "$hash"
}

TRUST_HASH="$(query_trust_hash "$RPC1")" || exit 1
SECOND_TRUST_HASH="$(query_trust_hash "$RPC2")" || exit 1
if [[ "$TRUST_HASH" != "$SECOND_TRUST_HASH" ]]; then
  echo "ERROR: RPC endpoints returned different trust hashes at height $TRUST_HEIGHT." >&2
  exit 1
fi

RPC_SERVERS="$RPC1,$RPC2"
TMP_CFG="$(mktemp "${CFG_TOML}.tmp.XXXXXX")"
cleanup() {
  rm -f "$TMP_CFG"
}
trap cleanup EXIT

if ! awk -v rpc_servers="$RPC_SERVERS" -v trust_height="$TRUST_HEIGHT" -v trust_hash="$TRUST_HASH" -v trust_period="$TRUST_PERIOD" '
  BEGIN { in_statesync = 0; found_section = 0; seen_enable = 0; seen_rpc = 0; seen_height = 0; seen_hash = 0; seen_period = 0 }
  /^\[/ {
    if ($0 == "[statesync]") { in_statesync = 1; found_section = 1 }
    else { in_statesync = 0 }
    print
    next
  }
  in_statesync && $0 ~ /^[[:space:]]*enable[[:space:]]*=/ { print "enable = true"; seen_enable = 1; next }
  in_statesync && $0 ~ /^[[:space:]]*rpc_servers[[:space:]]*=/ { print "rpc_servers = \"" rpc_servers "\""; seen_rpc = 1; next }
  in_statesync && $0 ~ /^[[:space:]]*trust_height[[:space:]]*=/ { print "trust_height = " trust_height; seen_height = 1; next }
  in_statesync && $0 ~ /^[[:space:]]*trust_hash[[:space:]]*=/ { print "trust_hash = \"" trust_hash "\""; seen_hash = 1; next }
  in_statesync && $0 ~ /^[[:space:]]*trust_period[[:space:]]*=/ { print "trust_period = \"" trust_period "\""; seen_period = 1; next }
  { print }
  END {
    if (!found_section || !seen_enable || !seen_rpc || !seen_height || !seen_hash || !seen_period) exit 1
  }
' "$CFG_TOML" > "$TMP_CFG"; then
  echo "ERROR: failed to update the [statesync] section in $CFG_TOML." >&2
  exit 1
fi

mv "$TMP_CFG" "$CFG_TOML"
trap - EXIT

echo
echo "Latest height:  $LATEST_HEIGHT"
echo "Trust offset:   $LAST"
echo "Trust height:   $TRUST_HEIGHT"
echo "Trust hash:     $TRUST_HASH"
echo "Chain IDs:      verified"
echo "Trust hashes:   verified"
echo "State sync:     enabled"
echo "Configuration:  $CFG_TOML"
echo
echo "Next steps:"
echo "  - Ensure '$HOME_DIR/data' is empty (no previous state)."
echo "  - Start the node with systemd or 'lumend start'."
