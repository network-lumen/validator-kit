#!/usr/bin/env bash
# Create and start a systemd service for an existing lumend home.
# Usage: sudo scripts/install/lumend_service.sh [--force] [HOME_DIR] [USER]
#
# - If you omit HOME_DIR / USER, they default to the user that ran sudo
#   (or root if there is no sudo context).

set -euo pipefail

if [[ "$EUID" -ne 0 ]]; then
  echo "ERROR: this installer needs root privileges (sudo)."
  echo "Re-run it with: sudo scripts/install/lumend_service.sh [--force] [HOME_DIR] [USER]"
  exit 1
fi

FORCE=0
if [ "${1:-}" = "--force" ]; then
  FORCE=1
  shift
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
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
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

# If a preferred binary path is provided via environment, reuse it and
# avoid prompting the operator a second time. Fallback to the usual
# interactive prompt only when we cannot resolve a candidate.
PREFERRED_BIN="${LUMEND_BIN:-${LUMEN_TARGET:-}}"
if [[ -n "${PREFERRED_BIN}" ]]; then
  BIN_PATH="${PREFERRED_BIN}"
  echo "Using lumend binary from environment: ${BIN_PATH}"
else
  read -p "Path to lumend binary? (${DEFAULT_BIN}): " BIN_PATH
  BIN_PATH="${BIN_PATH:-$DEFAULT_BIN}"
fi

SERVICE_FILE="/etc/systemd/system/lumend.service"
if [ ! -x "${BIN_PATH}" ]; then
  echo "lumend binary not found or not executable at ${BIN_PATH}." >&2
  echo "Install it or rerun this script and point to the correct path." >&2
  exit 1
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

if systemctl list-unit-files | grep -q "^lumend.service"; then
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
elif [ "${FORCE}" -eq 1 ]; then
  echo "No existing lumend.service found; installing new service (--force)."
fi

if [ "${IS_SEED_MODE}" -eq 1 ]; then
  cat >/tmp/lumend.service <<EOF
[Unit]
Description=Lumen node (seed)
After=network-online.target
Wants=network-online.target

[Service]
User=${RUN_USER}
ExecStart=${BIN_PATH} start --home ${HOME_DIR} \\
  --minimum-gas-prices 0ulmn
Restart=on-failure
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
else
  cat >/tmp/lumend.service <<EOF
[Unit]
Description=Lumen node
After=network-online.target
Wants=network-online.target

[Service]
User=${RUN_USER}
# Keep network-facing listeners in app.toml/config.toml so each role
# (validator, fullnode, rpc) retains its intended exposure profile.
ExecStart=${BIN_PATH} start --home ${HOME_DIR} \\
  --minimum-gas-prices 0ulmn
Restart=on-failure
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
fi

mv /tmp/lumend.service "${SERVICE_FILE}"
systemctl daemon-reload
systemctl enable lumend
systemctl start lumend

echo "Service installed at ${SERVICE_FILE} and started. Check with: systemctl status lumend"
