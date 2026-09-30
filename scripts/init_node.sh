#!/usr/bin/env bash
set -euo pipefail

#######################################################################
# Lumen - Role-aware node init
#
# This script wraps the existing helpers to encode the "safe" order
# for joining an existing network with a selected role. The validator role
# installs validator-suitable configuration but does not register a validator:
#
#   1. Ensure a verified lumend binary exists.
#   2. Join the network (creates \$HOME/.lumen with config + keys).
#   3. Optionally enable state sync against a trusted RPC endpoint.
#   4. Only then install and start the systemd service.
#
# When an RPC endpoint is provided, the node does not start before state
# sync is configured. Without one, it replays blocks from peers.
#######################################################################

usage() {
  cat <<EOF
Usage: $(basename "$0") <moniker> [options]

Joins an existing Lumen network using one of the supported node roles.

Options:
  --role ROLE     fullnode, rpc, validator, sentry, or seed (default: fullnode).
  --network NAME  mainnet (testnet/devnet require network assets in the repo).
  --service-mode  cosmovisor (default) or direct.
  --public-api    Legacy alias for --role rpc.
  --seed          Legacy alias for --role seed.
  --home DIR      Override the node home directory.
                  Default: \$HOME/.lumen (or LUMEN_HOME if set).
  --rpc URL       Trusted RPC endpoint to use for state sync
                  (e.g. http://100.64.0.1:26657).
                  If omitted, state sync is skipped and the node
                  synchronizes using seeds and peer exchange.
  --non-interactive
                  Never prompt for deployment decisions.

You can also set LUMEN_HOME to point at the desired node home; the
--home flag takes precedence over LUMEN_HOME.

Safety guarantees:
  - Refuses to run if the resolved node home already exists (no
    destructive resets; use ./scripts/network/join.sh --force if you
    know what you're doing).
  - Forces the order: join -> optional state sync -> systemd service.
  - Verifies state sync before service start when --rpc is provided.

Advanced users can call the underlying scripts directly:
  - ./scripts/network/join.sh
  - ./scripts/network/state_sync.sh
  - ./scripts/install/lumend_service.sh
EOF
}

MONIKER=""
RPC_URL=""
PUBLIC_API=0
SEED_MODE=0
ROLE=""
NON_INTERACTIVE=0
NETWORK="mainnet"
SERVICE_MODE="cosmovisor"
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
    --role)
      NEW_ROLE="${2:-}"
      if [[ -n "$ROLE" && "$ROLE" != "$NEW_ROLE" ]]; then
        echo "ERROR: conflicting node roles '$ROLE' and '$NEW_ROLE'." >&2
        exit 1
      fi
      ROLE="$NEW_ROLE"
      shift 2 || true
      ;;
    --seed)
      if [[ -n "$ROLE" && "$ROLE" != seed ]]; then
        echo "ERROR: --seed conflicts with --role $ROLE." >&2
        exit 1
      fi
      SEED_MODE=1
      ROLE="seed"
      shift
      ;;
    --rpc)
      RPC_URL="${2:-}"
      shift 2 || true
      ;;
    --network)
      NETWORK="${2:-}"
      shift 2 || true
      ;;
    --service-mode)
      SERVICE_MODE="${2:-}"
      shift 2 || true
      ;;
    --public-api)
      if [[ -n "$ROLE" && "$ROLE" != rpc ]]; then
        echo "ERROR: --public-api conflicts with --role $ROLE." >&2
        exit 1
      fi
      PUBLIC_API=1
      ROLE="rpc"
      shift
      ;;
    --non-interactive)
      NON_INTERACTIVE=1
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
if [[ "${SEED_MODE}" -eq 1 && "${PUBLIC_API}" -eq 1 ]]; then
  echo "ERROR: --seed and --public-api cannot be combined."
  exit 1
fi
if [[ "${SEED_MODE}" -eq 1 && "$ROLE" != seed ]]; then
  echo "ERROR: --seed conflicts with --role $ROLE."
  exit 1
fi
if [[ "${PUBLIC_API}" -eq 1 && "$ROLE" != rpc ]]; then
  echo "ERROR: --public-api conflicts with --role $ROLE."
  exit 1
