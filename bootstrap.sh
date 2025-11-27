#!/usr/bin/env bash
set -euo pipefail

# Bootstrap the first Lumen validator (genesis creator) with PQC enabled.
# Uses the bundled lumend binary from this folder by default.
#
# Usage:
#   sudo bash bootstrap.sh --moniker <name> --chain-id <id> [options]
#
# Typical flow:
#   1) On the first validator server:
#        cd /path/to/lumen/deploy
#        sudo bash bootstrap.sh --moniker node-1 --chain-id lumen --force
#   2) Backup /root/.lumen/first-node.bak somewhere safe.
#   3) Install the systemd service (optional):
#        cd /path/to/lumen/deploy/tools
#        sudo bash launch_service.sh --force /root/.lumen root

usage() {
  cat <<'EOF'
Usage: bootstrap.sh [options]

Required flags:
  --moniker <name>               Validator moniker
  --chain-id <id>                Target chain-id

Optional flags:
  --home <dir>                   Lumen home directory (default: $HOME/.lumen)
  --binary <path>                Path to the lumend binary
                                 (default: ./lumend in this folder, then lumend in PATH)
  --keyring-backend <backend>    Keyring backend (default: test)
  --stake <amount>               Self-delegation amount for gentx (default: 1000000ulmn)
  --balance <amount>             Genesis balance for the validator account (default: 1000000ulmn)
  --mnemonic-file <path>         File containing the validator mnemonic (if omitted, a new mnemonic is generated)
  --pqc-name <name>              Local name for the PQC key (default: validator-pqc)
  --install-service              Install the systemd service after bootstrapping (uses tools/launch_service.sh)
  --force                        Remove existing home directory before bootstrapping

Environment:
  LUMEN_INSTALL_SERVICE_ARGS     Extra arguments passed to launch_service.sh when --install-service is used.
EOF
}

MONIKER=""
CHAIN_ID=""
HOME_DIR="$HOME/.lumen"
BINARY=""
KEYRING="test"
STAKE="1000000ulmn"
BALANCE="1000000ulmn"
MNEMONIC_FILE=""
PQC_NAME="validator-pqc"
INSTALL_SERVICE=0
FORCE=0
BACKUP_DIR_SUFFIX="first-node.bak"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --moniker) MONIKER="$2"; shift ;;
    --chain-id) CHAIN_ID="$2"; shift ;;
    --home) HOME_DIR="$2"; shift ;;
    --binary) BINARY="$2"; shift ;;
    --keyring-backend) KEYRING="$2"; shift ;;
    --stake) STAKE="$2"; shift ;;
    --balance) BALANCE="$2"; shift ;;
    --mnemonic-file) MNEMONIC_FILE="$2"; shift ;;
    --pqc-name) PQC_NAME="$2"; shift ;;
    --install-service) INSTALL_SERVICE=1 ;;
    --force) FORCE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

if [[ -z "$MONIKER" || -z "$CHAIN_ID" ]]; then
  echo "Error: --moniker and --chain-id are required." >&2
  usage
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_BUNDLE="${SCRIPT_DIR}/lumend"

if [[ -z "$BINARY" ]]; then
  if [[ -x "$DEFAULT_BUNDLE" ]]; then
    BINARY="$DEFAULT_BUNDLE"
  elif command -v lumend >/dev/null 2>&1; then
    BINARY="$(command -v lumend)"
  else
    echo "Binary lumend not found. Place it at $DEFAULT_BUNDLE or pass --binary <path>." >&2
    exit 1
  fi
fi

command -v jq >/dev/null 2>&1 || { echo "jq is required"; exit 1; }

if [[ -d "$HOME_DIR" ]]; then
  if [[ "$FORCE" -eq 1 ]]; then
    rm -rf "$HOME_DIR"
  else
    echo "Home directory $HOME_DIR already exists. Use --force to overwrite." >&2
    exit 1
  fi
fi

echo "[1/8] Initializing home at $HOME_DIR"
"$BINARY" init "$MONIKER" --chain-id "$CHAIN_ID" --home "$HOME_DIR" >/dev/null

echo "[2/8] Preparing validator key"
if [[ -n "$MNEMONIC_FILE" ]]; then
  "$BINARY" keys add validator --recover --source "$MNEMONIC_FILE" --keyring-backend "$KEYRING" --home "$HOME_DIR" >/dev/null
  MNEMONIC=""
else
  KEY_JSON=$("$BINARY" keys add validator --keyring-backend "$KEYRING" --home "$HOME_DIR" --output json)
  MNEMONIC=$(printf '%s' "$KEY_JSON" | jq -r '.mnemonic')
  printf 'Generated mnemonic (store securely): %s\n' "$MNEMONIC"
