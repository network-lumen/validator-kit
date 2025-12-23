#!/usr/bin/env bash
set -euo pipefail

#######################################################################
# Lumen — Opinionated fullnode / sentry init
#
# This script wraps the existing helpers to encode the "safe" order
# for joining an existing network as a non-validator node:
#
#   1. Ensure a lumend binary exists.
#   2. Join the network (creates \$HOME/.lumen with config + keys).
#   3. Enable state sync against a trusted RPC endpoint.
#   4. Only then install and start the systemd service.
#
# The idea is that the node never starts before state sync is
# configured, so it does not waste time replaying from genesis or
# accidentally trust the wrong height/hash.
#######################################################################

usage() {
  cat <<EOF
Usage: $(basename "$0") <moniker> [--home DIR] [--rpc URL] [--public-api]

Joins an existing Lumen network as a fullnode / sentry on this host.

Options:
  --home DIR      Override the node home directory.
                  Default: \$HOME/.lumen (or LUMEN_HOME if set).
  --rpc URL       Trusted RPC endpoint to use for state sync
                  (e.g. http://100.64.0.1:26657).
                  If omitted, the state_sync helper will prompt.
  --public-api    Use the RPC/API profile (config/rpc) instead of the
                  default fullnode profile (config/fullnode).

You can also set LUMEN_HOME to point at the desired node home; the
--home flag takes precedence over LUMEN_HOME.

Safety guarantees:
  - Refuses to run if the resolved node home already exists (no
    destructive resets; use scripts/network/join.sh --force if you
    know what you're doing).
  - Forces the order: join -> state sync -> systemd service.
  - Verifies that state sync is enabled in config.toml before starting
    the service.

Advanced users can call the underlying scripts directly:
  - scripts/network/join.sh
  - scripts/network/state_sync.sh
  - scripts/install/lumend_service.sh
EOF
}

MONIKER=""
RPC_URL=""
PUBLIC_API=0
LUMEN_HOME_OVERRIDE="${LUMEN_HOME:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --home)
      LUMEN_HOME_OVERRIDE="${2:-}"
      shift 2 || true
      ;;
    --rpc)
      RPC_URL="${2:-}"
      shift 2 || true
      ;;
    --public-api)
      PUBLIC_API=1
      shift
      ;;
    *)
      if [[ -z "$MONIKER" ]]; then
        MONIKER="$1"
        shift
      else
        echo "Unknown option: $1"
        usage
        exit 1
      fi
      ;;
  esac
done

if [[ -z "$MONIKER" ]]; then
  usage
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DEFAULT_HOME="${HOME}/.lumen"
NODE_HOME="${LUMEN_HOME_OVERRIDE:-$DEFAULT_HOME}"
DEFAULT_LUMEND_BIN="${REPO_ROOT}/bin/lumend"
LUMEND_BIN_PATH="${LUMEND_BIN:-${LUMEN_TARGET:-$DEFAULT_LUMEND_BIN}}"
DOWNLOAD_SCRIPT="${REPO_ROOT}/scripts/install/download_lumend.sh"
JOIN_SCRIPT="${REPO_ROOT}/scripts/network/join.sh"
STATE_SYNC_SCRIPT="${REPO_ROOT}/scripts/network/state_sync.sh"
SERVICE_SCRIPT="${REPO_ROOT}/scripts/install/lumend_service.sh"
ADD_PEER_SCRIPT="${REPO_ROOT}/scripts/network/add_peer.sh"
RELOAD_PEERS_SCRIPT="${REPO_ROOT}/scripts/network/reload_peers.sh"

echo "=== Lumen fullnode / sentry init ==="
echo "Moniker   : ${MONIKER}"
echo "Home      : ${NODE_HOME}"
echo "RPC (opt) : ${RPC_URL:-<prompt in state_sync.sh>}"
echo

# As with the validator init, we never auto-delete an existing home.
# A non-empty home suggests this host already has state or a
# running node, and blowing it away from an "init" script would be
# dangerous.
if [[ -e "${NODE_HOME}" ]]; then
  echo "ERROR: ${NODE_HOME} already exists."
  echo "This script assumes a fresh node with no existing state."
  echo "If you need to rejoin, manage the home manually and use"
  echo "scripts/network/join.sh directly (with --force if required)."
  exit 1
