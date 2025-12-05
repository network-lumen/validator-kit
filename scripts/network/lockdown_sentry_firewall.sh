#!/usr/bin/env bash
set -euo pipefail

############################################################
# Lumen — Lock down sentry firewall (iptables)
#
# This helper is intended to run on a sentry/fullnode host.
# It:
#   - sets default DROP for INPUT/FORWARD (IPv4 + IPv6)
#   - allows established/related traffic
#   - allows loopback
#   - allows SSH on the Tailscale interface only (by default)
#   - allows P2P (26656) from the public Internet
#   - allows Prometheus (26660) + Grafana (3000) only on Tailscale
#   - leaves OUTPUT fully open
#
# After running this once, the sentry should:
#   - be reachable publicly only on its P2P port
#   - expose metrics + Grafana only over Headscale/Tailscale
############################################################

usage() {
  cat <<EOF
Usage: $(basename "$0") [--tailscale-if IFACE] [--p2p-port PORT] [--metrics-port PORT] [--grafana-port PORT] [--ssh-port PORT] [--yes]

Options:
  --tailscale-if IFACE  Tailscale interface name (default: auto-detect tailscale0/ts0)
  --p2p-port PORT       P2P port to allow from Internet (default: 26656)
  --metrics-port PORT   Prometheus /metrics port to allow on Tailscale (default: 26660)
  --grafana-port PORT   Grafana HTTP port to allow on Tailscale (default: 3000)
  --ssh-port PORT       SSH port to allow on Tailscale (default: 22)
  --yes                 Do not prompt for confirmation (non-interactive)
  -h, --help            Show this help and exit.

Note: This script configures iptables/ip6tables runtime rules. To make them
      persistent across reboots, install and use a persistence mechanism
      such as 'iptables-persistent' or 'netfilter-persistent' on Ubuntu.
EOF
}

if [[ "$EUID" -ne 0 ]]; then
  echo "ERROR: this script must be run as root (sudo)." >&2
  exit 1
fi

TAIL_IF=""
P2P_PORT=26656
METRICS_PORT=26660
GRAFANA_PORT=3000
SSH_PORT=22
ASSUME_YES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tailscale-if)
      [[ $# -ge 2 ]] || { echo "Missing value for --tailscale-if"; usage; exit 1; }
      TAIL_IF="$2"; shift
      ;;
    --p2p-port)
      [[ $# -ge 2 ]] || { echo "Missing value for --p2p-port"; usage; exit 1; }
      P2P_PORT="$2"; shift
      ;;
    --metrics-port)
      [[ $# -ge 2 ]] || { echo "Missing value for --metrics-port"; usage; exit 1; }
      METRICS_PORT="$2"; shift
      ;;
    --grafana-port)
      [[ $# -ge 2 ]] || { echo "Missing value for --grafana-port"; usage; exit 1; }
      GRAFANA_PORT="$2"; shift
      ;;
    --ssh-port)
      [[ $# -ge 2 ]] || { echo "Missing value for --ssh-port"; usage; exit 1; }
      SSH_PORT="$2"; shift
      ;;
    --yes)
      ASSUME_YES=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: \$1"
      usage
      exit 1
      ;;
  esac
  shift
done

if [[ -z "$TAIL_IF" ]]; then
  TAIL_IF="$(ip -o link show | awk -F': ' '/tailscale0|ts0/ {print $2; exit}')"
fi

if [[ -z "$TAIL_IF" ]]; then
  echo "ERROR: could not auto-detect Tailscale interface (tailscale0/ts0)." >&2
  echo "       Use --tailscale-if IFACE to specify it explicitly." >&2
  exit 1
fi

echo "=== Lumen sentry firewall lockdown ==="
echo "Tailscale interface : $TAIL_IF"
echo "P2P port (public)   : $P2P_PORT"
echo "Metrics port (ts)   : $METRICS_PORT"
echo "Grafana port (ts)   : $GRAFANA_PORT"
echo "SSH port (ts)       : $SSH_PORT"
echo
echo "Planned rules (IPv4 + IPv6):"
echo "  - Default INPUT/FORWARD DROP, OUTPUT ACCEPT"
echo "  - Allow ESTABLISHED,RELATED"
echo "  - Allow loopback (lo)"
echo "  - Allow SSH on $TAIL_IF:$SSH_PORT"
echo "  - Allow P2P on all interfaces (port $P2P_PORT)"
echo "  - Allow Prometheus on $TAIL_IF:$METRICS_PORT"
echo "  - Allow Grafana on $TAIL_IF:$GRAFANA_PORT"
echo

if [[ "$ASSUME_YES" -ne 1 ]]; then
  read -rp "Apply these iptables/ip6tables rules now? [y/N] " ANSWER
  ANSWER="${ANSWER:-N}"
  if [[ ! "$ANSWER" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
  fi
fi

BACKUP_DATE="$(date +%Y%m%d_%H%M%S)"

echo "Backing up existing rules..."
iptables-save  >"/root/iptables-backup-sentry-${BACKUP_DATE}.v4"  || true
ip6tables-save >"/root/ip6tables-backup-sentry-${BACKUP_DATE}.v6" || true

echo "Applying IPv4 rules..."

iptables -F
iptables -X
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

# Loopback
iptables -A INPUT -i lo -j ACCEPT

# Established / related
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# SSH on Tailscale only
iptables -A INPUT -i "$TAIL_IF" -p tcp --dport "$SSH_PORT" -j ACCEPT

# P2P from anywhere (public node)
iptables -A INPUT -p tcp --dport "$P2P_PORT" -j ACCEPT

# Metrics + Grafana only over Tailscale
iptables -A INPUT -i "$TAIL_IF" -p tcp --dport "$METRICS_PORT" -j ACCEPT
iptables -A INPUT -i "$TAIL_IF" -p tcp --dport "$GRAFANA_PORT" -j ACCEPT

echo "Applying IPv6 rules..."

ip6tables -F
ip6tables -X
ip6tables -P INPUT DROP
ip6tables -P FORWARD DROP
ip6tables -P OUTPUT ACCEPT

ip6tables -A INPUT -i lo -j ACCEPT
ip6tables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

ip6tables -A INPUT -i "$TAIL_IF" -p tcp --dport "$SSH_PORT" -j ACCEPT
ip6tables -A INPUT -p tcp --dport "$P2P_PORT" -j ACCEPT
ip6tables -A INPUT -i "$TAIL_IF" -p tcp --dport "$METRICS_PORT" -j ACCEPT
ip6tables -A INPUT -i "$TAIL_IF" -p tcp --dport "$GRAFANA_PORT" -j ACCEPT

echo "✔ Sentry firewall rules applied."
echo "Backups:"
echo "  /root/iptables-backup-sentry-${BACKUP_DATE}.v4"
echo "  /root/ip6tables-backup-sentry-${BACKUP_DATE}.v6"
echo
echo "Note: Grafana and Prometheus are now only reachable over Tailscale."
echo "      To persist these rules across reboots, save them with an"
echo "      iptables persistence tool on your distribution."
