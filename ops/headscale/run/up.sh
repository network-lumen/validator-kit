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

if [[ -f ".env" ]]; then
  echo "Using environment overrides from .env"
else
  echo "No .env found, using default ports (8080, 50443, 9090)"
  echo "To customize, copy .env.example to .env and edit."
fi

echo "Starting Headscale (docker-compose) from $HEADSCALE_DIR"
"${COMPOSE_CMD[@]}" up -d headscale

echo
echo "Headscale should now be running."
if [[ -f ".env" ]]; then
  echo "Control URL (from .env HEADSCALE_SERVER_URL):"
  grep -E '^HEADSCALE_SERVER_URL=' .env || echo "HEADSCALE_SERVER_URL not set in .env."
else
  echo "Default control URL: http://127.0.0.1:8080"
fi

