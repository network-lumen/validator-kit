#!/usr/bin/env bash
set -euo pipefail

###############################################################################
#  CONFIG
###############################################################################
FROM="${FROM:-validator}"
HOME_DIR="${HOME_DIR:-$HOME/.lumen}"
BIN="${BIN:-lumend}"
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
    out=$("$BIN" q tx "$hash" --node "$RPC" 2>/dev/null || true)
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
FROM_ADDR=$("$BIN" keys show "$FROM" -a --home "$HOME_DIR" --keyring-backend "$KEYRING")
VALOPER=$("$BIN" keys show "$FROM" --bech val -a --home "$HOME_DIR" --keyring-backend "$KEYRING")

info "Account:  $FROM_ADDR"
info "Valoper:  $VALOPER"

###############################################################################
#  VALIDATOR / PQC GUARDS
###############################################################################
step "Checking validator status and PQC link"

if ! "$BIN" q staking validator "$VALOPER" --node "$RPC" >/devnull 2>&1; then
  error "This address is not a validator on-chain. Run become_validator first."
fi

if ! "$BIN" q pqc account "$FROM_ADDR" --node "$RPC" >/dev/null 2>&1; then
  error "PQC account is not linked on-chain for $FROM_ADDR. Validator setup is incomplete."
fi

PQC_KEY="validator-pqc"
if ! "$BIN" keys pqc-show "$PQC_KEY" --home "$HOME_DIR" --keyring-backend "$KEYRING" >/dev/null 2>&1; then
  error "PQC key '$PQC_KEY' not found in $HOME_DIR (keyring=$KEYRING); run become_validator on this host first."
fi

###############################################################################
#  DELEGATION
###############################################################################
step "Delegating $AMOUNT"

DELEG=$("$BIN" tx staking delegate "$VALOPER" "$AMOUNT" \
  --from "$FROM" \
  --home "$HOME_DIR" \
  --keyring-backend "$KEYRING" \
  --chain-id "$CHAIN_ID" \
  --node "$RPC" \
  --pqc-from "$FROM_ADDR" \
  --pqc-key "$PQC_KEY" \
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
