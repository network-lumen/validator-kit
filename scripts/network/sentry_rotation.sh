#!/usr/bin/env bash
set -euo pipefail

############################################################
# Lumen — Experimental sentry rotation helper
#
# Idea:
# - You run two sentry nodes on the same host
#   (or reachable via systemd from this script).
# - At any given time, one is "active" and one is "sleeping".
# - When the active one becomes "overloaded", the script:
#   1) starts the sleeping sentry
#   2) waits for it to catch up
#   3) stops the overloaded one
#   4) swaps roles (new active / new sleeping)
#
# This script is intentionally conservative and requires an
# explicit --apply flag before touching systemd.
#
# Usage (example):
#   sudo deploy/scripts/network/sentry_rotation.sh \
#     --active-service lumen-sentry-a \
#     --sleep-service lumen-sentry-b \
#     --active-rpc http://127.0.0.1:26657 \
#     --sleep-rpc http://127.0.0.1:27657 \
#     --apply
#
# Notes:
# - This is a skeleton: you are expected to tune thresholds,
#   RPC URLs and systemd service names for your setup.
# - It uses peer count from the CometBFT RPC `/net_info` as a
#   crude proxy for "load".
############################################################

ACTIVE_SERVICE=""
SLEEP_SERVICE=""
ACTIVE_RPC=""
SLEEP_RPC=""
APPLY=0
ONCE=0

MAX_PEERS=${MAX_PEERS:-80}        # threshold to consider a sentry "overloaded"
CHECK_INTERVAL=${CHECK_INTERVAL:-60}  # seconds between checks

while [[ $# -gt 0 ]]; do
  case "$1" in
    --active-service) ACTIVE_SERVICE="$2"; shift 2 ;;
    --sleep-service)  SLEEP_SERVICE="$2"; shift 2 ;;
    --active-rpc)     ACTIVE_RPC="$2"; shift 2 ;;
    --sleep-rpc)      SLEEP_RPC="$2"; shift 2 ;;
    --apply)          APPLY=1; shift ;;
    --once)           ONCE=1; shift ;;
    -h|--help)
      echo "Usage: sentry_rotation.sh --active-service NAME --sleep-service NAME --active-rpc URL --sleep-rpc URL [--apply] [--once]"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

if [[ -z "$ACTIVE_SERVICE" || -z "$SLEEP_SERVICE" || -z "$ACTIVE_RPC" || -z "$SLEEP_RPC" ]]; then
  echo "Missing required arguments."
  echo "Usage: sentry_rotation.sh --active-service NAME --sleep-service NAME --active-rpc URL --sleep-rpc URL [--apply] [--once]"
  exit 1
fi

echo "=== Sentry rotation (experimental) ==="
echo "Active service : $ACTIVE_SERVICE ($ACTIVE_RPC)"
echo "Sleep service  : $SLEEP_SERVICE ($SLEEP_RPC)"
echo "Max peers      : $MAX_PEERS"
echo "Apply changes  : $APPLY (0=dry-run, 1=systemd control)"
echo "Single run     : $ONCE (0=loop, 1=run once)"
echo

get_peers() {
  local rpc="$1"
  local res
  res="$(curl -s "$rpc/net_info" || true)"
  if [[ -z "$res" ]]; then
    echo 0
    return
  fi
  echo "$res" | jq -r '.result.n_peers // 0' 2>/dev/null || echo 0
}

get_height() {
  local rpc="$1"
  local res
  res="$(curl -s "$rpc/status" || true)"
  if [[ -z "$res" ]]; then
    echo 0
    return
  fi
  echo "$res" | jq -r '.result.sync_info.latest_block_height // 0' 2>/dev/null || echo 0
}

start_service() {
  local svc="$1"
  if (( APPLY == 1 )); then
    systemctl start "$svc"
  else
    echo "[dry-run] systemctl start $svc"
  fi
}

stop_service() {
  local svc="$1"
  if (( APPLY == 1 )); then
    systemctl stop "$svc"
  else
    echo "[dry-run] systemctl stop $svc"
  fi
}

rotate_once() {
  local a_svc="$1" a_rpc="$2" s_svc="$3" s_rpc="$4"

  local peers_active height_active
  peers_active="$(get_peers "$a_rpc")"
  height_active="$(get_height "$a_rpc")"

  echo "[info] Active $a_svc: peers=$peers_active height=$height_active"

  if (( peers_active <= MAX_PEERS )); then
    echo "[info] Below peer threshold ($MAX_PEERS), no rotation."
    return 0
  fi

  echo "[warn] $a_svc peers=$peers_active exceeds $MAX_PEERS → starting $s_svc"
  start_service "$s_svc"

  echo "[info] Waiting for $s_svc to catch up..."
  while true; do
    local height_sleep
    height_sleep="$(get_height "$s_rpc")"
    echo "  heights: active=$height_active sleep=$height_sleep"

    if (( height_sleep >= height_active - 1 && height_sleep > 0 )); then
      echo "[info] $s_svc caught up, stopping $a_svc"
      stop_service "$a_svc"
      break
    fi

    sleep 10
    height_active="$(get_height "$a_rpc")"
  done

  echo "[info] Rotation step complete (roles will be swapped on next loop)."
}

while true; do
  rotate_once "$ACTIVE_SERVICE" "$ACTIVE_RPC" "$SLEEP_SERVICE" "$SLEEP_RPC"

  # Swap roles for the next iteration
  tmp_svc="$ACTIVE_SERVICE"
  tmp_rpc="$ACTIVE_RPC"
  ACTIVE_SERVICE="$SLEEP_SERVICE"
  ACTIVE_RPC="$SLEEP_RPC"
  SLEEP_SERVICE="$tmp_svc"
  SLEEP_RPC="$tmp_rpc"

  if (( ONCE == 1 )); then
    echo "[info] Single-run mode enabled, exiting."
    break
  fi

  echo "[info] Next check in ${CHECK_INTERVAL}s"
  sleep "$CHECK_INTERVAL"
done
