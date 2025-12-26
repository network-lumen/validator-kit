#!/usr/bin/env bash
set -euo pipefail

HOME_DIR="${HOME_DIR:-/root/.lumen}"
BIN="${BIN:-/usr/local/bin/lumend}"
KEYRING="${KEYRING:-test}"
CHAIN_ID="${CHAIN_ID:-lumen}"
RPC="${RPC:-http://127.0.0.1:26657}"
FEES="${FEES:-0ulmn}"
GAS_ADJ="${GAS_ADJ:-1.5}"

MONIKER=""
AMOUNT=""
FROM="${FROM:-validator}"

step() { echo -e "\033[36m[step]\033[0m $*"; }
info() { echo -e "\033[32m[info]\033[0m $*"; }
error() { echo -e "\033[31m[error]\033[0m $*" >&2; exit 1; }

# ------------------------- ARGS -------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --moniker) MONIKER="$2"; shift 2;;
    --amount) AMOUNT="$2"; shift 2;;
    *) error "Unknown arg: $1";;
  esac
done

[ -n "$MONIKER" ] || error "Missing: --moniker"
[ -n "$AMOUNT" ] || error "Missing: --amount"

FROM_ADDR=$($BIN keys show "$FROM" -a --keyring-backend "$KEYRING" --home "$HOME_DIR")
VALOPER=$($BIN keys show "$FROM" --bech val -a --keyring-backend "$KEYRING" --home "$HOME_DIR")

info "Account : $FROM_ADDR"
info "Valoper : $VALOPER"

# ------------------------- PQC DETECTION -------------------------

PQC_NAME="validator-pqc"

step "Checking PQC key"
if ! $BIN keys pqc-show "$PQC_NAME" >/dev/null 2>&1; then
    error "PQC key '$PQC_NAME' not found"
fi

PUB_HEX=$($BIN keys pqc-show "$PQC_NAME" | grep "PubKey (hex)" | sed 's/.*: *//')
[ -n "$PUB_HEX" ] || error "Unable to extract PQC pubkey"
info "PQC pubkey OK"

# ------------------------- PQC LINK-ACCOUNT ON-CHAIN -------------------------
step "Checking on-chain PQC link"

if $BIN q pqc account "$FROM_ADDR" --node "$RPC" >/dev/null 2>&1; then
    info "PQC already linked on-chain"
else
    info "Linking PQC on-chain..."

    LINK_RES=$($BIN tx pqc link-account \
      --from "$FROM" \
      --pubkey "$PUB_HEX" \
      --scheme dilithium3 \
      --chain-id "$CHAIN_ID" \
      --home "$HOME_DIR" \
      --keyring-backend "$KEYRING" \
      --node "$RPC" \
      --yes --fees "$FEES" \
      --broadcast-mode sync \
      -o json)

    LINK_HASH=$(echo "$LINK_RES" | jq -r '.txhash // empty')
    [ -n "$LINK_HASH" ] || error "Failed to extract PQC link tx hash"

    CODE=$(echo "$LINK_RES" | jq -r '.code // 0')
    [ "$CODE" = "0" ] || error "PQC link-account failed: code=$CODE"

    info "PQC linked successfully (Tx: $LINK_HASH)"
fi

# ------------------------- REAL CONSENSUS PUBKEY -------------------------
REAL_PUBKEY=$($BIN tendermint show-validator --home "$HOME_DIR")
info "Consensus pubkey OK"

# ------------------------- BUILD validator.json -------------------------
TMP_JSON=$(mktemp)
cat > "$TMP_JSON" <<EOF
{
  "pubkey": $REAL_PUBKEY,
  "amount": "$AMOUNT",
  "moniker": "$MONIKER",
  "identity": "",
  "website": "",
  "security": "",
  "details": "",
  "commission-rate": "0.1",
  "commission-max-rate": "0.2",
  "commission-max-change-rate": "0.01",
  "min-self-delegation": "1"
}
EOF

info "validator.json built"

# ------------------------- CREATE VALIDATOR -------------------------
step "Broadcasting create-validator"

RES=$($BIN tx staking create-validator "$TMP_JSON" \
    --from "$FROM" \
    --chain-id "$CHAIN_ID" \
    --keyring-backend "$KEYRING" \
    --home "$HOME_DIR" \
    --gas auto \
    --gas-adjustment "$GAS_ADJ" \
    --yes \
    --fees "$FEES" \
    --broadcast-mode sync \
    -o json)

echo "$RES"

CODE=$(echo "$RES" | jq -r '.code // 0')
[ "$CODE" = "0" ] || error "create-validator failed: code=$CODE"

HASH=$(echo "$RES" | jq -r '.txhash // empty')

info "SUCCESS - Validator created!"
info "Tx: $HASH"