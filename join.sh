#!/usr/bin/env bash
# Join an existing Lumen network as a full node (no gentx).
usage() {
  cat <<'EOF'
Usage: sudo bash join.sh <MONIKER> <seed_id@host:26656> [genesis_url] [options]

Positional arguments:
  MONIKER                    Local node moniker (e.g. validator-2)
  seed_id@host:26656         Seed / peer to connect to. Can also be provided via:
                               - SEEDS environment variable
                               - seeds.txt file next to this script (first line)
  genesis_url                Optional HTTP(S) URL for the chain genesis (either raw
                             genesis.json or the /genesis endpoint of a running node).
                             If omitted, the script will try to contact the first seed's
                             RPC endpoint at http://host:26657/genesis.

Options:
  --chain-id <id>              Override chain-id (default: autodetect from genesis)
  --persistent-peers <peers>   Comma-separated persistent peers
  --pqc-backup <dir>           Path to a pqc backup folder (pqc_keys) to restore from
  --import-priv <dir>          Path to a folder containing priv_validator_key.json and node_key.json
  --binary <path>              Use an existing lumend binary (skip download)
  --backup-dir <dir>           Save a backup of keys/config to <dir> (default: <home>/join-node.bak)
  --pqc-name <name>            Name for the PQC key to generate if missing (default: validator-pqc)
  --auto-backup                Create a backup without prompting
EOF
}

set -euo pipefail

MONIKER="${1:-}"
# SEEDS can come from 2nd arg, or from SEEDS env var if arg is empty.
SEEDS="${2:-${SEEDS:-}}"
GENESIS_URL="${3:-${GENESIS_URL:-}}"

# Consume only the positional args we actually have (1, 2, or 3),
# so that remaining $@ is reserved for flags like --chain-id, etc.
if [ "$#" -ge 3 ]; then
  shift 3
elif [ "$#" -ge 2 ]; then
  shift 2
elif [ "$#" -ge 1 ]; then
  shift 1
fi

CHAIN_ID=""
HOME_DIR="${HOME}/.lumen"
KEYRING="test"
DENOM="ulmn"
PERSISTENT_PEERS=""
PQC_BACKUP_DIR=""
IMPORT_PRIV_DIR=""
BINARY_OVERRIDE=""
BACKUP_DIR=""
AUTO_BACKUP=0
PQC_NAME="validator-pqc"
MNEMONIC_CREATED=""

while [ $# -gt 0 ]; do
  case "$1" in
    --chain-id) CHAIN_ID="$2"; shift 2 ;;
    --persistent-peers) PERSISTENT_PEERS="$2"; shift 2 ;;
    --pqc-backup) PQC_BACKUP_DIR="$2"; shift 2 ;;
    --import-priv) IMPORT_PRIV_DIR="$2"; shift 2 ;;
    --binary) BINARY_OVERRIDE="$2"; shift 2 ;;
    --backup-dir) BACKUP_DIR="$2"; shift 2 ;;
    --pqc-name) PQC_NAME="$2"; shift 2 ;;
    --auto-backup) AUTO_BACKUP=1; shift 1 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

# Fallback: if SEEDS still empty, try seeds.txt next to this script.
if [ -z "${SEEDS}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [ -f "${SCRIPT_DIR}/seeds.txt" ]; then
    SEEDS="$(head -n1 "${SCRIPT_DIR}/seeds.txt" | tr -d '\r\n')"
  fi
fi

if [ -z "${MONIKER}" ]; then
  echo "Error: MONIKER is required." >&2
  usage >&2
  exit 1
fi

if [ -z "${SEEDS}" ]; then
  echo "Error: seeds not provided (second argument, SEEDS env var, or seeds.txt)." >&2
  usage >&2
  exit 1
fi

# If no genesis_url was provided, try to derive it from the first seed.
if [ -z "${GENESIS_URL}" ]; then
  first_seed="${SEEDS%%,*}"
  peer="${first_seed#*@}"        # strip node-id@
  host_port="${peer}"
  host_rpc=""
  if [ -n "${host_port}" ]; then
    case "${host_port}" in
      \[*\]*:*)
        # IPv6 in [addr]:port form – keep [addr] as-is and switch to RPC port 26657.
        host_rpc="${host_port%:*}"
        ;;
      *:*)
        # hostname:port or IPv4:port
        host_rpc="${host_port%%:*}"
        ;;
      *)
        host_rpc="${host_port}"
        ;;
    esac
  fi
  if [ -n "${host_rpc}" ]; then
    GENESIS_URL="http://${host_rpc}:26657/genesis"
    echo "[join] GENESIS_URL not provided; auto-detected from seeds: ${GENESIS_URL}"
  fi