fi
case "$SERVICE_MODE" in
  cosmovisor|direct) ;;
  *)
    echo "ERROR: unsupported service mode '$SERVICE_MODE'; use cosmovisor or direct." >&2
    exit 1
    ;;
esac
case "$NETWORK" in
  mainnet) ;;
  testnet|devnet)
    echo "ERROR: $NETWORK assets are incomplete in this checkout; deployment is currently mainnet-only." >&2
    exit 1
    ;;
  *)
    echo "ERROR: unsupported network '$NETWORK'." >&2
    exit 1
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DEFAULT_HOME="${HOME:-/root}/.lumen"
NODE_HOME="${LUMEN_HOME_OVERRIDE:-$DEFAULT_HOME}"
DEFAULT_LUMEND_BIN="${REPO_ROOT}/bin/lumend"
LUMEND_BIN_PATH="${LUMEND_BIN:-${LUMEN_TARGET:-$DEFAULT_LUMEND_BIN}}"
DOWNLOAD_SCRIPT="${REPO_ROOT}/scripts/install/download_lumend.sh"
JOIN_SCRIPT="${REPO_ROOT}/scripts/network/join.sh"
STATE_SYNC_SCRIPT="${REPO_ROOT}/scripts/network/state_sync.sh"
SERVICE_SCRIPT="${REPO_ROOT}/scripts/install/lumend_service.sh"
COSMOVISOR_INSTALL_SCRIPT="${REPO_ROOT}/scripts/install/install_cosmovisor.sh"
ADD_PEER_SCRIPT="${REPO_ROOT}/scripts/network/add_peer.sh"
RELOAD_PEERS_SCRIPT="${REPO_ROOT}/scripts/network/reload_peers.sh"

NODE_HOME_ABS="$(realpath -m -- "${NODE_HOME}")"
if [[ "$SERVICE_MODE" == direct ]]; then
  LUMEND_BIN_ABS="$(realpath -m -- "${LUMEND_BIN_PATH}")"
  if [[ "${LUMEND_BIN_ABS}" == "${NODE_HOME_ABS}" || "${LUMEND_BIN_ABS}" == "${NODE_HOME_ABS}/"* ]]; then
    echo "ERROR: lumend binary target '${LUMEND_BIN_PATH}' is inside node home '${NODE_HOME}'." >&2
    echo "Choose a binary path outside the node home, such as '${DEFAULT_LUMEND_BIN}'." >&2
    exit 1
  fi
fi

echo "=== Lumen ${ROLE} init ==="
echo "Role      : ${ROLE}"
echo "Moniker   : ${MONIKER}"
echo "Home      : ${NODE_HOME}"
echo "RPC (opt) : ${RPC_URL:-<state sync disabled>}"
echo "Network   : ${NETWORK}"
echo "Service   : ${SERVICE_MODE}"
echo

# As with the validator init, we never auto-delete an existing home.
# A non-empty home suggests this host already has state or a
# running node, and blowing it away from an "init" script would be
# dangerous.
if [[ -e "${NODE_HOME}" || -L "${NODE_HOME}" ]]; then
  echo "ERROR: ${NODE_HOME} already exists."
  echo "This script assumes a fresh node with no existing state."
  echo "If you need to rejoin, manage the home manually and use"
  echo "./scripts/network/join.sh directly (with --force if required)."
  exit 1
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

if [[ "$SERVICE_MODE" == cosmovisor && ! -x "${COSMOVISOR_INSTALL_SCRIPT}" ]]; then
  echo "ERROR: Cosmovisor installer not found at ${COSMOVISOR_INSTALL_SCRIPT}" >&2
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

DEPLOY_BINARY_TARGET="${LUMEND_BIN_PATH}"
STAGING_DIR=""
cleanup_staging() {
  [[ -n "$STAGING_DIR" && -d "$STAGING_DIR" ]] && rm -rf -- "$STAGING_DIR"
  return 0
}
trap cleanup_staging EXIT
if [[ "$SERVICE_MODE" == cosmovisor ]]; then
  # Stage outside the fresh home so the join primitive can create the home
  # before the verified binary is moved into Cosmovisor's genesis layout.
  STAGING_DIR="$(mktemp -d)"
  DEPLOY_BINARY_TARGET="$STAGING_DIR/lumend"
