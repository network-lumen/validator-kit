#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Install + configure Prometheus node_exporter as a systemd service.
# - Downloads official binary from GitHub
# - Installs to /usr/local/bin/node_exporter
# - Creates user node_exporter
# - Creates and enables node_exporter.service
# Default listen address: 0.0.0.0:9100 (reachable from Tailscale / LAN)
#
# Usage (on validator / sentry host):
#   sudo deploy/scripts/install/node_exporter_service.sh
###############################################################################

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root (use sudo)." >&2
  exit 1
fi

DEFAULT_VERSION="1.8.2"
echo
echo "=== Node Exporter Installer ==="
echo

read -p "Node Exporter version? (${DEFAULT_VERSION}): " VERSION
VERSION=${VERSION:-$DEFAULT_VERSION}

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)  ARCH_TAG="amd64" ;;
  aarch64) ARCH_TAG="arm64" ;;
  armv7l)  ARCH_TAG="armv7" ;;
  *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

read -p "Listen address? (0.0.0.0:9100): " LISTEN_ADDR
LISTEN_ADDR="${LISTEN_ADDR:-0.0.0.0:9100}"

echo
echo "Version      : $VERSION"
echo "Architecture : $ARCH ($ARCH_TAG)"
echo "Listen addr  : $LISTEN_ADDR"
echo

TMP_DIR="$(mktemp -d)"
FILENAME="node_exporter-${VERSION}.linux-${ARCH_TAG}.tar.gz"
URL="https://github.com/prometheus/node_exporter/releases/download/v${VERSION}/${FILENAME}"

echo "[1/4] Downloading node_exporter from:"
echo "      $URL"
echo

(
  cd "$TMP_DIR"
  curl -fL "$URL" -o "$FILENAME"
  tar -xzf "$FILENAME"
)

BIN_SRC="$(find "$TMP_DIR" -maxdepth 2 -type f -name 'node_exporter' | head -n1)"
if [[ -z "$BIN_SRC" ]]; then
  echo "Failed to find node_exporter binary in archive." >&2
  rm -rf "$TMP_DIR"
  exit 1
fi

echo "[2/4] Installing binary to /usr/local/bin/node_exporter"
install -m 0755 "$BIN_SRC" /usr/local/bin/node_exporter

if ! id -u node_exporter >/dev/null 2>&1; then
  echo "[3/4] Creating user 'node_exporter'"
  useradd --system --no-create-home --shell /usr/sbin/nologin node_exporter
fi

SERVICE_FILE="/etc/systemd/system/node_exporter.service"
echo "[4/4] Writing systemd service to $SERVICE_FILE"

cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=Prometheus Node Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter \\
  --web.listen-address=$LISTEN_ADDR
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now node_exporter

rm -rf "$TMP_DIR"

echo
echo "=== Installation complete ==="
echo "Service: node_exporter"
echo "Listen : $LISTEN_ADDR"
echo
echo "Check status:"
echo "  systemctl status node_exporter"
echo
echo "Prometheus scrape example (prod):"
echo "  - job_name: \"node\""
echo "    static_configs:"
echo "      - targets:"
echo "          - \"<validator-host>:9100\""
echo "          - \"<sentry-a-host>:9100\""
echo "          - \"<sentry-b-host>:9100\""
