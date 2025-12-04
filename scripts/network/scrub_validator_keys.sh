#!/usr/bin/env bash
set -euo pipefail

############################################################
# Lumen — Scrub validator signing keys from this host
#
# Goal:
#   - keep the node able to run as a validator / fullnode
#     (CometBFT consensus key + node_id stay on disk)
#   - remove local account / PQC keys so this machine
#     cannot create Cosmos TXs (send, vote, etc.)
#
# What this script can remove:
#   - $HOME/.lumen/keyring-*    (Cosmos account keys)
#   - $HOME/.lumen/pqc_keys     (PQC keystore)
#   - optionally local backups: first-node.bak, join-node.bak
#   - optionally shell history (~/.bash_history)
#
# It does NOT touch:
#   - $HOME/.lumen/config/priv_validator_key.json
#   - $HOME/.lumen/config/node_key.json
#
# Run this only after you have safely exported / backed up
# your mnemonic + PQC keys to an offline location.
############################################################

usage() {
  cat <<EOF
Usage: $(basename "$0") [--home DIR] [--include-backups] [--wipe-history] [--yes]

Options:
  --home DIR          Lumen home directory (default: \$HOME/.lumen).
  --include-backups   Also delete local backups (first-node.bak, join-node.bak).
  --wipe-history      Truncate ~/.bash_history for the current user.
  --yes               Do not prompt for confirmation (non-interactive).
  -h, --help          Show this help and exit.

This is meant for hardened validator hosts where:
  - all signing keys are stored offline, and
  - the node only runs the consensus engine and relays blocks.
EOF
}

HOME_DIR="${HOME}/.lumen"
INCLUDE_BACKUPS=0
WIPE_HISTORY=0
ASSUME_YES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --home)
      [[ $# -ge 2 ]] || { echo "Missing value for --home"; usage; exit 1; }
      HOME_DIR="$2"
      shift
      ;;
    --include-backups)
      INCLUDE_BACKUPS=1
      ;;
    --wipe-history)
      WIPE_HISTORY=1
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

echo "=== Lumen validator key scrub ==="
echo "Home directory      : $HOME_DIR"
echo "Include backups     : $INCLUDE_BACKUPS"
echo "Wipe shell history  : $WIPE_HISTORY"
echo

if [[ ! -d "$HOME_DIR" ]]; then
  echo "❌ Home directory not found: $HOME_DIR"
  exit 1
fi

TARGETS=()

# keyring-* (account keys)
for d in "$HOME_DIR"/keyring-*; do
  [[ -d "$d" ]] && TARGETS+=("$d")
done

# PQC keystore
if [[ -d "$HOME_DIR/pqc_keys" ]]; then
  TARGETS+=("$HOME_DIR/pqc_keys")
fi

if [[ "$INCLUDE_BACKUPS" -eq 1 ]]; then
  for d in "$HOME_DIR/first-node.bak" "$HOME_DIR/join-node.bak"; do
    [[ -d "$d" ]] && TARGETS+=("$d")
  done
fi

if [[ "${#TARGETS[@]}" -eq 0 ]]; then
  echo "ℹ No keyring/pqc/backups directories found to remove under $HOME_DIR"
else
  echo "The following directories will be permanently deleted:"
  for t in "${TARGETS[@]}"; do
    echo "  - $t"
  done
  echo
fi

if [[ "$WIPE_HISTORY" -eq 1 ]]; then
  echo "Shell history (~/.bash_history) will be truncated."
fi

if [[ "$ASSUME_YES" -ne 1 ]]; then
  read -rp "Proceed with deletion? [y/N] " ANSWER
  ANSWER="${ANSWER:-N}"
  if [[ ! "$ANSWER" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
  fi
fi

for t in "${TARGETS[@]}"; do
  echo "Removing $t ..."
  rm -rf "$t"
done

if [[ "$WIPE_HISTORY" -eq 1 ]]; then
  if [[ -f "${HOME}/.bash_history" ]]; then
    : > "${HOME}/.bash_history"
    echo "✔ Truncated ${HOME}/.bash_history"
  fi
fi

echo "✔ Scrub completed. Consensus keys (priv_validator_key.json) and node_id"
echo "  have NOT been touched, so this node can still participate in the network,"
echo "  but it no longer holds local account/PQC keys to create TXs."

