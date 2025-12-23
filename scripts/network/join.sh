#!/usr/bin/env bash
set -euo pipefail

###############################################
# Lumen — Join an existing network (full/sentry/RPC)
# Fully offline — config & genesis come from repo
# Seeds/persistent peers taken from config/*.txt
#
# Modes:
#   - node (default, non-validator): runs as a fullnode/sentry/RPC node
#     with no local consensus key. This is the safe default and matches
#     Cosmos best practices: joining as a non-validator, then creating
#     a validator on-chain later if desired.
#   - validator (--validator): initialize this home with a local
#     consensus key and priv_validator_state.json so it can sign blocks.
###############################################

# --- Arguments ---------------------------------------------------------------

if [[ $# -lt 1 ]]; then
  echo "Usage: join.sh <moniker> [--public-api] [--validator] [--import-validator dir] [--pqc-backup dir]"
  exit 1
fi

MONIKER="$1"
shift || true

HOME_DIR="$HOME/.lumen"
KEYRING="test"
PQC_NAME="node-pqc"
MODE="node"   # default: non-validator node
IMPORT_VALIDATOR=""
PQC_BACKUP=""
BACKUP_DIR=""
FORCE=0
PUBLIC_API=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --public-api)      PUBLIC_API=1 ;;
    --validator)       MODE="validator" ;;
    --import-validator) IMPORT_VALIDATOR="$2"; shift ;;
    --pqc-backup)       PQC_BACKUP="$2"; shift ;;
    --backup-dir)       BACKUP_DIR="$2"; shift ;;
    --pqc-name)         PQC_NAME="$2"; shift ;;
    --force)            FORCE=1 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
  shift
done

echo "Mode: ${MODE} ($([[ "$MODE" == "validator" ]] && echo "validator" || echo "non-validator"))"

# -----------------------------------------------------------------------------
# Repo paths
# -----------------------------------------------------------------------------

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

BIN="$REPO_ROOT/bin/lumend"
DEPS="$REPO_ROOT/deps"
GENESIS_SRC="$REPO_ROOT/config/genesis.json"
SEEDS_FILE="$REPO_ROOT/config/seeds.txt"
PEERS_FILE="$REPO_ROOT/config/peers.txt"
CFG_FULL="$REPO_ROOT/config/fullnode"
CFG_RPC="$REPO_ROOT/config/rpc"

# -----------------------------------------------------------------------------
# Check binaries (local)
# -----------------------------------------------------------------------------

if [[ ! -x "$BIN" ]]; then
  echo "❌ Missing binary: $BIN"
  exit 1
fi

if command -v jq >/dev/null 2>&1; then
  JQ="$(command -v jq)"
else
  echo "❌ Missing jq in PATH. Please install jq (e.g. 'sudo apt install jq')."
  exit 1
fi

# -----------------------------------------------------------------------------
# Load seeds & peers from config/
# -----------------------------------------------------------------------------

[[ -f "$SEEDS_FILE" ]] || { echo "❌ Missing $SEEDS_FILE"; exit 1; }
SEEDS="$(head -n1 "$SEEDS_FILE" | tr -d '\r\n')"

PEERS=""
if [[ -f "$PEERS_FILE" ]]; then
  PEERS="$(head -n1 "$PEERS_FILE" | tr -d '\r\n')"
fi

# -----------------------------------------------------------------------------
# Reset ~/.lumen
# -----------------------------------------------------------------------------

if [[ -d "$HOME_DIR" ]]; then
  if [[ "$FORCE" -eq 1 ]]; then
    rm -rf "$HOME_DIR"
  else
    echo "❌ $HOME_DIR exists. Use --force"
    exit 1
  fi
fi

echo "[1/7] Init home: $HOME_DIR"
"$BIN" init "$MONIKER" --chain-id lumen --home "$HOME_DIR" >/dev/null

# -----------------------------------------------------------------------------
# Install fullnode config
# -----------------------------------------------------------------------------

echo "[2/7] Installing config"
CFG_SRC="$CFG_FULL"
if [[ "$PUBLIC_API" -eq 1 ]]; then
  if [[ ! -d "$CFG_RPC" ]]; then
    echo "❌ --public-api requested but $CFG_RPC is missing" >&2
    exit 1
  fi
  echo "→ Using RPC/API profile from config/rpc"
  CFG_SRC="$CFG_RPC"
fi

cp "$CFG_SRC/app.toml"    "$HOME_DIR/config/app.toml"
cp "$CFG_SRC/client.toml" "$HOME_DIR/config/client.toml"
cp "$CFG_SRC/config.toml" "$HOME_DIR/config/config.toml"