fi

if [ -z "${GENESIS_URL}" ]; then
  echo "Error: genesis_url is required and could not be derived from seeds." >&2
  usage >&2
  exit 1
fi

RPC_LADDR="tcp://0.0.0.0:26657"
P2P_LADDR="tcp://0.0.0.0:26656"
API_ADDR="tcp://0.0.0.0:1317"
GRPC_ADDR="0.0.0.0:9090"

log() { echo "[$(date -Ins)] $*"; }
require() { command -v "$1" >/dev/null 2>&1 || { log "missing dependency: $1"; exit 1; }; }

log "Installing dependencies"
apt-get update -y >/dev/null
apt-get install -y curl jq ca-certificates >/dev/null
require curl; require sha256sum

# Resolve lumend binary: prefer bundled deploy/lumend, then PATH, or explicit --binary.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_BUNDLE="${SCRIPT_DIR}/lumend"

BIN_PATH=""
if [ -n "${BINARY_OVERRIDE}" ]; then
  BIN_PATH="${BINARY_OVERRIDE}"
elif [ -x "${DEFAULT_BUNDLE}" ]; then
  BIN_PATH="${DEFAULT_BUNDLE}"
elif command -v lumend >/dev/null 2>&1; then
  BIN_PATH="$(command -v lumend)"
else
  log "lumend binary not found. Place it at ${DEFAULT_BUNDLE} or use --binary."
  exit 1
fi

log "Using lumend binary at ${BIN_PATH}"

# Ensure /usr/local/bin/lumend is installed for systemd / other tools.
if [ ! -x /usr/local/bin/lumend ] || ! cmp -s "${BIN_PATH}" /usr/local/bin/lumend 2>/dev/null; then
  log "Installing lumend to /usr/local/bin"
  if command -v install >/dev/null 2>&1; then
    install -m 0755 "${BIN_PATH}" /usr/local/bin/lumend
  else
    cp "${BIN_PATH}" /usr/local/bin/lumend
    chmod 0755 /usr/local/bin/lumend
  fi
fi

log "Resetting home at ${HOME_DIR}"
rm -rf "${HOME_DIR}"

log "Init node ${MONIKER}"
lumend init "${MONIKER}" --chain-id "${CHAIN_ID}" --home "${HOME_DIR}"

# Ensure validator key exists (capture mnemonic if newly created)
if ! lumend keys show validator --keyring-backend "${KEYRING}" --home "${HOME_DIR}" >/dev/null 2>&1; then
  log "Creating validator key"
  KEY_JSON=$(lumend keys add validator --keyring-backend "${KEYRING}" --home "${HOME_DIR}" --output json)
  MNEMONIC_CREATED=$(printf '%s' "${KEY_JSON}" | jq -r '.mnemonic')
fi

log "Fetching genesis from ${GENESIS_URL}"
TMP_GENESIS="$(mktemp)"
curl -fsSL "${GENESIS_URL}" >"${TMP_GENESIS}"
if jq -e '.result.genesis' >/dev/null 2>&1 <"${TMP_GENESIS}"; then
  jq -r '.result.genesis' <"${TMP_GENESIS}" >"${HOME_DIR}/config/genesis.json"
else
  cp "${TMP_GENESIS}" "${HOME_DIR}/config/genesis.json"
fi
rm -f "${TMP_GENESIS}"