fi

# Resolve the HOME value seen by join.sh (which derives its own
# \$HOME/.lumen) so that everything lines up with the operator-facing
# node home path we just logged.
HELPER_HOME="$HOME"
if [[ "${NODE_HOME}" != "${DEFAULT_HOME}" ]]; then
  PARENT_DIR="$(dirname "${NODE_HOME}")"
  SYM_PATH="${PARENT_DIR}/.lumen"
  mkdir -p "${PARENT_DIR}"

  if [[ -e "${SYM_PATH}" && ! -L "${SYM_PATH}" ]]; then
    echo "ERROR: ${SYM_PATH} already exists and is not a symlink; refusing to overwrite." >&2
    exit 1
  fi

  if [[ -L "${SYM_PATH}" && "$(readlink "${SYM_PATH}")" != "${NODE_HOME}" ]]; then
    echo "ERROR: ${SYM_PATH} already points somewhere else; refusing to reuse it." >&2
    exit 1
  fi

  ln -sfn "${NODE_HOME}" "${SYM_PATH}"
  HELPER_HOME="${PARENT_DIR}"
fi

if [[ ! -x "${DOWNLOAD_SCRIPT}" ]]; then
  echo "ERROR: download helper not found at ${DOWNLOAD_SCRIPT}"
  exit 1
fi

if [[ ! -x "${JOIN_SCRIPT}" ]]; then
  echo "ERROR: join helper not found at ${JOIN_SCRIPT}"
  exit 1
fi

if [[ ! -x "${STATE_SYNC_SCRIPT}" ]]; then
  echo "ERROR: state sync helper not found at ${STATE_SYNC_SCRIPT}"
  exit 1
fi

if [[ ! -x "${SERVICE_SCRIPT}" ]]; then
  echo "ERROR: systemd installer not found at ${SERVICE_SCRIPT}"
  exit 1
fi

if [[ ! -x "${ADD_PEER_SCRIPT}" ]]; then
  echo "WARNING: add_peer helper not found at ${ADD_PEER_SCRIPT}; skipping RPC persistent peer injection."
  ADD_PEER_SCRIPT=""
fi

if [[ ! -x "${RELOAD_PEERS_SCRIPT}" ]]; then
  echo "WARNING: reload_peers helper not found at ${RELOAD_PEERS_SCRIPT}; skipping peer reload step."
  RELOAD_PEERS_SCRIPT=""
fi

echo "[1/5] Ensuring lumend binary is available"
echo "       (this calls scripts/install/download_lumend.sh)"
"${DOWNLOAD_SCRIPT}"

echo
echo "[2/5] Joining the network as a node"

JOIN_ARGS=()
if [[ "${PUBLIC_API}" -eq 1 ]]; then
  echo "       Using RPC/API config profile (config/rpc)"
  JOIN_ARGS+=(--public-api)
else
  echo "       Using fullnode config profile (config/fullnode)"
fi

# join.sh:
#   - initializes a .lumen home
#   - copies config/{fullnode,rpc}/*.toml and genesis.json
#   - sets seeds/persistent_peers from config/*.txt
#   - creates PQC keys and a join-node.bak backup
HOME="${HELPER_HOME}" "${JOIN_SCRIPT}" "${MONIKER}" "${JOIN_ARGS[@]}"

echo
echo "[2b/5] Reinforcing peers from config/peers.txt (post-join)"

if [[ -n "${RELOAD_PEERS_SCRIPT}" ]]; then
  "${RELOAD_PEERS_SCRIPT}" --home "${NODE_HOME}" --no-restart
fi

BACKUP_DIR="${NODE_HOME}/join-node.bak"

echo
echo "[3/5] Verifying join backup at ${BACKUP_DIR}"

if [[ ! -d "${BACKUP_DIR}" ]]; then
  echo "ERROR: expected backup directory ${BACKUP_DIR} was not created."
  echo "Aborting before enabling state sync or installing a service."
  exit 1
