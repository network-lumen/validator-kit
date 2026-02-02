#!/usr/bin/env bash
set -euo pipefail

HOME_DIR="${HOME_DIR:-$HOME/.lumen}"
BIN="${BIN:-lumend}"
KEYRING="${KEYRING:-test}"
CHAIN_ID="${CHAIN_ID:-lumen-testnet-1}"
RPC="${RPC:-http://127.0.0.1:26657}"
FEES="${FEES:-0ulmn}"
GAS_ADJ="${GAS_ADJ:-1.5}"
BACKUP_DIR_DEFAULT="${BACKUP_DIR_DEFAULT:-validator-node.bak}"

MONIKER=""
FROM="${FROM:-validator}"
SELF_DELEGATION="1ulmn"

step() { echo -e "\033[36m[step]\033[0m $*"; }
info() { echo -e "\033[32m[info]\033[0m $*"; }
error() { echo -e "\033[31m[error]\033[0m $*" >&2; exit 1; }

wait_tx() {
  local hash="$1"
  local tries=60
  local out code
  for _ in $(seq 1 "$tries"); do
    out=$($BIN q tx "$hash" --node "$RPC" -o json 2>/dev/null || true)
    code=$(echo "$out" | jq -r '.code // empty')
    if [[ -n "$code" ]]; then
      echo "$code"
      return 0
    fi
    sleep 1
  done
  return 1
}

# ------------------------- ARGS -------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --moniker) MONIKER="$2"; shift 2;;
    *) error "Unknown arg: $1";;
  esac
done

[ -n "$MONIKER" ] || error "Missing: --moniker"

info "Using minimal self-delegation for create-validator: $SELF_DELEGATION"

FROM_ADDR=$($BIN keys show "$FROM" -a --keyring-backend "$KEYRING" --home "$HOME_DIR")
VALOPER=$($BIN keys show "$FROM" --bech val -a --keyring-backend "$KEYRING" --home "$HOME_DIR")

info "Account : $FROM_ADDR"
info "Valoper : $VALOPER"
info "Home    : $HOME_DIR"

# Basic balance guard: require some funds before proceeding.
BALANCE_ULMN="$($BIN q bank balances "$FROM_ADDR" --node "$RPC" -o json 2>/dev/null \
  | jq -r '.balances[]? | select(.denom=="ulmn") | .amount' \
  | head -n1)"
BALANCE_ULMN="${BALANCE_ULMN:-0}"
if [[ "$BALANCE_ULMN" == "0" ]]; then
  error "Account $FROM_ADDR has no ulmn balance; at least $SELF_DELEGATION is required to create the validator / PQC signature."
fi

echo
read -r -p "Have you safely stored the mnemonic for '$FROM'? (y/N) " MNEM_OK
MNEM_OK=${MNEM_OK:-N}
if [[ ! "$MNEM_OK" =~ ^[Yy]$ ]]; then
  error "Please back up your mnemonic offline before creating a validator."
fi

# ------------------------- PQC KEY ENSURE -------------------------

PQC_NAME="validator-pqc"

step "Ensuring PQC key '$PQC_NAME'"
if ! $BIN keys pqc-show "$PQC_NAME" --home "$HOME_DIR" --keyring-backend "$KEYRING" >/dev/null 2>&1; then
    echo "PQC key '$PQC_NAME' not found in $HOME_DIR (keyring=$KEYRING)."
    read -r -p "Generate PQC key '$PQC_NAME' now? (y/N) " GEN_PQC
    GEN_PQC=${GEN_PQC:-N}
    if [[ ! "$GEN_PQC" =~ ^[Yy]$ ]]; then
      error "PQC key is required to register a validator; aborting."
    fi
    $BIN keys pqc-generate \
      --name "$PQC_NAME" \
      --home "$HOME_DIR" \
      --keyring-backend "$KEYRING" \
      >/dev/null
fi

PUB_HEX=$($BIN keys pqc-show "$PQC_NAME" --home "$HOME_DIR" --keyring-backend "$KEYRING" | grep "PubKey (hex)" | sed 's/.*: *//')
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
    [ "$CODE" = "0" ] || error "PQC link-account failed (CheckTx): code=$CODE"

    step "Waiting for PQC link tx to commit"
    LINK_COMMIT_CODE=$(wait_tx "$LINK_HASH") || error "Timeout waiting for PQC link tx to commit"
    [ "$LINK_COMMIT_CODE" = "0" ] || error "PQC link-account failed on commit: code=$LINK_COMMIT_CODE"

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
  "amount": "$SELF_DELEGATION",
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
    --pqc-from "$FROM_ADDR" \
    --pqc-key "$PQC_NAME" \
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

# ------------------------- OPTIONAL LOCAL BACKUP -------------------------
echo
read -r -p "To facilitate future UI import, create local backup in '$HOME_DIR/${BACKUP_DIR_DEFAULT}' (wallet keyring + PQC + optional mnemonic)? (y/N) " DO_BACKUP
DO_BACKUP=${DO_BACKUP:-N}

if [[ "$DO_BACKUP" =~ ^[Yy]$ ]]; then
  step "Creating local validator backup"

  BACKUP_DIR="${HOME_DIR}/${BACKUP_DIR_DEFAULT}"
  mkdir -p "$BACKUP_DIR"
  rm -rf "${BACKUP_DIR:?}/"*

  {
    echo "moniker=$MONIKER"
    echo "chain_id=$CHAIN_ID"
    echo "account_address=$FROM_ADDR"
    echo "valoper_address=$VALOPER"
    echo "pqc_name=$PQC_NAME"
  } > "$BACKUP_DIR/metadata.txt"

  # Optional mnemonic capture (operator may prefer offline storage only).
  echo
  read -r -p "Paste mnemonic for '$FROM' to store in backup (leave empty to skip): " MNEMONIC_INPUT || true
  if [[ -n "$MNEMONIC_INPUT" ]]; then
    printf '%s\n' "$MNEMONIC_INPUT" > "$BACKUP_DIR/validator_mnemonic.txt"
  fi

  cp -r "$HOME_DIR"/keyring-* "$BACKUP_DIR/" 2>/dev/null || true
  cp -r "$HOME_DIR/pqc_keys" "$BACKUP_DIR/" 2>/dev/null || true
  cp "$HOME_DIR/config/"*.json "$BACKUP_DIR/" 2>/dev/null || true
  cp "$HOME_DIR/config/"*.toml "$BACKUP_DIR/" 2>/dev/null || true

  info "Local backup directory ready to export: $BACKUP_DIR"
  info "Copy it OFF the server (e.g. with scp) and store it safely."
else
  info "Skipped creation of on-host validator backup directory."
fi