if [ -z "${CHAIN_ID}" ]; then
  CHAIN_ID="$(jq -r '.chain_id // .result.genesis.chain_id // empty' "${HOME_DIR}/config/genesis.json")"
  if [ -z "${CHAIN_ID}" ] || [ "${CHAIN_ID}" = "null" ]; then
    CHAIN_ID="lumen"
    log "chain-id not found in genesis, defaulting to ${CHAIN_ID}"
  else
    log "Detected chain-id from genesis: ${CHAIN_ID}"
  fi
fi

log "Rewriting config with chain-id ${CHAIN_ID}"
lumend config chain-id "${CHAIN_ID}" >/dev/null 2>&1 || true

# Client config
CLIENT_TOML="${HOME_DIR}/config/client.toml"
sed -i "s|^node *=.*|node = \"${RPC_LADDR}\"|" "${CLIENT_TOML}"
sed -i "s|^chain-id *=.*|chain-id = \"${CHAIN_ID}\"|" "${CLIENT_TOML}"

# CometBFT config
CONFIG_TOML="${HOME_DIR}/config/config.toml"
sed -i "s|^laddr *=.*26657\"|laddr = \"${RPC_LADDR}\"|" "${CONFIG_TOML}"
sed -i "s|^external_address *=.*|external_address = \"\"|" "${CONFIG_TOML}"
sed -i "s|^seeds *=.*|seeds = \"${SEEDS}\"|" "${CONFIG_TOML}"
sed -i "s|^persistent_peers *=.*|persistent_peers = \"${PERSISTENT_PEERS}\"|" "${CONFIG_TOML}"
sed -i "s|^pex *=.*|pex = true|" "${CONFIG_TOML}"

# App config
APP_TOML="${HOME_DIR}/config/app.toml"
sed -i "s|^minimum-gas-prices *=.*|minimum-gas-prices = \"0${DENOM}\"|" "${APP_TOML}"
sed -i "s|^address *=.*1317\"|address = \"${API_ADDR}\"|" "${APP_TOML}"
sed -i "s|^address *=.*9090\"|address = \"${GRPC_ADDR}\"|" "${APP_TOML}"
sed -i "s|^enable *=.*|enable = true|" "${APP_TOML}"

# Optional: import PQC keystore (pqc_keys) in plaintext
if [ -n "${PQC_BACKUP_DIR}" ] && [ -d "${PQC_BACKUP_DIR}" ]; then
  if [ -d "${PQC_BACKUP_DIR}/pqc_keys" ]; then
    log "Importing PQC keystore from ${PQC_BACKUP_DIR}/pqc_keys (plaintext)"
    mkdir -p "${HOME_DIR}/pqc_keys"
    cp -r "${PQC_BACKUP_DIR}/pqc_keys/." "${HOME_DIR}/pqc_keys/"
  else
    log "PQC backup dir provided but pqc_keys not found inside"
  fi
fi

# Optional: import validator/node keys (for restoring an existing validator)
if [ -n "${IMPORT_PRIV_DIR}" ] && [ -d "${IMPORT_PRIV_DIR}" ]; then
  for f in priv_validator_key.json node_key.json; do
    if [ -f "${IMPORT_PRIV_DIR}/${f}" ]; then
      log "Importing ${f} from ${IMPORT_PRIV_DIR}"
      cp "${IMPORT_PRIV_DIR}/${f}" "${HOME_DIR}/config/${f}"
    fi
  done
fi

# Ensure a PQC key exists (generate if missing) — PLAINTEXT, NO PASSPHRASE
if [ ! -d "${HOME_DIR}/pqc_keys" ] || [ -z "$(ls -A "${HOME_DIR}/pqc_keys" 2>/dev/null)" ]; then
  LINK_ARGS=()
  if lumend keys show validator --home "${HOME_DIR}" --keyring-backend "${KEYRING}" >/dev/null 2>&1; then
    LINK_ARGS+=(--link-from validator)
  fi
  log "Generating PQC key (${PQC_NAME}) in plaintext (no passphrase)"
  lumend keys pqc-generate \
    --name "${PQC_NAME}" \
    --home "${HOME_DIR}" \
    --keyring-backend "${KEYRING}" \
    "${LINK_ARGS[@]}" >/dev/null
else
  log "Existing PQC keystore detected; leaving as-is (expected plaintext)."
fi

