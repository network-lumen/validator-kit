#!/usr/bin/env bash
set -euo pipefail

############################################################
# Lumen — Lock down RPC/API node firewall (iptables)
#
# This helper is intended to run on a dedicated RPC/API fullnode host.
# It:
#   - sets default DROP for INPUT/FORWARD (IPv4 + IPv6)
#   - allows established/related traffic
#   - allows loopback
#   - allows SSH on the Tailscale interface only (by default)
#   - allows P2P (26656) from the public Internet
#   - allows CometBFT RPC (26657), REST API (1317) and gRPC (9090)
#     from the public Internet
#   - optionally allows Prometheus metrics (26660) only on Tailscale
#   - leaves OUTPUT fully open
#
# After running this once, the RPC node should:
#   - be reachable publicly only on its P2P + RPC/API/gRPC ports
#   - expose metrics only over Headscale/Tailscale (if enabled)
#
# WARNING (Docker):
#   - This script flushes and recreates INPUT/FORWARD chains for iptables/ip6tables.
#   - On hosts where Docker is already running, this also removes Docker's own
#     filter chains (e.g. the DOCKER chain used for published ports).
#   - After applying this script on a host with running containers, you should:
#       * restart Docker:   systemctl restart docker
#       * then restart any docker-compose stacks.
############################################################

usage() {
  cat <<EOF
Usage: $(basename "$0") [--tailscale-if IFACE] [--p2p-port PORT] [--rpc-port PORT] [--api-port PORT] [--grpc-port PORT] [--metrics-port PORT] [--ssh-port PORT] [--yes]

Options:
  --tailscale-if IFACE  Tailscale interface name (default: auto-detect tailscale0/ts0)
  --p2p-port PORT       P2P port to allow from Internet (default: 26656)
  --rpc-port PORT       CometBFT RPC port to allow from Internet (default: 26657)
  --api-port PORT       REST API port to allow from Internet (default: 1317)
  --grpc-port PORT      gRPC port to allow from Internet (default: 9090)
  --metrics-port PORT   Prometheus /metrics port to allow on Tailscale (default: 26660, 0 = disabled)
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
RPC_PORT=26657
API_PORT=1317
GRPC_PORT=9090
METRICS_PORT=26660
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
    --rpc-port)
      [[ $# -ge 2 ]] || { echo "Missing value for --rpc-port"; usage; exit 1; }
      RPC_PORT="$2"; shift
      ;;
    --api-port)
      [[ $# -ge 2 ]] || { echo "Missing value for --api-port"; usage; exit 1; }
      API_PORT="$2"; shift
      ;;
    --grpc-port)
      [[ $# -ge 2 ]] || { echo "Missing value for --grpc-port"; usage; exit 1; }
      GRPC_PORT="$2"; shift
      ;;
    --metrics-port)
      [[ $# -ge 2 ]] || { echo "Missing value for --metrics-port"; usage; exit 1; }
      METRICS_PORT="$2"; shift
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
      echo "Unknown option: $1"
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

echo "=== Lumen RPC/API node firewall lockdown ==="
echo "Tailscale interface : $TAIL_IF"
echo "P2P port (public)   : $P2P_PORT"
echo "RPC port (public)   : $RPC_PORT"
echo "API port (public)   : $API_PORT"
echo "gRPC port (public)  : $GRPC_PORT"
if [[ "$METRICS_PORT" -ne 0 ]]; then
  echo "Metrics port (ts)   : $METRICS_PORT"
else
  echo "Metrics port (ts)   : disabled"
fi
echo "SSH port (ts)       : $SSH_PORT"
echo
echo "Planned rules (IPv4 + IPv6):"
echo "  - Default INPUT/FORWARD DROP, OUTPUT ACCEPT"
echo "  - Allow ESTABLISHED,RELATED"
echo "  - Allow loopback (lo)"
echo "  - Allow SSH on $TAIL_IF:$SSH_PORT"
echo "  - Allow P2P on all interfaces (port $P2P_PORT)"
echo "  - Allow CometBFT RPC on all interfaces (port $RPC_PORT)"
echo "  - Allow REST API on all interfaces (port $API_PORT)"
echo "  - Allow gRPC on all interfaces (port $GRPC_PORT)"
if [[ "$METRICS_PORT" -ne 0 ]]; then
  echo "  - Allow Prometheus metrics on $TAIL_IF:$METRICS_PORT"
fi
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
iptables-save  >"/root/iptables-backup-rpc-${BACKUP_DATE}.v4"  || true
ip6tables-save >"/root/ip6tables-backup-rpc-${BACKUP_DATE}.v6" || true

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

# Public P2P, RPC, API, gRPC
iptables -A INPUT -p tcp --dport "$P2P_PORT" -j ACCEPT
iptables -A INPUT -p tcp --dport "$RPC_PORT" -j ACCEPT
iptables -A INPUT -p tcp --dport "$API_PORT" -j ACCEPT
iptables -A INPUT -p tcp --dport "$GRPC_PORT" -j ACCEPT

# Metrics only over Tailscale (optional)
if [[ "$METRICS_PORT" -ne 0 ]]; then
  iptables -A INPUT -i "$TAIL_IF" -p tcp --dport "$METRICS_PORT" -j ACCEPT
fi

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
ip6tables -A INPUT -p tcp --dport "$RPC_PORT" -j ACCEPT
ip6tables -A INPUT -p tcp --dport "$API_PORT" -j ACCEPT
ip6tables -A INPUT -p tcp --dport "$GRPC_PORT" -j ACCEPT

if [[ "$METRICS_PORT" -ne 0 ]]; then
  ip6tables -A INPUT -i "$TAIL_IF" -p tcp --dport "$METRICS_PORT" -j ACCEPT
fi

echo "✔ RPC/API node firewall rules applied."
echo "Backups:"
echo "  /root/iptables-backup-rpc-${BACKUP_DATE}.v4"
echo "  /root/ip6tables-backup-rpc-${BACKUP_DATE}.v6"
echo
echo "Note: RPC/API and P2P ports are now reachable from the Internet; SSH and metrics"
echo "      are only reachable over Tailscale. To persist these rules across reboots,"
echo "      save them with an iptables persistence tool on your distribution."
echo
echo "If this host runs Docker services, you should restart Docker and then any"
echo "docker-compose stacks so that Docker can recreate its iptables chains and"
echo "published ports:"
echo "  systemctl restart docker"
echo "  # then in each stack directory:"
echo "  docker-compose down && docker-compose up -d"

