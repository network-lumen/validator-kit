#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLI="$REPO_ROOT/scripts/lumen-node"

help_output="$(cd /tmp && "$CLI" --help)"
grep -q "deploy <moniker>" <<< "$help_output"
grep -q "upgrade prepare" <<< "$help_output"
deploy_help="$($CLI deploy --help)"
grep -q "Usage: ./scripts/lumen-node deploy <moniker>" <<< "$deploy_help"

if "$CLI" deploy --role seed >/tmp/lumen-node-missing-moniker 2>&1; then
  echo "missing moniker was accepted" >&2
  exit 1
fi
grep -q "lumen-node deploy requires" /tmp/lumen-node-missing-moniker
if "$CLI" deploy node --role invalid >/dev/null 2>&1; then
  echo "invalid role was accepted" >&2
  exit 1
fi
if "$CLI" deploy node --service-mode invalid >/dev/null 2>&1; then
  echo "invalid service mode was accepted" >&2
  exit 1
fi
if "$CLI" deploy node --network invalid >/dev/null 2>&1; then
  echo "invalid network was accepted" >&2
  exit 1
fi
if "$CLI" deploy node --network testnet >/dev/null 2>&1; then
  echo "incomplete testnet was accepted" >&2
  exit 1
fi

grep -q "Usage: ./scripts/lumen-node snapshot" <("$CLI" snapshot --help)
grep -q "Usage: ./scripts/lumen-node upgrade" <("$CLI" help upgrade)
grep -q "Usage: ./scripts/lumen-node backup export" <("$CLI" backup --help)
grep -q "Usage: ./scripts/doctor.sh" <("$CLI" doctor --help)

if "$CLI" unknown-command >/dev/null 2>&1; then
  echo "unknown command was accepted" >&2
  exit 1
fi
if "$CLI" snapshot unknown >/dev/null 2>&1; then
  echo "unknown snapshot subcommand was accepted" >&2
  exit 1
fi
if "$CLI" upgrade prepare --name bad/name --version v1.0.0 >/dev/null 2>&1; then
  echo "underlying upgrade failure was swallowed" >&2
  exit 1
fi

version_output="$("$CLI" version)"
grep -q "lumen-node (validator-kit" <<< "$version_output"

echo "cli regression: passed"
