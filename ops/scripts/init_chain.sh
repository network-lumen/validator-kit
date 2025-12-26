#!/usr/bin/env bash
set -euo pipefail

#######################################################################
# Lumen — Chain initialisation (new network, block 0)
#
# This orchestration script is for *network maintainers only*.
# It wraps the low-level bootstrap helper to create a *new* Lumen
# network with a single initial validator at block 0.
#
# It does *not*:
#   - join an existing chain
#   - configure state sync
#   - read or apply peers.txt
#   - attempt to connect to any existing network
#
# Use this exactly once per network. All other machines should use
# scripts/init_node.sh to join the existing chain defined by the
# resulting genesis.json.
#######################################################################

usage() {
  cat <<EOF
Usage: $(basename "$0") <moniker> [--home DIR]

Creates a *new* Lumen network with a single initial validator at block 0.

This script:
  - wraps scripts/network/bootstrap.sh
  - creates a fresh node home
  - generates validator + consensus keys
  - generates PQC keys and writes them into genesis
  - writes backups under <home>/first-node.bak

Important:
  - This is a *network creation* tool, not a join tool.
  - Do NOT use it to connect a validator to an existing chain.
  - Peers and sentries are added later, after other nodes join using
    the same genesis.json via scripts/init_node.sh.

Options:
  --home DIR   Override the node home directory.
               Default: \$HOME/.lumen (or LUMEN_HOME if set).

You can also set LUMEN_HOME to point at the desired node home; the
--home flag takes precedence over LUMEN_HOME.
EOF
}

MONIKER=""
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
    *)
      if [[ -z "$MONIKER" ]]; then
        MONIKER="$1"
        shift
      else
        echo "Unknown argument: $1"
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
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

DEFAULT_HOME="${HOME}/.lumen"
NODE_HOME="${LUMEN_HOME_OVERRIDE:-$DEFAULT_HOME}"
DEFAULT_LUMEND_BIN="${REPO_ROOT}/bin/lumend"
LUMEND_BIN_PATH="${LUMEND_BIN:-${LUMEN_TARGET:-$DEFAULT_LUMEND_BIN}}"
DOWNLOAD_SCRIPT="${REPO_ROOT}/ops/scripts/install/download_lumend.sh"
BOOTSTRAP_SCRIPT="${REPO_ROOT}/ops/scripts/network/bootstrap.sh"
SERVICE_SCRIPT="${REPO_ROOT}/ops/scripts/install/lumend_service.sh"

echo "=== Lumen chain initialisation (new network, block 0) ==="
echo "Moniker : ${MONIKER}"
echo "Home    : ${NODE_HOME}"
echo
echo "This script CREATES a new network at block 0."
echo "It must NOT be used to join an existing chain."
echo

# We never auto-delete or reuse an existing node home. A pre-existing
# home almost always means "this host already has state", and deleting
# it silently could destroy a live validator or chain data.
if [[ -e "${NODE_HOME}" ]]; then
  echo "ERROR: ${NODE_HOME} already exists."
  echo "This script is only for a *fresh* initial validator at block 0."
  echo "If you really need to wipe it, back it up and remove it"
  echo "manually, or use scripts/network/bootstrap.sh with --force."
  exit 1
fi

# Resolve the HOME value seen by bootstrap.sh (which derives its own
# \$HOME/.lumen) so that everything still lines up with the operator-
# facing node home path we just logged.
HELPER_HOME="$HOME"
if [[ "${NODE_HOME}" != "${DEFAULT_HOME}" ]]; then
  PARENT_DIR="$(dirname "${NODE_HOME}")"
  SYM_PATH="${PARENT_DIR}/.lumen"
  mkdir -p "${PARENT_DIR}"

  if [[ -e "${SYM_PATH}" && ! -L "${SYM_PATH}" ]]; then
    echo "ERROR: ${SYM_PATH} already exists and is not a symlink; refusing to overwrite."
    exit 1
  fi

  if [[ -L "${SYM_PATH}" && "$(readlink "${SYM_PATH}")" != "${NODE_HOME}" ]]; then
    echo "ERROR: ${SYM_PATH} already points somewhere else; refusing to reuse it."
    exit 1
  fi

  ln -sfn "${NODE_HOME}" "${SYM_PATH}"
  HELPER_HOME="${PARENT_DIR}"
fi

if [[ ! -x "${DOWNLOAD_SCRIPT}" ]]; then
  echo "ERROR: download helper not found at ${DOWNLOAD_SCRIPT}"
  exit 1
fi

if [[ ! -x "${BOOTSTRAP_SCRIPT}" ]]; then
  echo "ERROR: bootstrap helper not found at ${BOOTSTRAP_SCRIPT}"
  exit 1
fi

if [[ ! -x "${SERVICE_SCRIPT}" ]]; then
  echo "ERROR: systemd installer not found at ${SERVICE_SCRIPT}"
  exit 1
fi

echo "[1/4] Ensuring lumend binary is available"
echo "       (this calls scripts/install/download_lumend.sh)"
# Download first so bootstrap will either succeed or fail before any
# on-disk state is created with the wrong binary.
"${DOWNLOAD_SCRIPT}"

echo
echo "[2/4] Bootstrapping initial validator from repo config"
echo "       (scripts/network/bootstrap.sh ${MONIKER})"
# bootstrap.sh:
#   - reads chain-id and genesis from config/genesis.json
#   - uses config/validator/* as templates
#   - generates validator + PQC keys
#   - creates a .lumen home and a first-node.bak backup
HOME="${HELPER_HOME}" "${BOOTSTRAP_SCRIPT}" "${MONIKER}"

BACKUP_DIR="${NODE_HOME}/first-node.bak"

echo
echo "[3/4] Verifying bootstrap backup at ${BACKUP_DIR}"

if [[ ! -d "${BACKUP_DIR}" ]]; then
  echo "ERROR: expected backup directory ${BACKUP_DIR} was not created."
  echo "Aborting before installing the service so you can inspect the"
  echo "bootstrap logs and fix the issue."
  exit 1
fi

MISSING=0
for f in "metadata.txt" "validator_mnemonic.txt"; do
  if [[ ! -f "${BACKUP_DIR}/${f}" ]]; then
    echo "WARNING: ${BACKUP_DIR}/${f} is missing."
    MISSING=1
  fi
done

if ! ls "${BACKUP_DIR}"/*.json >/dev/null 2>&1; then
  echo "WARNING: no *.json files found under ${BACKUP_DIR}."
  echo "Expected to see genesis.json and consensus/node key backups."
  MISSING=1
fi

if [[ "${MISSING}" -eq 1 ]]; then
  echo
  echo "Backup looks incomplete. It is strongly recommended to fix this"
  echo "before putting funds on this validator."
fi

echo
echo "[4/4] Installing lumend systemd service (optional but recommended)"
echo "       (this will use sudo and may prompt for your password)"

# We install the service only after bootstrap + backup so that the first
# start of lumend cannot race with key generation or backup creation.
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
echo "=== Chain init complete ==="
echo "Home directory : ${NODE_HOME}"
echo "Local backup   : ${BACKUP_DIR}"
echo
echo "This node is the initial validator of a NEW network."
echo "It starts from block 0 using the genesis.json created here."
echo
echo "Do NOT use this script to join an existing network."
echo "Other nodes should use scripts/init_node.sh with the same genesis."
echo
echo "You can inspect the service with:"
echo "  sudo systemctl status lumend"
