#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

DEFAULT_BIN="${REPO_ROOT}/bin/lumend"

if [[ -x "${DEFAULT_BIN}" ]]; then
  LUMEN_BIN="${DEFAULT_BIN}"
elif command -v lumend >/dev/null 2>&1; then
  LUMEN_BIN="$(command -v lumend)"
else
  echo "ERROR: lumend binary not found. Expected at ${DEFAULT_BIN} or in PATH." >&2
  exit 1
fi

validators_data="$("${LUMEN_BIN}" q staking validators -o json)"

# Calculate the total voting power
total_vp=$(echo "$validators_data" | jq '[.validators[].tokens | tonumber] | add')

# Loop through each validator and calculate the percentage
echo "$validators_data" | jq -r '.validators[] | "\(.description.moniker) \(.tokens)"' | while read -r moniker vp; do
    percentage=$(echo "scale=4; $vp * 100 / $total_vp" | bc -l)
    printf "%-10s: %10d ulmn (%6.2f%%)\n" "$moniker" "$vp" "$percentage"
done
