#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Lumen – Validator Bootstrap (non-interactive)
# - Uses ./bin/lumend
# - Loads chain-id from config/genesis.json
# - Injects config/validator/*.toml
# - Generates validator key + PQC key
# - Creates gentx and collects it
# - Always creates a plaintext backup
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

LUMEN_BIN="${REPO_ROOT}/bin/lumend"
VALIDATOR_CFG_DIR="${REPO_ROOT}/config/validator"
GENESIS_FILE_REPO="${REPO_ROOT}/config/genesis.json"

HOME_DIR="$HOME/.lumen"
KEYRING="test"
STAKE="1000000ulmn"
BALANCE="1000000ulmn"
PQC_NAME="validator-pqc"
BACKUP_DIR_SUFFIX="first-node.bak"

MONIKER="${1:-}"
FORCE=0
[[ "${2:-}" == "--force" ]] && FORCE=1

if [[ -z "$MONIKER" ]]; then
  echo "Usage: bootstrap.sh <moniker> [--force]"
  exit 1
fi

# ---------------------------------------------------------------------------
# Requirements
# ---------------------------------------------------------------------------

if [[ ! -x "$LUMEN_BIN" ]]; then
  echo "ERROR: lumend binary not found at $LUMEN_BIN"
  exit 1
fi

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required"; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "ERROR: curl is required"; exit 1; }

if [[ ! -d "$VALIDATOR_CFG_DIR" ]]; then
  echo "ERROR: validator config directory missing: $VALIDATOR_CFG_DIR"
  exit 1
fi

if [[ ! -f "$GENESIS_FILE_REPO" ]]; then
  echo "ERROR: config/genesis.json is missing"
  exit 1
fi

CHAIN_ID="$(jq -r '.chain_id' "$GENESIS_FILE_REPO")"
if [[ -z "$CHAIN_ID" || "$CHAIN_ID" == "null" ]]; then
  echo "ERROR: chain_id is missing in config/genesis.json"
  exit 1
fi

echo "=== Validator Bootstrap ==="
echo "Moniker   : $MONIKER"
echo "Chain-ID  : $CHAIN_ID"
echo "Home      : $HOME_DIR"
echo

# ---------------------------------------------------------------------------
# Reset home
# ---------------------------------------------------------------------------

if [[ -d "$HOME_DIR" ]]; then
  if [[ "$FORCE" -eq 1 ]]; then
    echo "[1/7] Removing existing home: $HOME_DIR"
    rm -rf "$HOME_DIR"
  else
    echo "ERROR: $HOME_DIR already exists (use --force)"
    exit 1
  fi
fi

echo "[1/7] Initializing home directory"
"$LUMEN_BIN" init "$MONIKER" --chain-id "$CHAIN_ID" --home "$HOME_DIR" >/dev/null

# ---------------------------------------------------------------------------
# Inject config
# ---------------------------------------------------------------------------

echo "[2/7] Injecting validator config"
cp "$VALIDATOR_CFG_DIR/app.toml"    "$HOME_DIR/config/app.toml"
cp "$VALIDATOR_CFG_DIR/client.toml" "$HOME_DIR/config/client.toml"
cp "$VALIDATOR_CFG_DIR/config.toml" "$HOME_DIR/config/config.toml"

# Validator hardening
sed -i 's/^seeds *=.*/seeds = ""/' "$HOME_DIR/config/config.toml"
sed -i 's/^pex *=.*/pex = false/' "$HOME_DIR/config/config.toml"
sed -i 's/^allow_duplicate_ip *=.*/allow_duplicate_ip = false/' "$HOME_DIR/config/config.toml"

echo "[3/7] Copying genesis.json from repo"
cp "$GENESIS_FILE_REPO" "$HOME_DIR/config/genesis.json"

# ---------------------------------------------------------------------------
# Keys
# ---------------------------------------------------------------------------

echo "[4/7] Creating validator key"
KEY_JSON=$("$LUMEN_BIN" keys add validator --keyring-backend "$KEYRING" --home "$HOME_DIR" --output json)
MNEMONIC=$(printf '%s' "$KEY_JSON" | jq -r '.mnemonic')
VAL_ADDR=$("$LUMEN_BIN" keys show validator -a --keyring-backend "$KEYRING" --home "$HOME_DIR")

echo "[5/7] Adding validator genesis balance"
"$LUMEN_BIN" genesis add-genesis-account "$VAL_ADDR" "$BALANCE" \
  --keyring-backend "$KEYRING" \
  --home "$HOME_DIR"

echo "[6/7] Generating PQC key"
"$LUMEN_BIN" keys pqc-generate \
  --name "$PQC_NAME" \
  --link-from validator \
  --home "$HOME_DIR" \
  --keyring-backend "$KEYRING" >/dev/null

"$LUMEN_BIN" keys pqc-genesis-entry \
  --from validator \
  --pqc "$PQC_NAME" \
  --home "$HOME_DIR" \
  --keyring-backend "$KEYRING" \
  --write-genesis "$HOME_DIR/config/genesis.json" >/dev/null

echo "[6b/7] Creating gentx"
"$LUMEN_BIN" genesis gentx validator "$STAKE" \
  --chain-id "$CHAIN_ID" \
  --keyring-backend "$KEYRING" \
  --home "$HOME_DIR" >/dev/null

echo "[6c/7] Collecting gentxs"
"$LUMEN_BIN" genesis collect-gentxs --home "$HOME_DIR" >/dev/null

# priv_validator_state.json
mkdir -p "$HOME_DIR/data"
cat >"$HOME_DIR/data/priv_validator_state.json" <<'EOF'
{"height":"0","round":0,"step":0,"signature":null,"signbytes":null,"timestamp":"0001-01-01T00:00:00Z"}
EOF

# ---------------------------------------------------------------------------
# Backup (automatic)
# ---------------------------------------------------------------------------

echo "[7/7] Creating backup"

BACKUP_DIR="$HOME_DIR/$BACKUP_DIR_SUFFIX"
rm -rf "$BACKUP_DIR"
mkdir -p "$BACKUP_DIR"

printf '%s\n' "$MNEMONIC" >"$BACKUP_DIR/validator_mnemonic.txt"

{
  echo "moniker=$MONIKER"
  echo "chain_id=$CHAIN_ID"
  echo "validator_address=$VAL_ADDR"
  echo "pqc_name=$PQC_NAME"
} >"$BACKUP_DIR/metadata.txt"

cp -r "$HOME_DIR/keyring-$KEYRING" "$BACKUP_DIR/keyring-$KEYRING" 2>/dev/null || true
cp -r "$HOME_DIR/pqc_keys" "$BACKUP_DIR/pqc_keys" 2>/dev/null || true
cp "$HOME_DIR/config/"*.json "$BACKUP_DIR/" || true
cp "$HOME_DIR/config/"*.toml "$BACKUP_DIR/" || true

echo
echo "=== Bootstrap complete ==="
echo "Home directory : $HOME_DIR"
echo "Backup folder  : $BACKUP_DIR"
echo "Validator addr : $VAL_ADDR"
echo "PQC key name   : $PQC_NAME"
echo
