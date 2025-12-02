#!/usr/bin/env bash
set -euo pipefail

###############################################################################
#  CONFIG
###############################################################################
FROM="${FROM:-validator}"
HOME_DIR="${HOME_DIR:-$HOME/.lumen}"
KEYRING="${KEYRING:-test}"
CHAIN_ID="${CHAIN_ID:-lumen}"
RPC="${RPC:-http://127.0.0.1:26657}"
FEES="${FEES:-0ulmn}"

AMOUNT=""

step() { echo -e "\033[36m[step]\033[0m $*"; }
info() { echo -e "\033[32m[info]\033[0m $*"; }
error() { echo -e "\033[31m[error]\033[0m $*" >&2; exit 1; }

###############################################################################
#  TX WAIT FUNCTION
###############################################################################
wait_tx() {
  local hash="$1"
  for _ in $(seq 1 60); do
    local out
    out=$(lumend q tx "$hash" --node "$RPC" 2>/dev/null || true)
    local code
    code=$(echo "$out" | awk '/code:/ {print $2; exit}')
    if [ -n "$code" ]; then
      echo "$code"
      return 0
    fi
    sleep 1
  done
  return 1
}

###############################################################################
#  ARG PARSING
###############################################################################
while [ $# -gt 0 ]; do
  case "$1" in
    --amount) AMOUNT="$2"; shift 2;;
    *) error "Unknown arg: $1";;
  esac
done

[ -n "$AMOUNT" ] || error "Usage: ./stake_tokens.sh --amount <NUMulmn>"

###############################################################################
#  ADDRESSES
###############################################################################
FROM_ADDR=$(lumend keys show "$FROM" -a --home "$HOME_DIR" --keyring-backend "$KEYRING")
VALOPER=$(lumend keys show "$FROM" --bech val -a --home "$HOME_DIR" --keyring-backend "$KEYRING")

info "Account:  $FROM_ADDR"
info "Valoper:  $VALOPER"

###############################################################################
#  PQC KEY CHECK
###############################################################################
step "Checking PQC key"
PQC_KEY="validator-pqc"

if ! lumend keys pqc-show "$PQC_KEY" >/dev/null 2>&1; then
    error "PQC key '$PQC_KEY' not found — cannot continue"
fi

info "Using PQC key: $PQC_KEY"

###############################################################################
#  EXTRACT PQC PUBKEY
###############################################################################
PUB=$(lumend keys pqc-show "$PQC_KEY" \
      | grep "PubKey (hex)" \
      | sed 's/.*PubKey (hex): *//')

[ -n "$PUB" ] || error "Failed to extract PQC pubkey"

info "PQC pubkey length: $(echo -n "$PUB" | wc -c)"

###############################################################################
#  CHECK / LINK PQC ACCOUNT
###############################################################################
step "Checking on-chain PQC link"

if lumend q pqc account "$FROM_ADDR" --node "$RPC" >/dev/null 2>&1; then
    info "PQC already linked on-chain"
else
    step "Linking PQC account..."

    LINK=$(lumend tx pqc link-account \
      --from "$FROM" \
      --pubkey "$PUB" \
      --scheme dilithium3 \
      --chain-id "$CHAIN_ID" \
      --home "$HOME_DIR" \
      --keyring-backend "$KEYRING" \
      --node "$RPC" \
      --gas 250000 \
      --fees "$FEES" \
      --yes \
      -o json)

    LINK_HASH=$(echo "$LINK" | jq -r '.txhash // empty')
    [ -n "$LINK_HASH" ] || error "Failed to extract txhash from link-account response"

    step "Waiting for PQC link tx commit..."
    CODE=$(wait_tx "$LINK_HASH") || error "Timeout waiting for PQC link tx"
    [ "$CODE" = "0" ] || error "PQC link-account failed with code=$CODE"

    info "PQC link-account OK"
fi

###############################################################################
#  DELEGATION
###############################################################################
step "Delegating $AMOUNT"

DELEG=$(lumend tx staking delegate "$VALOPER" "$AMOUNT" \
  --from "$FROM" \
  --home "$HOME_DIR" \
  --keyring-backend "$KEYRING" \
  --chain-id "$CHAIN_ID" \
  --node "$RPC" \
  --fees "$FEES" \
  --gas auto \
  --gas-adjustment 1.5 \
  --yes \
  --broadcast-mode sync \
  -o json)

HASH=$(echo "$DELEG" | jq -r '.txhash // empty')
[ -n "$HASH" ] || error "Failed to extract txhash from delegate response"

step "Waiting for delegate tx commit..."
DCODE=$(wait_tx "$HASH") || error "Timeout waiting for delegate tx"
if [ "$DCODE" != "0" ]; then
  error "Delegate transaction failed with code=$DCODE (tx=$HASH)"
fi

info "Delegated $AMOUNT from $FROM_ADDR to $VALOPER (tx=$HASH)"