fi

CFG_TOML="${NODE_HOME}/config/config.toml"
if [[ ! -f "${CFG_TOML}" ]]; then
  echo "ERROR: config.toml not found at ${CFG_TOML} after join."
  exit 1
fi

echo
echo "[4/5] Enabling state sync *before* first start"
echo "       (this calls scripts/network/state_sync.sh)"

STATE_SYNC_ARGS=(--home "${NODE_HOME}")
if [[ -n "${RPC_URL}" ]]; then
  STATE_SYNC_ARGS+=(--rpc "${RPC_URL}")
fi

# The state_sync helper will:
#   - query the trusted RPC for the latest height
#   - pick a trust height/hash window
#   - write the [statesync] section in config.toml
# We run it before any systemd service exists to ensure the very first
# start uses state sync instead of replaying from genesis.
"${STATE_SYNC_SCRIPT}" "${STATE_SYNC_ARGS[@]}"

echo
echo "Verifying that state sync is enabled in ${CFG_TOML} ..."
if ! grep -Eq '^\s*enable\s*=\s*true' "${CFG_TOML}"; then
  echo "ERROR: state sync does not appear to be enabled in ${CFG_TOML}."
  echo "Refusing to install/start the service. Inspect the file and,"
  echo "if needed, re-run scripts/network/state_sync.sh manually."
  exit 1
fi

# Optional: push the state sync RPC node into persistent_peers before the
# first start, so snapshot discovery works reliably through that peer.
if [[ -n "${RPC_URL}" && -n "${ADD_PEER_SCRIPT}" ]]; then
  echo
  echo "[4b/5] Adding state sync RPC as a persistent peer"

  PRIMARY_RPC="${RPC_URL%%,*}"
  PRIMARY_RPC="${PRIMARY_RPC%/}"

  # Strip scheme (http://, https://) if present.
  STRIPPED="${PRIMARY_RPC#*://}"
  if [[ "${STRIPPED}" == "${PRIMARY_RPC}" ]]; then
    STRIPPED="${PRIMARY_RPC}"
  fi

  RPC_HOST_PORT="${STRIPPED}"
  RPC_HOST="${RPC_HOST_PORT%%:*}"

  if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    echo "WARNING: curl and/or jq not available; skipping RPC persistent peer injection."
  else
    STATUS_JSON="$(curl -fsS "${PRIMARY_RPC}/status" 2>/dev/null || true)"
    if [[ -z "${STATUS_JSON}" ]]; then
      echo "WARNING: failed to query ${PRIMARY_RPC}/status; skipping RPC persistent peer injection."
    else
      NODE_ID="$(printf '%s' "${STATUS_JSON}" | jq -r '.result.node_info.id // empty')"
      LISTEN_ADDR="$(printf '%s' "${STATUS_JSON}" | jq -r '.result.node_info.listen_addr // empty')"

      P2P_PORT="26656"
      if [[ "${LISTEN_ADDR}" == *:* ]]; then
        P2P_PORT="${LISTEN_ADDR##*:}"
        P2P_PORT="${P2P_PORT//[^0-9]/}"
        [[ -z "${P2P_PORT}" ]] && P2P_PORT="26656"
      fi

      if [[ -z "${NODE_ID}" || -z "${RPC_HOST}" ]]; then
        echo "WARNING: could not extract node_id or host for RPC; skipping RPC persistent peer injection."
      else
        RPC_PEER="${NODE_ID}@${RPC_HOST}:${P2P_PORT}"
        echo "→ Adding RPC node as persistent peer: ${RPC_PEER}"
        "${ADD_PEER_SCRIPT}" --peer "${RPC_PEER}" --home "${NODE_HOME}" --no-restart

        if [[ -n "${RELOAD_PEERS_SCRIPT}" ]]; then
          echo "→ Reloading persistent_peers into ${NODE_HOME} from config/peers.txt"
          "${RELOAD_PEERS_SCRIPT}" --home "${NODE_HOME}" --no-restart
        fi
      fi
    fi
  fi
