#!/usr/bin/env bash
# Create and start a systemd service for an existing lumend home.
# Usage: sudo bash launch_service.sh [--force] [HOME_DIR] [USER]
#
# - HOME_DIR defaults to /root/.lumen
# - USER defaults to root

set -euo pipefail

FORCE=0
if [ "${1:-}" = "--force" ]; then
  FORCE=1
  shift
fi

HOME_DIR="${1:-/root/.lumen}"
RUN_USER="${2:-root}"
BIN_PATH="/usr/local/bin/lumend"
SERVICE_FILE="/etc/systemd/system/lumend.service"
RPC_LADDR="${RPC_LADDR:-tcp://0.0.0.0:26657}"
P2P_LADDR="${P2P_LADDR:-tcp://0.0.0.0:26656}"
API_ADDR="${API_ADDR:-tcp://0.0.0.0:1317}"
GRPC_ADDR="${GRPC_ADDR:-0.0.0.0:9090}"

if [ ! -x "${BIN_PATH}" ]; then
  echo "lumend binary not found at ${BIN_PATH}. Install it first." >&2
  exit 1
fi

if [ ! -d "${HOME_DIR}" ]; then
  echo "Home directory ${HOME_DIR} not found. Run bootstrap first." >&2
  exit 1
fi

if systemctl list-unit-files | grep -q "^lumend.service"; then
  if [ "${FORCE}" -eq 1 ]; then
    echo "Stopping existing lumend.service (force)..."
    systemctl stop lumend >/dev/null 2>&1 || true
    systemctl disable lumend >/dev/null 2>&1 || true
    systemctl reset-failed lumend >/dev/null 2>&1 || true
    pkill -f "${BIN_PATH} start" >/dev/null 2>&1 || true
    pkill -f "/root/validator-kit/bin/lumend start" >/dev/null 2>&1 || true
    pkill -f "lumend start" >/dev/null 2>&1 || true
    pkill -f "lumend" >/dev/null 2>&1 || true
    rm -f "${SERVICE_FILE}"
    rm -f "/etc/systemd/system/multi-user.target.wants/lumend.service"
    systemctl daemon-reload
  else
    echo "lumend.service already exists. Use --force to overwrite." >&2
    exit 1
  fi
fi

cat >/tmp/lumend.service <<EOF
[Unit]
Description=Lumen node
After=network-online.target
Wants=network-online.target

[Service]
User=${RUN_USER}
ExecStart=${BIN_PATH} start --home ${HOME_DIR} \\
  --rpc.laddr ${RPC_LADDR} \\
  --p2p.laddr ${P2P_LADDR} \\
  --api.enable \\
  --api.address ${API_ADDR} \\
  --grpc.address ${GRPC_ADDR} \\
  --minimum-gas-prices 0ulmn
Restart=on-failure
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

mv /tmp/lumend.service "${SERVICE_FILE}"
systemctl daemon-reload
systemctl enable lumend
systemctl restart lumend

echo "Service installed at ${SERVICE_FILE} and started. Check with: systemctl status lumend"