# Backup (opt-in unless --auto-backup)
do_backup=0
if [ "${AUTO_BACKUP}" -eq 1 ]; then
  do_backup=1
else
  read -rp "Create backup of keys/config now? [y/N]: " ans
  if echo "${ans}" | grep -qi '^y'; then do_backup=1; fi
fi

if [ "${do_backup}" -eq 1 ]; then
  BACKUP_DIR="${BACKUP_DIR:-${HOME_DIR}/join-node.bak}"
  log "Creating backup at ${BACKUP_DIR}"
  mkdir -p "${BACKUP_DIR}"
  rm -rf "${BACKUP_DIR:?}/"*

  # Try to detect validator address (optional)
  VAL_ADDR="$(lumend keys show validator -a --keyring-backend "${KEYRING}" --home "${HOME_DIR}" 2>/dev/null || true)"

  # Detect first pqc key name from links.json if present
  PQC_NAME_META=""
  if [ -f "${HOME_DIR}/pqc_keys/links.json" ]; then
    PQC_NAME_META="$(jq -r 'to_entries[0].value // empty' "${HOME_DIR}/pqc_keys/links.json" 2>/dev/null || true)"
  fi
  if [ -z "${PQC_NAME_META}" ] && [ -n "${PQC_NAME}" ]; then
    PQC_NAME_META="${PQC_NAME}"
  fi

  {
    echo "moniker=${MONIKER}"
    echo "chain_id=${CHAIN_ID}"
    echo "validator_address=${VAL_ADDR}"
    if [ -n "${PQC_NAME_META}" ]; then echo "pqc_name=${PQC_NAME_META}"; fi
  } >"${BACKUP_DIR}/metadata.txt"

  cp -f "${HOME_DIR}/config/genesis.json" "${BACKUP_DIR}/genesis.json" 2>/dev/null || true
  cp -f "${HOME_DIR}/config/config.toml" "${BACKUP_DIR}/config.toml" 2>/dev/null || true
  cp -f "${HOME_DIR}/config/app.toml" "${BACKUP_DIR}/app.toml" 2>/dev/null || true
  cp -f "${HOME_DIR}/config/client.toml" "${BACKUP_DIR}/client.toml" 2>/dev/null || true
  cp -f "${HOME_DIR}/config/priv_validator_key.json" "${BACKUP_DIR}/priv_validator_key.json" 2>/dev/null || true
  cp -f "${HOME_DIR}/config/node_key.json" "${BACKUP_DIR}/node_key.json" 2>/dev/null || true
  if [ -n "${MNEMONIC_CREATED}" ]; then
    printf '%s\n' "${MNEMONIC_CREATED}" >"${BACKUP_DIR}/validator_mnemonic.txt"
  fi
  if [ -d "${HOME_DIR}/pqc_keys" ]; then
    mkdir -p "${BACKUP_DIR}/pqc_keys"
    cp -r "${HOME_DIR}/pqc_keys/." "${BACKUP_DIR}/pqc_keys/"
  fi
  # Note: no pqc_passphrase.txt anymore: PQC keystore is plaintext.
  if [ -d "${HOME_DIR}/keyring-test" ]; then
    cp -r "${HOME_DIR}/keyring-test" "${BACKUP_DIR}/keyring-test"
  fi
  log "Backup completed at ${BACKUP_DIR}"
else
  log "Backup skipped"
fi

log "Starting lumend (smoke test)"
lumend start --home "${HOME_DIR}" \
  --rpc.laddr "${RPC_LADDR}" \
  --p2p.laddr "${P2P_LADDR}" \
  --api.enable \
  --api.address "${API_ADDR}" \
  --grpc.address "${GRPC_ADDR}" >/tmp/lumend.log 2>&1 &
PID=$!
sleep 6

log "Node status (truncated):"
lumend status --node "${RPC_LADDR}" | head -c 400 || true

log "Tail log (first 20 lines):"
head -n 20 /tmp/lumend.log || true

log "Stopping node"
kill "${PID}" >/dev/null 2>&1 || true

log "Done. Home at ${HOME_DIR}. To run as a service: sudo bash tools/launch_service.sh --force ${HOME_DIR} root"