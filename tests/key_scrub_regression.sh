#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT

HOME_DIR="$FIXTURE/home/.lumen"
mkdir -p "$HOME_DIR" \
  "$HOME_DIR/keyring-file" \
  "$HOME_DIR/pqc_keys" \
  "$HOME_DIR/first-node.bak" \
  "$HOME_DIR/validator-node.bak" \
  "$HOME_DIR/join-node.bak" \
  "$HOME_DIR/config"
printf 'keep\n' > "$HOME_DIR/config/priv_validator_key.json"
printf 'keep\n' > "$HOME_DIR/config/node_key.json"

help_output="$($REPO_ROOT/scripts/network/scrub_validator_keys.sh --help)"
grep -q 'first-node.bak, validator-node.bak, join-node.bak' <<< "$help_output"

HOME="$FIXTURE/home" "$REPO_ROOT/scripts/network/scrub_validator_keys.sh" \
  --home "$HOME_DIR" --include-backups --yes >/dev/null

for removed in keyring-file pqc_keys first-node.bak validator-node.bak join-node.bak; do
  [[ ! -e "$HOME_DIR/$removed" ]]
done
[[ -f "$HOME_DIR/config/priv_validator_key.json" ]]
[[ -f "$HOME_DIR/config/node_key.json" ]]

echo "key scrub regression: passed"
