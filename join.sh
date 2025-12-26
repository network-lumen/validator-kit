#!/usr/bin/env bash
set -euo pipefail

# Lumen – simple entrypoint to join the network
# Usage: ./join.sh <moniker> [--home DIR] [--rpc URL] [--public-api]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPS_ROOT="${SCRIPT_DIR}/ops"

INIT_NODE="${OPS_ROOT}/scripts/init_node.sh"
if [[ ! -x "${INIT_NODE}" ]]; then
  echo "ERROR: init_node.sh not found at ${INIT_NODE}" >&2
  exit 1
fi

exec "${INIT_NODE}" "$@"
