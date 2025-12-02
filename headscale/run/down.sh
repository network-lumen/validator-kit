#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HEADSCALE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$HEADSCALE_DIR"

if docker compose version >/dev/null 2>&1; then
  COMPOSE_CMD=(docker compose)
elif docker-compose version >/dev/null 2>&1; then
  COMPOSE_CMD=(docker-compose)
else
  echo "docker compose / docker-compose not found in PATH"
  exit 1
fi

echo "Stopping Headscale (docker-compose) from $HEADSCALE_DIR"
"${COMPOSE_CMD[@]}" down