fi

if [[ -n "${RELOAD_PEERS_SCRIPT}" ]]; then
  echo
  echo "→ Reinforcing peers from config/peers.txt (post-RPC injection)"
  "${RELOAD_PEERS_SCRIPT}" --home "${NODE_HOME}" --no-restart
fi

echo
echo "[5/5] Installing lumend systemd service"
echo "       (this will use sudo and may prompt for your password)"

if ! command -v sudo >/dev/null 2>&1; then
  echo "ERROR: sudo not found; cannot install systemd service automatically."
  echo "You can install it manually with:"
  echo "  sudo ${SERVICE_SCRIPT} \"${NODE_HOME}\" \"${USER}\""
  exit 1
fi

SERVICE_EXISTS=0
SERVICE_ACTIVE=0
if systemctl list-unit-files 2>/dev/null | grep -q '^lumend\.service'; then
  SERVICE_EXISTS=1
  if systemctl is-active --quiet lumend 2>/dev/null; then
    SERVICE_ACTIVE=1
  fi
fi

if [[ "${SERVICE_EXISTS}" -eq 0 ]]; then
  echo
  echo "→ Calling: sudo LUMEND_BIN=\"${LUMEND_BIN_PATH}\" ${SERVICE_SCRIPT} \"${NODE_HOME}\" \"${USER}\""
  sudo LUMEND_BIN="${LUMEND_BIN_PATH}" "${SERVICE_SCRIPT}" "${NODE_HOME}" "${USER}"
else
  if [[ "${SERVICE_ACTIVE}" -eq 1 ]]; then
    echo
    echo "A lumend systemd service is currently RUNNING."
    echo "Overwriting it will stop and restart the node."
    read -r -p "Do you want to stop the service and continue? [y/N] " ANSWER
    ANSWER="${ANSWER:-N}"
    if ! [[ "${ANSWER}" =~ ^[Yy]$ ]]; then
      echo "Aborting without touching existing lumend.service."
      exit 0
    fi

    echo "Stopping lumend.service ..."
    if ! sudo systemctl stop lumend; then
      echo "ERROR: failed to stop lumend.service; aborting."
      exit 1
    fi

    echo "→ Calling: sudo LUMEND_BIN=\"${LUMEND_BIN_PATH}\" ${SERVICE_SCRIPT} --force \"${NODE_HOME}\" \"${USER}\""
    if ! sudo LUMEND_BIN="${LUMEND_BIN_PATH}" "${SERVICE_SCRIPT}" --force "${NODE_HOME}" "${USER}"; then
      echo "ERROR: lumend_service.sh failed; existing service may need manual attention."
      exit 1
    fi

    echo "Starting lumend.service ..."
    if ! sudo systemctl start lumend; then
      echo "ERROR: failed to start lumend.service; check 'systemctl status lumend'."
      exit 1
    fi
  else
    echo
    echo "A lumend systemd service already exists but is stopped."
    read -r -p "Do you want to overwrite it with the new configuration? [y/N] " ANSWER
    ANSWER="${ANSWER:-N}"
    if ! [[ "${ANSWER}" =~ ^[Yy]$ ]]; then
      echo "Aborting without touching existing lumend.service."
      exit 0
    fi

    echo "→ Calling: sudo LUMEND_BIN=\"${LUMEND_BIN_PATH}\" ${SERVICE_SCRIPT} --force \"${NODE_HOME}\" \"${USER}\""
    if ! sudo LUMEND_BIN="${LUMEND_BIN_PATH}" "${SERVICE_SCRIPT}" --force "${NODE_HOME}" "${USER}"; then
      echo "ERROR: lumend_service.sh failed; existing service may need manual attention."
      exit 1
    fi
  fi
fi

echo
echo "=== Node init complete ==="
echo "Home directory : ${NODE_HOME}"
echo "Local backup   : ${BACKUP_DIR}"
echo
echo "You can inspect the service with:"
echo "  sudo systemctl status lumend"
echo
echo "Node started with state sync enabled."
echo "It will fast-forward to the configured trust height before continuing with live blocks."
