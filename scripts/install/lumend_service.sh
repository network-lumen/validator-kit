#!/usr/bin/env bash
# Create and start a systemd service for an existing lumend home.
# Usage: sudo ./scripts/install/lumend_service.sh [--force] [--mode direct|cosmovisor] [HOME_DIR] [USER]
#
# - If you omit HOME_DIR / USER, they default to the user that ran sudo
#   (or root if there is no sudo context).

set -euo pipefail

FORCE=0
PRINT_UNIT=0
SERVICE_MODE="direct"
COSMOVISOR_BIN_PATH=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    --print-unit) PRINT_UNIT=1; shift ;;
    --mode)
      [[ $# -ge 2 ]] || { echo "ERROR: --mode requires direct or cosmovisor." >&2; exit 2; }
      SERVICE_MODE="$2"
      shift 2
      ;;
    --cosmovisor-bin)
      [[ $# -ge 2 ]] || { echo "ERROR: --cosmovisor-bin requires a path." >&2; exit 2; }
      COSMOVISOR_BIN_PATH="$2"
      shift 2
      ;;
    --help)
      echo "Usage: sudo ./scripts/install/lumend_service.sh [--force] [--mode direct|cosmovisor] [HOME_DIR] [USER]"
      echo "       ./scripts/install/lumend_service.sh --print-unit [--mode direct|cosmovisor] [HOME_DIR] [USER]"
      exit 0
      ;;
    *) break ;;
  esac
done
case "$SERVICE_MODE" in
  direct|cosmovisor) ;;
  *) echo "ERROR: unsupported service mode '$SERVICE_MODE'." >&2; exit 2 ;;
esac
if [[ "$EUID" -ne 0 && "$PRINT_UNIT" -eq 0 ]]; then
  echo "ERROR: this installer needs root privileges (sudo)." >&2
  echo "Use --print-unit to render a unit without installing it." >&2
  exit 1
fi

# Default to the sudo-invoking user if present, otherwise root.
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER:-}" != "root" ]]; then
  DEFAULT_USER="${SUDO_USER}"
  DEFAULT_HOME="$(eval echo "~${SUDO_USER}")"
else
  DEFAULT_USER="root"
  DEFAULT_HOME="/root"
fi

HOME_DIR="${1:-${DEFAULT_HOME}/.lumen}"
RUN_USER="${2:-${DEFAULT_USER}}"
# Try to suggest a reasonable default for the lumend binary:
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_BIN="${REPO_ROOT}/bin/lumend"

FOUND_BIN=""
if command -v lumend >/dev/null 2>&1; then
  FOUND_BIN="$(command -v lumend)"
fi

if [[ -n "$FOUND_BIN" ]]; then
  DEFAULT_BIN="$FOUND_BIN"
elif [[ -x "$REPO_BIN" ]]; then
  DEFAULT_BIN="$REPO_BIN"
else
  DEFAULT_BIN="/usr/local/bin/lumend"
fi

if [[ "$SERVICE_MODE" == direct ]]; then
  PREFERRED_BIN="${LUMEND_BIN:-${LUMEN_TARGET:-}}"
  if [[ -n "${PREFERRED_BIN}" ]]; then
    BIN_PATH="${PREFERRED_BIN}"
    echo "Using lumend binary from environment: ${BIN_PATH}"
  else
    read -r -p "Path to lumend binary? (${DEFAULT_BIN}): " BIN_PATH
    BIN_PATH="${BIN_PATH:-$DEFAULT_BIN}"
  fi
else
  if [[ -z "$COSMOVISOR_BIN_PATH" ]]; then
    COSMOVISOR_BIN_PATH="${COSMOVISOR_BIN:-}"
  fi
  if [[ -z "$COSMOVISOR_BIN_PATH" ]]; then
    COSMOVISOR_BIN_PATH="$(command -v cosmovisor 2>/dev/null || true)"
  fi
fi

SERVICE_FILE="/etc/systemd/system/lumend.service"

if [[ "$SERVICE_MODE" == direct ]]; then
  if [ ! -x "${BIN_PATH}" ]; then
    echo "lumend binary not found or not executable at ${BIN_PATH}." >&2
    echo "Install it or rerun this script and point to the correct path." >&2
    exit 1
  fi
else
  [[ -n "$COSMOVISOR_BIN_PATH" && -x "$COSMOVISOR_BIN_PATH" ]] || {
    echo "ERROR: Cosmovisor binary not found. Use --cosmovisor-bin PATH." >&2
    exit 1
  }
