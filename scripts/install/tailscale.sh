#!/usr/bin/env bash
set -euo pipefail

# Install and configure Tailscale for a node.
# - Installs tailscaled (Debian/Ubuntu via official script) if missing
# - Enables and starts the tailscaled systemd service
# - Optionally runs `tailscale up` with your Headscale URL and auth key
#
# Usage (from deploy/):
#   sudo scripts/install/tailscale.sh \
#     --login-server https://lmn-ops.cloud \
#     --authkey tskey-xxxxxxxx \
#     --hostname validator-1
#
# Flags:
#   --login-server URL   Headscale/Tailscale control plane URL (required for `tailscale up`)
#   --authkey KEY        Pre-auth key from Headscale (`validator=...` or `sentry1=...`)
#   --hostname NAME      Optional hostname to register for this node
#   --no-up              Install tailscale but skip `tailscale up`
#

if [[ "$EUID" -ne 0 ]]; then
  echo "ERROR: this installer must be run as root (sudo)." >&2
  echo "Re-run it with: sudo scripts/install/tailscale.sh [...flags]" >&2
  exit 1
fi

LOGIN_SERVER=""
AUTHKEY=""
HOSTNAME=""
RUN_UP=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --login-server)
      LOGIN_SERVER="$2"; shift 2 ;;
    --authkey)
      AUTHKEY="$2"; shift 2 ;;
    --hostname)
      HOSTNAME="$2"; shift 2 ;;
    --no-up)
      RUN_UP=0; shift ;;
    -h|--help)
      sed -n '1,80p' "$0"
      exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1 ;;
  esac
done

echo "=== Tailscale installer ==="

if ! command -v tailscaled >/dev/null 2>&1; then
  echo "[1/3] tailscaled not found, installing via official script..."
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
  fi

  case "${ID:-}" in
    ubuntu|debian)
      curl -fsSL https://tailscale.com/install.sh | sh ;;
    *)
      echo "Unsupported distro ID='${ID:-unknown}'. Install Tailscale manually from:" >&2
      echo "  https://tailscale.com/download" >&2
      exit 1 ;;
  esac
else
  echo "[1/3] tailscaled already installed."
fi

echo "[2/3] Enabling and starting tailscaled.service..."
systemctl enable tailscaled >/dev/null 2>&1 || true
systemctl start tailscaled

if [[ "$RUN_UP" -eq 0 ]]; then
  echo "[3/3] Skipping 'tailscale up' (per --no-up)."
  echo "You can join later with:"
  echo "  sudo tailscale up --login-server <URL> --authkey <KEY> [--hostname <NAME>]"
  exit 0
fi

if [[ -z "$LOGIN_SERVER" || -z "$AUTHKEY" ]]; then
  echo "[3/3] LOGIN_SERVER or AUTHKEY not provided; not running 'tailscale up'." >&2
  echo "Example:" >&2
  echo "  sudo scripts/install/tailscale.sh \\" >&2
  echo "    --login-server https://lmn-ops.cloud \\" >&2
  echo "    --authkey tskey-xxxxxxxx \\" >&2
  echo "    --hostname validator-1" >&2
  exit 1
fi

echo "[3/3] Running 'tailscale up' against ${LOGIN_SERVER}..."

ARGS=(--login-server "$LOGIN_SERVER" --authkey "$AUTHKEY")
if [[ -n "$HOSTNAME" ]]; then
  ARGS+=(--hostname "$HOSTNAME")
fi

# Do not echo the authkey to the terminal.
tailscale up "${ARGS[@]}"

echo
echo "✅ Tailscale installed and node joined to: $LOGIN_SERVER"