fi
VAL_ADDR=$("$BINARY" keys show validator -a --keyring-backend "$KEYRING" --home "$HOME_DIR")

echo "[3/8] Funding validator account with $BALANCE"
"$BINARY" genesis add-genesis-account "$VAL_ADDR" "$BALANCE" --keyring-backend "$KEYRING" --home "$HOME_DIR"

echo "[4/8] Generating PQC key"
"$BINARY" keys pqc-generate --name "$PQC_NAME" --link-from validator --home "$HOME_DIR" --keyring-backend "$KEYRING" >/dev/null

echo "[5/8] Injecting PQC entry into genesis"
"$BINARY" keys pqc-genesis-entry --from validator --pqc "$PQC_NAME" --home "$HOME_DIR" --keyring-backend "$KEYRING" --write-genesis "$HOME_DIR/config/genesis.json" >/dev/null

echo "[6/8] Creating gentx with stake $STAKE"
"$BINARY" genesis gentx validator "$STAKE" --chain-id "$CHAIN_ID" --keyring-backend "$KEYRING" --home "$HOME_DIR" >/dev/null

echo "[7/8] Collecting gentxs"
"$BINARY" genesis collect-gentxs --home "$HOME_DIR" >/dev/null

# Configure pruning to keep recent history but avoid unbounded disk growth.
APP_TOML="$HOME_DIR/config/app.toml"
if [[ -f "$APP_TOML" ]]; then
  sed -i.bak 's/^pruning *=.*/pruning = "custom"/' "$APP_TOML" || true
  sed -i.bak 's/^pruning-keep-recent *=.*/pruning-keep-recent = "1000"/' "$APP_TOML" || true
  sed -i.bak 's/^pruning-keep-every *=.*/pruning-keep-every = "0"/' "$APP_TOML" || true
  sed -i.bak 's/^pruning-interval *=.*/pruning-interval = "100"/' "$APP_TOML" || true
fi

# Backup secrets
BACKUP_DIR="$HOME_DIR/$BACKUP_DIR_SUFFIX"
mkdir -p "$BACKUP_DIR"
rm -rf "$BACKUP_DIR"/*
if [[ -n "${MNEMONIC:-}" ]]; then
  printf '%s\n' "$MNEMONIC" >"$BACKUP_DIR/validator_mnemonic.txt"
fi
{
  echo "validator_address=$VAL_ADDR"
  echo "pqc_name=$PQC_NAME"
} >"$BACKUP_DIR/metadata.txt"
cp -r "$HOME_DIR/keyring-test" "$BACKUP_DIR/keyring-test"
cp -r "$HOME_DIR/pqc_keys" "$BACKUP_DIR/pqc_keys"
cp "$HOME_DIR/config/priv_validator_key.json" "$BACKUP_DIR/priv_validator_key.json"
cp "$HOME_DIR/config/node_key.json" "$BACKUP_DIR/node_key.json"
cp "$HOME_DIR/config/genesis.json" "$BACKUP_DIR/genesis.json"

# Ensure priv_validator_state.json exists for the service
mkdir -p "$HOME_DIR/data"
STATE_FILE="$HOME_DIR/data/priv_validator_state.json"
if [[ ! -f "$STATE_FILE" ]]; then
  cat >"$STATE_FILE" <<'EOF'
{"height":"0","round":0,"step":0,"signature":null,"signbytes":null,"timestamp":"0001-01-01T00:00:00Z"}
EOF
fi

# Optional backup archive (no encryption, plaintext only)
read -rp "Create backup archive (tar.gz) now? [y/N]: " ARCHIVE_CHOICE
if [[ "${ARCHIVE_CHOICE,,}" == "y" ]]; then
  TAR_PATH="${HOME_DIR}/first-node.bak.tar.gz"
  tar -czf "${TAR_PATH}" -C "${HOME_DIR}" "${BACKUP_DIR_SUFFIX}"
  echo "Backup archive saved to ${TAR_PATH} (plaintext; encrypt it separately if desired)"
fi

if [[ "$INSTALL_SERVICE" -eq 1 ]]; then
  echo "[8/8] Installing systemd service"
  LUMEN_HOME="$HOME_DIR" BIN_PATH="$BINARY" bash "$SCRIPT_DIR/tools/launch_service.sh" ${LUMEN_INSTALL_SERVICE_ARGS:-}
else
  echo "[8/8] Skipping systemd installation (use --install-service to enable)"
fi

cat <<EOF
Bootstrap completed.
  Home directory : $HOME_DIR
  Validator addr : $VAL_ADDR
  PQC key name   : $PQC_NAME

Use 'lumend start --home $HOME_DIR' or enable the systemd service to start the node.
EOF