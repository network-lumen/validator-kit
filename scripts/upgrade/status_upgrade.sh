#!/usr/bin/env bash
set -euo pipefail

HOME_DIR="$HOME/.lumen"
SERVICE_NAME="lumend"
[[ -v LUMEN_HOME ]] && HOME_DIR="$LUMEN_HOME"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --home) [[ $# -ge 2 ]] || { echo "ERROR: --home requires a value." >&2; exit 2; }; HOME_DIR="$2"; shift 2 ;;
    --service) [[ $# -ge 2 ]] || { echo "ERROR: --service requires a value." >&2; exit 2; }; SERVICE_NAME="$2"; shift 2 ;;
    -h|--help) echo "Usage: ./scripts/upgrade/status_upgrade.sh [--home DIR] [--service NAME]"; exit 0 ;;
    *) echo "ERROR: unknown option '$1'." >&2; exit 2 ;;
  esac
done

echo "Node home       : $HOME_DIR"
SERVICE_EXEC=""
SERVICE_MODE="UNKNOWN"
SERVICE_STATE="UNKNOWN"
if command -v systemctl >/dev/null 2>&1; then
  SERVICE_EXEC="$(systemctl show -p ExecStart --value "$SERVICE_NAME" 2>/dev/null || true)"
  SERVICE_STATE="$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)"
fi
if [[ -z "$SERVICE_EXEC" && -f "/etc/systemd/system/$SERVICE_NAME.service" ]]; then
  SERVICE_EXEC="$(awk -F= '$1 == "ExecStart" { print substr($0, index($0, \"=\") + 1); exit }' "/etc/systemd/system/$SERVICE_NAME.service")"
fi
if [[ "$SERVICE_EXEC" == *cosmovisor* ]]; then SERVICE_MODE="COSMOVISOR"; fi
if [[ "$SERVICE_EXEC" == *lumend* && "$SERVICE_MODE" == UNKNOWN ]]; then SERVICE_MODE="DIRECT"; fi
echo "Service mode   : $SERVICE_MODE"
echo "Service state  : ${SERVICE_STATE:-UNKNOWN}"

if [[ ! -v COSMOVISOR_BIN ]]; then
  COSMOVISOR_BIN="$(command -v cosmovisor 2>/dev/null || true)"
fi
if [[ -x "$COSMOVISOR_BIN" ]]; then
  COSMOVISOR_VERSION="$("$COSMOVISOR_BIN" version 2>&1 || true)"
  echo "Cosmovisor     : $COSMOVISOR_BIN ${COSMOVISOR_VERSION//$'\n'/ }"
else
  echo "Cosmovisor     : UNKNOWN (not found)"
fi

isolated_version() {
  local binary="$1" temp output status
  temp="$(mktemp -d)"
  if output="$(HOME="$temp" XDG_CONFIG_HOME="$temp/.config" XDG_DATA_HOME="$temp/.local/share" XDG_CACHE_HOME="$temp/.cache" "$binary" version 2>&1)"; then
    status=0
  else
    status=$?
  fi
  rm -rf -- "$temp"
  printf '%s' "$output"
  return "$status"
}

report_binary() {
  local label="$1" binary="$2" version
  if [[ -x "$binary" ]]; then
    version="$(isolated_version "$binary" 2>/dev/null || true)"
    echo "$label: $binary ${version//$'\n'/ }"
  else
    echo "$label: UNKNOWN ($binary is unavailable)"
  fi
}

report_binary "Genesis binary" "$HOME_DIR/cosmovisor/genesis/bin/lumend"
found_upgrade=0
shopt -s nullglob
for binary in "$HOME_DIR"/cosmovisor/upgrades/*/bin/lumend; do
  found_upgrade=1
  upgrade_name="$(basename "$(dirname "$(dirname "$binary")")")"
  report_binary "Prepared upgrade $upgrade_name" "$binary"
done
shopt -u nullglob
if [[ "$found_upgrade" -eq 0 ]]; then echo "Prepared upgrades: none"; fi

for info in "$HOME_DIR/data/upgrade-info.json" "$HOME_DIR/upgrade-info.json"; do
  if [[ -f "$info" ]]; then echo "Upgrade info   : $info"; fi
done

ACTIVE_PATH="UNKNOWN"
if command -v systemctl >/dev/null 2>&1; then
  MAIN_PID="$(systemctl show -p MainPID --value "$SERVICE_NAME" 2>/dev/null || true)"
  if [[ "$MAIN_PID" =~ ^[1-9][0-9]*$ && -e "/proc/$MAIN_PID/exe" ]]; then
    ACTIVE_PATH="$(readlink -f "/proc/$MAIN_PID/exe")"
    if [[ "$ACTIVE_PATH" == *cosmovisor* ]] && command -v pgrep >/dev/null 2>&1; then
      CHILD_PID="$(pgrep -P "$MAIN_PID" -x lumend | head -n 1 || true)"
      if [[ "$CHILD_PID" =~ ^[1-9][0-9]*$ && -e "/proc/$CHILD_PID/exe" ]]; then
        ACTIVE_PATH="$(readlink -f "/proc/$CHILD_PID/exe")"
      else
        ACTIVE_PATH="UNKNOWN"
      fi
    fi
  fi
fi
echo "Active lumend  : $ACTIVE_PATH"
if [[ "$ACTIVE_PATH" != UNKNOWN ]]; then
  report_binary "Running version" "$ACTIVE_PATH"
else
  echo "Running version : UNKNOWN (active executable could not be determined)"
fi