fi

echo "[1/5] Ensuring verified lumend binary is available"
echo "       (this calls ./scripts/install/download_lumend.sh)"
LUMEN_NETWORK="${NETWORK}" LUMEN_TARGET="${DEPLOY_BINARY_TARGET}" "${DOWNLOAD_SCRIPT}"

echo
echo "[2/5] Joining the network as a node"

JOIN_ARGS=(--home "${NODE_HOME}" --role "${ROLE}" --network "${NETWORK}")
echo "       Using ${ROLE} config profile"

# join.sh:
#   - initializes a .lumen home
#   - copies config/{fullnode,rpc}/*.toml and genesis.json
#   - sets seeds/persistent_peers from config/*.txt
LUMEND_BIN="${DEPLOY_BINARY_TARGET}" "${JOIN_SCRIPT}" "${MONIKER}" "${JOIN_ARGS[@]}"

if [[ "$SERVICE_MODE" == cosmovisor ]]; then
  GENESIS_BIN="${NODE_HOME}/cosmovisor/genesis/bin/lumend"
  mkdir -p "${NODE_HOME}/cosmovisor/genesis/bin" "${NODE_HOME}/cosmovisor/upgrades"
  mv -- "${DEPLOY_BINARY_TARGET}" "${GENESIS_BIN}"
  chmod 0755 "${GENESIS_BIN}"
  DEPLOY_BINARY_TARGET="$GENESIS_BIN"
  echo "Cosmovisor genesis binary: ${GENESIS_BIN}"
fi

echo
echo "[2b/5] Reinforcing peers from networks/mainnet/peers.txt (post-join)"

if [[ "$ROLE" == seed ]]; then
  echo "→ Skipping persistent_peers reload (seed mode)"
elif [[ -n "${RELOAD_PEERS_SCRIPT}" ]]; then
  "${RELOAD_PEERS_SCRIPT}" --home "${NODE_HOME}" --no-restart
fi

CFG_TOML="${NODE_HOME}/config/config.toml"
if [[ ! -f "${CFG_TOML}" ]]; then
  echo "ERROR: config.toml not found at ${CFG_TOML} after join."
  exit 1
fi

echo
if [[ -z "${RPC_URL}" ]]; then
  echo "No RPC provided, skipping state sync. Bootstrap will rely on seeds + PEX."
else
  echo "[4/5] Enabling state sync *before* first start"
echo "       (this calls ./scripts/network/state_sync.sh)"

  STATE_SYNC_ARGS=(--home "${NODE_HOME}")
  STATE_SYNC_ARGS+=(--non-interactive)
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
    echo "if needed, re-run ./scripts/network/state_sync.sh manually."
    exit 1
  fi
fi

# Optional: push the state sync RPC node into persistent_peers before the
# first start, so snapshot discovery works reliably through that peer.
if [[ "$ROLE" != seed && -n "${RPC_URL}" && -n "${ADD_PEER_SCRIPT}" ]]; then
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
          echo "→ Reloading persistent_peers into ${NODE_HOME} from networks/mainnet/peers.txt"
          "${RELOAD_PEERS_SCRIPT}" --home "${NODE_HOME}" --no-restart
        fi
      fi
    fi
  fi
fi

if [[ "$ROLE" == seed ]]; then
  echo
  echo "→ Skipping persistent_peers reload (seed mode)"
elif [[ -n "${RELOAD_PEERS_SCRIPT}" ]]; then
  echo
  echo "→ Reinforcing peers from networks/mainnet/peers.txt (post-RPC injection)"
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