sed -i "s|^seeds *=.*|seeds = \"$SEEDS\"|" "$HOME_DIR/config/config.toml"
sed -i "s|^persistent_peers *=.*|persistent_peers = \"$PEERS\"|" "$HOME_DIR/config/config.toml"

# -----------------------------------------------------------------------------
# Install genesis.json
# -----------------------------------------------------------------------------

echo "[3/7] Installing genesis.json"
cp "$GENESIS_SRC" "$HOME_DIR/config/genesis.json"

CHAIN_ID="$("$JQ" -r '.chain_id' "$GENESIS_SRC")"
[[ -n "$CHAIN_ID" && "$CHAIN_ID" != "null" ]] || CHAIN_ID="lumen"

"$BIN" config chain-id "$CHAIN_ID" >/dev/null 2>&1 || true

sed -i "s|^chain-id *=.*|chain-id = \"$CHAIN_ID\"|" "$HOME_DIR/config/client.toml"

# -----------------------------------------------------------------------------
# Import validator keys (optional)
# -----------------------------------------------------------------------------

echo "[4/7] Validator key import (optional)"

if [[ -n "$IMPORT_VALIDATOR" ]]; then
  if [[ -f "$IMPORT_VALIDATOR/priv_validator_key.json" ]]; then
    cp "$IMPORT_VALIDATOR/priv_validator_key.json" "$HOME_DIR/config/"
  fi
  if [[ -f "$IMPORT_VALIDATOR/node_key.json" ]]; then
    cp "$IMPORT_VALIDATOR/node_key.json" "$HOME_DIR/config/"
  fi
fi

# -----------------------------------------------------------------------------
# PQC restore OR generate
# -----------------------------------------------------------------------------

echo "[5/7] PQC handling"

if [[ -n "$PQC_BACKUP" && -d "$PQC_BACKUP/pqc_keys" ]]; then
  echo "→ Restoring PQC keystore"
  mkdir -p "$HOME_DIR/pqc_keys"
  cp -r "$PQC_BACKUP/pqc_keys/." "$HOME_DIR/pqc_keys/"
else
  echo "→ Generating PQC key $PQC_NAME"
  "$BIN" keys pqc-generate \
    --name "$PQC_NAME" \
    --home "$HOME_DIR" \
    --keyring-backend "$KEYRING" \
    >/dev/null
fi

# -----------------------------------------------------------------------------
# Consensus state / priv_validator_state.json
# -----------------------------------------------------------------------------
if [[ "$MODE" == "validator" ]]; then
  echo "[6/7] Writing priv_validator_state.json (validator mode)"
  mkdir -p "$HOME_DIR/data"
  cat >"$HOME_DIR/data/priv_validator_state.json" <<EOF
{"height":"0","round":0,"step":0,"signature":null,"signbytes":null,"timestamp":"0001-01-01T00:00:00Z"}
EOF
else
  echo "[6/7] Node mode: removing local consensus key/state (non-validator)"

  if [[ -n "$IMPORT_VALIDATOR" ]]; then
    echo "ℹ Note: --import-validator was provided but mode is 'node'."
    echo "  Consensus key material will NOT be used in this home."
  fi

  # Defensive cleanup: ensure this home cannot accidentally behave as a validator.
  rm -f "$HOME_DIR/config/priv_validator_key.json" 2>/dev/null || true
  rm -f "$HOME_DIR/data/priv_validator_state.json" 2>/dev/null || true
fi

# -----------------------------------------------------------------------------
# Backup (always, no prompt)
# -----------------------------------------------------------------------------

echo "[7/7] Backup"

BACKUP_DIR="${BACKUP_DIR:-$HOME_DIR/join-node.bak}"
mkdir -p "$BACKUP_DIR"
rm -rf "$BACKUP_DIR/"*

VAL_ADDR="$("$BIN" keys show validator -a --home "$HOME_DIR" --keyring-backend "$KEYRING" 2>/dev/null || true)"

echo "moniker=$MONIKER" > "$BACKUP_DIR/metadata.txt"
echo "chain_id=$CHAIN_ID" >> "$BACKUP_DIR/metadata.txt"
echo "validator_address=$VAL_ADDR" >> "$BACKUP_DIR/metadata.txt"
echo "pqc_name=$PQC_NAME" >> "$BACKUP_DIR/metadata.txt"

cp "$HOME_DIR/config/"* "$BACKUP_DIR/" 2>/dev/null || true
cp -r "$HOME_DIR/pqc_keys" "$BACKUP_DIR/" 2>/dev/null || true
cp -r "$HOME_DIR/keyring-test" "$BACKUP_DIR/" 2>/dev/null || true

echo "✔ DONE"
echo "Start node:"
echo "  lumend start --home $HOME_DIR"
