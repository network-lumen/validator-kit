#!/usr/bin/env bash
set -euo pipefail

###############################################
# Lumen - Join an existing network with a selected node role
# Fully offline — config & genesis come from repo
# Seeds/persistent peers taken from networks/mainnet/*.txt
#
# Selecting the validator role only installs validator-suitable configuration;
# validator registration and staking remain separate blockchain workflows.
###############################################

# --- Arguments ---------------------------------------------------------------

if [[ $# -lt 1 ]]; then
  echo "Usage: join.sh <moniker> [--role ROLE] [--force]"
  exit 1
fi

MONIKER="$1"
shift || true

HOME_DIR="$HOME/.lumen"
FORCE=0
PUBLIC_API=0
SEED_MODE=0
ROLE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --role)
      [[ $# -ge 2 ]] || { echo "ERROR: --role requires a value." >&2; exit 1; }
      NEW_ROLE="$2"
      if [[ -n "$ROLE" && "$ROLE" != "$NEW_ROLE" ]]; then
        echo "ERROR: conflicting node roles '$ROLE' and '$NEW_ROLE'." >&2
        exit 1
      fi
      ROLE="$NEW_ROLE"
      shift
      ;;
    --public-api)
      if [[ -n "$ROLE" && "$ROLE" != rpc ]]; then
        echo "ERROR: --public-api conflicts with --role $ROLE" >&2
        exit 1
      fi
      PUBLIC_API=1
      ROLE="rpc"
      ;;
    --seed)
      if [[ -n "$ROLE" && "$ROLE" != seed ]]; then
        echo "ERROR: --seed conflicts with --role $ROLE" >&2
        exit 1
      fi
      SEED_MODE=1
      ROLE="seed"
      ;;
    --force)       FORCE=1 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
  shift
done

if [[ -z "$ROLE" ]]; then
  ROLE="fullnode"
fi
case "$ROLE" in
  fullnode|rpc|validator|sentry|seed) ;;
  *)
    echo "ERROR: unsupported node role '$ROLE'" >&2
    echo "Supported roles: fullnode rpc validator sentry seed" >&2
    exit 1
    ;;
esac
if [[ "$SEED_MODE" -eq 1 && "$PUBLIC_API" -eq 1 ]]; then
  echo "❌ --seed and --public-api cannot be combined" >&2
  exit 1
fi
if [[ "$SEED_MODE" -eq 1 && "$ROLE" != seed ]]; then
  echo "ERROR: --seed conflicts with --role $ROLE" >&2
  exit 1
fi
if [[ "$PUBLIC_API" -eq 1 && "$ROLE" != rpc ]]; then
  echo "ERROR: --public-api conflicts with --role $ROLE" >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# Repo paths
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/list_file.sh"

BIN="$REPO_ROOT/bin/lumend"
DEPS="$REPO_ROOT/deps"
GENESIS_SRC="$REPO_ROOT/networks/mainnet/genesis.json"
SEEDS_FILE="$REPO_ROOT/networks/mainnet/seeds.txt"
PEERS_FILE="$REPO_ROOT/networks/mainnet/peers.txt"
CFG_FULL="$REPO_ROOT/config/fullnode"
CFG_RPC="$REPO_ROOT/config/rpc"
CFG_VALIDATOR="$REPO_ROOT/config/validator"
CFG_SENTRY="$REPO_ROOT/config/sentry"
CFG_SEED="$REPO_ROOT/config/seed"

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
# Load seeds & peers from networks/mainnet/
# -----------------------------------------------------------------------------

[[ -f "$SEEDS_FILE" ]] || { echo "❌ Missing $SEEDS_FILE"; exit 1; }

SEEDS="$(network_list_csv "$SEEDS_FILE")"

PEERS=""
if [[ -f "$PEERS_FILE" ]]; then
  PEERS="$(network_list_csv "$PEERS_FILE")"
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
# Install the selected role profile
# -----------------------------------------------------------------------------

echo "[2/5] Installing config"

case "$ROLE" in
  fullnode) CFG_SRC="$CFG_FULL" ;;
  rpc) CFG_SRC="$CFG_RPC" ;;
  validator) CFG_SRC="$CFG_VALIDATOR" ;;
  sentry) CFG_SRC="$CFG_SENTRY" ;;
  seed) CFG_SRC="$CFG_SEED" ;;
esac
[[ -d "$CFG_SRC" ]] || { echo "ERROR: role profile is missing: $CFG_SRC" >&2; exit 1; }
echo "→ Using $ROLE profile from ${CFG_SRC#$REPO_ROOT/}"

cp "$CFG_SRC/app.toml"    "$HOME_DIR/config/app.toml"
cp "$CFG_SRC/client.toml" "$HOME_DIR/config/client.toml"
cp "$CFG_SRC/config.toml" "$HOME_DIR/config/config.toml"

CFG_TOML="$HOME_DIR/config/config.toml"
CFG_APP="$HOME_DIR/config/app.toml"

sed -i "s|^seeds *=.*|seeds = \"$SEEDS\"|" "$CFG_TOML"
if [[ "$ROLE" == seed ]]; then
  sed -i 's|^persistent_peers *=.*|persistent_peers = ""|' "$CFG_TOML"
else
  sed -i "s|^persistent_peers *=.*|persistent_peers = \"$PEERS\"|" "$CFG_TOML"
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

# Non-secret role identity consumed by Doctor and future tooling.
printf 'role=%s\n' "$ROLE" > "$HOME_DIR/validator-kit-role"
chmod 644 "$HOME_DIR/validator-kit-role"

# -----------------------------------------------------------------------------
# Done
# -----------------------------------------------------------------------------

echo "✔ DONE"
echo "Role: $ROLE"
echo "Start node:"
echo "  lumend start --home $HOME_DIR"