if [[ "$SERVICE_MODE" == cosmovisor ]]; then
  COSMOVISOR_BIN_PATH="${COSMOVISOR_BIN:-}"
  if [[ -z "$COSMOVISOR_BIN_PATH" ]]; then
    COSMOVISOR_BIN_PATH="$(command -v cosmovisor 2>/dev/null || true)"
  fi
  if [[ -n "$COSMOVISOR_BIN_PATH" ]]; then
    COSMOVISOR_BIN_PATH="$(realpath -- "$COSMOVISOR_BIN_PATH")"
    if [[ ! -x "$COSMOVISOR_BIN_PATH" ]]; then
      echo "ERROR: Cosmovisor binary is not executable at ${COSMOVISOR_BIN_PATH}." >&2
      exit 1
    fi
    COSMOVISOR_VERSION_OUTPUT="$(${COSMOVISOR_BIN_PATH} version 2>&1 || true)"
    if [[ -z "$COSMOVISOR_VERSION_OUTPUT" ]]; then
      echo "ERROR: Cosmovisor version could not be verified at ${COSMOVISOR_BIN_PATH}." >&2
      exit 1
    fi
    echo "→ Found existing Cosmovisor"
    echo "→ Cosmovisor: ${COSMOVISOR_BIN_PATH}"
    echo "→ Version: ${COSMOVISOR_VERSION_OUTPUT//$'\n'/ }"
    echo "→ Reusing existing installation"
  else
    echo "→ Installing pinned Cosmovisor through the repository installer"
    if ! INSTALL_OUTPUT="$(sudo env "PATH=${PATH:-}" "${COSMOVISOR_INSTALL_SCRIPT}")"; then
      echo "ERROR: Cosmovisor installation failed; refusing to continue without Cosmovisor." >&2
      exit 1
    fi
    printf '%s\n' "$INSTALL_OUTPUT"
    COSMOVISOR_BIN_PATH="$(awk -F= '$1 == "COSMOVISOR_PATH" { path = substr($0, index($0, "=") + 1) } END { print path }' <<< "$INSTALL_OUTPUT")"
    COSMOVISOR_BIN_PATH="${COSMOVISOR_BIN_PATH:-/usr/local/bin/cosmovisor}"
  fi
  if [[ ! -x "$COSMOVISOR_BIN_PATH" ]]; then
    echo "ERROR: Cosmovisor binary is not executable at ${COSMOVISOR_BIN_PATH}." >&2
    exit 1
  fi
  COSMOVISOR_VERSION_OUTPUT="$("${COSMOVISOR_BIN_PATH}" version 2>&1 || true)"
  if [[ -z "$COSMOVISOR_VERSION_OUTPUT" ]]; then
    echo "ERROR: Cosmovisor version could not be verified at ${COSMOVISOR_BIN_PATH}." >&2
    exit 1
  fi
  echo "Cosmovisor: ${COSMOVISOR_BIN_PATH} (${COSMOVISOR_VERSION_OUTPUT//$'\n'/ })"
  echo "→ Installing Cosmovisor lumend.service"
  SERVICE_ARGS=(--mode cosmovisor --cosmovisor-bin "${COSMOVISOR_BIN_PATH}")
  [[ "$NON_INTERACTIVE" -eq 1 ]] && SERVICE_ARGS+=(--non-interactive)
  SERVICE_ARGS+=("${NODE_HOME}" "${USER}")
  sudo "${SERVICE_SCRIPT}" "${SERVICE_ARGS[@]}"
else
  echo "→ Installing direct lumend.service"
  SERVICE_ARGS=(--mode direct)
  [[ "$NON_INTERACTIVE" -eq 1 ]] && SERVICE_ARGS+=(--non-interactive)
  SERVICE_ARGS+=("${NODE_HOME}" "${USER}")
  sudo LUMEND_BIN="${DEPLOY_BINARY_TARGET}" "${SERVICE_SCRIPT}" "${SERVICE_ARGS[@]}"
fi

echo
echo "=== Node init complete ==="
echo "Home directory : ${NODE_HOME}"
echo "Network        : ${NETWORK}"
echo "Service mode   : ${SERVICE_MODE}"
echo "Local backup   : <none created by init_node.sh>"
echo
echo "You can inspect the service with:"
echo "  sudo systemctl status lumend"
echo
if [[ -n "${RPC_URL}" ]]; then
  echo "Node started with state sync enabled."
  echo "It will fast-forward to the configured trust height before continuing with live blocks."
else
  echo "Node started without state sync; it will synchronize from peers."
fi
