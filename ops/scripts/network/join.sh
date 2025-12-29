#!/usr/bin/env bash
set -euo pipefail

###############################################
# Lumen — Join an existing network (full/sentry/RPC)
# Fully offline — config & genesis come from repo
# Seeds/persistent peers taken from config/*.txt
#
# This helper only creates a non-validator node (fullnode / sentry / RPC).
# Becoming a validator (PQC + create-validator + staking) is handled by the
# dedicated blockchain scripts under ops/scripts/blockchain/.
###############################################

# --- Arguments ---------------------------------------------------------------

if [[ $# -lt 1 ]]; then
  echo "Usage: join.sh <moniker> [--public-api] [--seed] [--force]"
  exit 1
fi

MONIKER="$1"
shift || true

HOME_DIR="$HOME/.lumen"
FORCE=0
PUBLIC_API=0
SEED_MODE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --public-api)  PUBLIC_API=1 ;;
    --seed)        SEED_MODE=1 ;;
    --force)       FORCE=1 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
  shift
done

if [[ "$SEED_MODE" -eq 1 && "$PUBLIC_API" -eq 1 ]]; then
  echo "❌ --seed and --public-api cannot be combined" >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# Repo paths
# -----------------------------------------------------------------------------

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

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

# Collect all non-empty, trimmed lines from seeds.txt and join as a comma-separated list.
SEEDS="$(
  awk '
    BEGIN { seeds = "" }
    {
      gsub(/\r/, "")                          # strip CR
      gsub(/^[ \t]+|[ \t]+$/, "", $0)         # trim
      if ($0 != "") {
        if (seeds == "") { seeds = $0 }
        else { seeds = seeds "," $0 }
      }
    }
    END { print seeds }
  ' "$SEEDS_FILE"
)"

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

echo "[1/5] Init home: $HOME_DIR"
"$BIN" init "$MONIKER" --chain-id lumen --home "$HOME_DIR" >/dev/null

# -----------------------------------------------------------------------------
# Install fullnode config
# -----------------------------------------------------------------------------

echo "[2/5] Installing config"

CFG_SRC="$CFG_FULL"
PROFILE_LABEL="fullnode"

if [[ "$SEED_MODE" -eq 1 ]]; then
  echo "→ Using seed profile (fullnode config with seed_mode enabled)"
  PROFILE_LABEL="seed"
elif [[ "$PUBLIC_API" -eq 1 ]]; then
  if [[ ! -d "$CFG_RPC" ]]; then
    echo "❌ --public-api requested but $CFG_RPC is missing" >&2
    exit 1
  fi
  echo "→ Using RPC/API profile from config/rpc"
  CFG_SRC="$CFG_RPC"
  PROFILE_LABEL="rpc"
fi

cp "$CFG_SRC/app.toml"    "$HOME_DIR/config/app.toml"
cp "$CFG_SRC/client.toml" "$HOME_DIR/config/client.toml"
cp "$CFG_SRC/config.toml" "$HOME_DIR/config/config.toml"

CFG_TOML="$HOME_DIR/config/config.toml"
CFG_APP="$HOME_DIR/config/app.toml"

sed -i "s|^seeds *=.*|seeds = \"$SEEDS\"|" "$CFG_TOML"
sed -i "s|^persistent_peers *=.*|persistent_peers = \"$PEERS\"|" "$CFG_TOML"

if [[ "$SEED_MODE" -eq 1 ]]; then
  echo "→ Applying seed node tweaks (p2p.seed_mode=true, tx_index=null, RPC/API/gRPC disabled)"
  # Ensure PEX is enabled and seed_mode is true.
  sed -i 's/^pex *=.*/pex = true/' "$CFG_TOML"
  sed -i 's/^seed_mode *=.*/seed_mode = true/' "$CFG_TOML"
  # Seed nodes should not use static persistent peers.
  sed -i 's|^persistent_peers *=.*|persistent_peers = ""|' "$CFG_TOML"
  # Disable tx indexer to reduce disk IO.
  sed -i 's/^indexer *=.*/indexer = "null"/' "$CFG_TOML"
  # Explicitly disable RPC listener (no JSON-RPC endpoint on seeds).
  sed -i '/^\[rpc\]/,/^\[/ s|^laddr *=.*|laddr = ""|' "$CFG_TOML"
  # Optionally tighten peer counts to avoid runaway outbound dials.
  sed -i '/^\[p2p\]/,/^\[/ s/^max_num_outbound_peers *=.*/max_num_outbound_peers = 20/' "$CFG_TOML"
  # Harden application-level APIs: keep API off and disable gRPC / gRPC-Web.
  if [[ -f "$CFG_APP" ]]; then
    sed -i '/^\[api\]/,/^\[/ s/^enable *=.*/enable = false/' "$CFG_APP"
    sed -i '/^\[grpc\]/,/^\[/ s/^enable *=.*/enable = false/' "$CFG_APP"
    sed -i '/^\[grpc-web\]/,/^\[/ s/^enable *=.*/enable = false/' "$CFG_APP"
  fi
fi

# -----------------------------------------------------------------------------
# Install genesis.json
# -----------------------------------------------------------------------------

echo "[3/5] Installing genesis.json"
cp "$GENESIS_SRC" "$HOME_DIR/config/genesis.json"

CHAIN_ID="$("$JQ" -r '.chain_id' "$GENESIS_SRC")"
[[ -n "$CHAIN_ID" && "$CHAIN_ID" != "null" ]] || CHAIN_ID="lumen"

"$BIN" config chain-id "$CHAIN_ID" >/dev/null 2>&1 || true

sed -i "s|^chain-id *=.*|chain-id = \"$CHAIN_ID\"|" "$HOME_DIR/config/client.toml"

# -----------------------------------------------------------------------------
# Done
# -----------------------------------------------------------------------------

echo "✔ DONE"
echo "Start node:"
echo "  lumend start --home $HOME_DIR"
