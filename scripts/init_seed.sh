#!/usr/bin/env bash
set -euo pipefail

#######################################################################
# Lumen — Seed node init (bootstrap-only P2P node)
#
# Thin wrapper around init_node.sh that forces the seed profile:
#   - p2p.seed_mode = true
#   - RPC disabled in config.toml
#   - tx indexer turned off
#
# Usage:
#   scripts/init_seed.sh <moniker> [--home DIR] [--rpc URL]
#
# All flags are forwarded to init_node.sh; the --seed flag is appended
# automatically so operators don't have to remember it.
#######################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INIT_NODE_SCRIPT="${SCRIPT_DIR}/init_node.sh"

if [[ ! -x "${INIT_NODE_SCRIPT}" ]]; then
  echo "ERROR: init_node.sh not found or not executable at ${INIT_NODE_SCRIPT}" >&2
  exit 1
fi

exec "${INIT_NODE_SCRIPT}" "$@" --seed