fi

if [ ! -d "${HOME_DIR}" ]; then
  echo "Home directory ${HOME_DIR} not found. Run bootstrap first." >&2
  exit 1
fi

CFG_TOML="${HOME_DIR}/config/config.toml"
IS_SEED_MODE=0
if [[ -f "${CFG_TOML}" ]] && grep -Eq '^[[:space:]]*seed_mode[[:space:]]*=[[:space:]]*true' "${CFG_TOML}"; then
  IS_SEED_MODE=1
fi

if [[ "$SERVICE_MODE" == cosmovisor && ! -x "$HOME_DIR/cosmovisor/genesis/bin/lumend" ]]; then
  echo "ERROR: missing Cosmovisor genesis binary: $HOME_DIR/cosmovisor/genesis/bin/lumend" >&2
  exit 1
fi

if [[ "$PRINT_UNIT" -eq 0 ]] && systemctl list-unit-files | grep -q "^lumend.service"; then
  if [ "${FORCE}" -eq 0 ]; then
    echo "lumend.service already exists. Use --force to overwrite." >&2
    exit 1
  fi

  CURRENT_STATE="$(systemctl is-active lumend 2>/dev/null || true)"
  if [[ "${CURRENT_STATE}" == "active" || "${CURRENT_STATE}" == "activating" ]]; then
    echo "Existing lumend.service is running (state: ${CURRENT_STATE})."
    echo "Stopping lumend.service gracefully before updating unit..."
    if ! systemctl stop lumend; then
      echo "Warning: 'systemctl stop lumend' returned non-zero; checking service state..." >&2
    fi

    # Wait until the service is no longer active/activating.
    for _ in $(seq 1 30); do
      STATE_NOW="$(systemctl is-active lumend 2>/dev/null || true)"
      if [[ "${STATE_NOW}" != "active" && "${STATE_NOW}" != "activating" ]]; then
        break
      fi
      sleep 1
    done

    STATE_FINAL="$(systemctl is-active lumend 2>/dev/null || true)"
    if [[ "${STATE_FINAL}" == "active" || "${STATE_FINAL}" == "activating" ]]; then
      echo "ERROR: lumend.service did not stop cleanly; aborting." >&2
      exit 1
    fi
    echo "lumend.service is stopped; proceeding with overwrite (--force)."
  else
    echo "Existing lumend.service is not running (state: ${CURRENT_STATE:-unknown})."
    echo "Proceeding with overwrite (--force)."
  fi
elif [ "${FORCE}" -eq 1 ] && [[ "$PRINT_UNIT" -eq 0 ]]; then
  echo "No existing lumend.service found; installing new service (--force)."
fi

UNIT_OUTPUT="/tmp/lumend.service"
if [[ "$PRINT_UNIT" -eq 1 ]]; then
  UNIT_OUTPUT="/dev/stdout"
fi

if [[ "$SERVICE_MODE" == cosmovisor ]]; then
  cat >"$UNIT_OUTPUT" <<EOF
[Unit]
Description=Lumen node (Cosmovisor)
After=network-online.target
Wants=network-online.target

[Service]
User=${RUN_USER}
Environment=DAEMON_NAME=lumend
Environment=DAEMON_HOME=${HOME_DIR}
Environment=DAEMON_ALLOW_DOWNLOAD_BINARIES=false
Environment=DAEMON_RESTART_AFTER_UPGRADE=true
ExecStart=${COSMOVISOR_BIN_PATH} run start --home ${HOME_DIR}
Restart=on-failure
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
elif [ "${IS_SEED_MODE}" -eq 1 ]; then
  cat >"$UNIT_OUTPUT" <<EOF
[Unit]
Description=Lumen node (seed)
After=network-online.target
Wants=network-online.target

[Service]
User=${RUN_USER}
ExecStart=${BIN_PATH} start --home ${HOME_DIR}
Restart=on-failure
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
else
  cat >"$UNIT_OUTPUT" <<EOF
[Unit]
Description=Lumen node
After=network-online.target
Wants=network-online.target

[Service]
User=${RUN_USER}
ExecStart=${BIN_PATH} start --home ${HOME_DIR}
Restart=on-failure
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
fi

if [[ "$PRINT_UNIT" -eq 1 ]]; then
  exit 0
fi

mv "$UNIT_OUTPUT" "${SERVICE_FILE}"
systemctl daemon-reload
systemctl enable lumend
systemctl start lumend

echo "Service installed at ${SERVICE_FILE} and started. Check with: systemctl status lumend"
