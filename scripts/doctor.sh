#!/usr/bin/env bash
set -u

# Read-only diagnostics for an installed Lumen node.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOME_DIR="${LUMEN_HOME:-${HOME}/.lumen}"
BIN_PATH="${LUMEND_BIN:-${LUMEN_TARGET:-${REPO_ROOT}/bin/lumend}}"
PROGRESS_CHECK=0
PROGRESS_WAIT="${DOCTOR_PROGRESS_WAIT:-3}"
FAILURES=0
WARNINGS=0
SYNCING=0
STATUS_JSON=""
LATEST_HEIGHT=""
EXPECTED_CHAIN_ID=""
RPC_URL=""
ROLE="unknown"
SERVICE_MODE="UNKNOWN"
ACTIVE_BINARY_PATH="UNKNOWN"

usage() {
  cat <<EOF
Usage: ./scripts/doctor.sh [options]

Read-only diagnostics for a Lumen node. The command never starts, stops, or
repairs services and never modifies node configuration or blockchain data.

Options:
  --home DIR       Node home (default: \$LUMEN_HOME or \$HOME/.lumen).
  --binary PATH    lumend binary (default: \$LUMEND_BIN, \$LUMEN_TARGET, or repo bin/lumend).
  --progress       Sample RPC height twice to check for progress.
  -h, --help       Show this help.

Exit status:
  0  HEALTHY, SYNCING, or DEGRADED diagnostics.
  1  One or more required checks failed.
EOF
}

pass() { printf '[PASS] %-16s %s\n' "$1" "$2"; }
warn() { WARNINGS=$((WARNINGS + 1)); printf '[WARN] %-16s %s\n' "$1" "$2"; }
fail() { FAILURES=$((FAILURES + 1)); printf '[FAIL] %-16s %s\n' "$1" "$2"; }
skip() { printf '[SKIP] %-16s %s\n' "$1" "$2"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --home)
      [[ $# -ge 2 ]] || { echo "ERROR: --home requires a value." >&2; exit 2; }
      HOME_DIR="$2"
      shift
      ;;
    --binary)
      [[ $# -ge 2 ]] || { echo "ERROR: --binary requires a value." >&2; exit 2; }
      BIN_PATH="$2"
      shift
      ;;
    --progress)
      PROGRESS_CHECK=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown option '$1'." >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

toml_value() {
  local file="$1" section="$2" key="$3"
  awk -v wanted_section="$section" -v wanted_key="$key" '
    /^\[/ { in_section = ($0 == wanted_section); next }
    in_section && $0 ~ "^[[:space:]]*" wanted_key "[[:space:]]*=" {
      sub("^[[:space:]]*" wanted_key "[[:space:]]*=[[:space:]]*", "")
      sub("[[:space:]]+#.*$", "")
      gsub(/^"|"$/, "")
      print
      exit
    }
  ' "$file"
}

port_from_address() {
  local address="$1"
  if [[ "$address" == tcp://* ]]; then
    address="${address#tcp://}"
  elif [[ "$address" != *:* ]]; then
    return 1
  fi
  printf '%s\n' "${address##*:}"
}

socket_has_port() {
  local port="$1"
  command -v ss >/dev/null 2>&1 || return 2
  ss -ltnH 2>/dev/null | awk -v wanted=":$port" '$4 ~ wanted "$" { found = 1 } END { exit(found ? 0 : 1) }'
}

isolated_binary_version() {
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

detect_execution_model() {
  local service_exec="" main_pid="" child_pid=""
  if command -v systemctl >/dev/null 2>&1; then
    service_exec="$(systemctl show -p ExecStart --value lumend.service 2>/dev/null || true)"
    if [[ -z "$service_exec" && -f /etc/systemd/system/lumend.service ]]; then
      service_exec="$(awk -F= '$1 == \"ExecStart\" { print substr($0, index($0, \"=\") + 1); exit }' /etc/systemd/system/lumend.service)"
    fi
    main_pid="$(systemctl show -p MainPID --value lumend.service 2>/dev/null || true)"
  fi
  if [[ "$service_exec" == *cosmovisor* ]]; then
    SERVICE_MODE="COSMOVISOR"
  elif [[ "$service_exec" == *lumend* ]]; then
    SERVICE_MODE="DIRECT"
  fi
  if [[ "$main_pid" =~ ^[1-9][0-9]*$ && -e "/proc/$main_pid/exe" ]]; then
    ACTIVE_BINARY_PATH="$(readlink -f "/proc/$main_pid/exe")"
    if [[ "$SERVICE_MODE" == COSMOVISOR && "$ACTIVE_BINARY_PATH" == *cosmovisor* ]] && command -v pgrep >/dev/null 2>&1; then
      child_pid="$(pgrep -P "$main_pid" -x lumend | head -n 1 || true)"
      if [[ "$child_pid" =~ ^[1-9][0-9]*$ && -e "/proc/$child_pid/exe" ]]; then
        ACTIVE_BINARY_PATH="$(readlink -f "/proc/$child_pid/exe")"
      else
        ACTIVE_BINARY_PATH="UNKNOWN"
      fi
    fi
  fi
}

echo "Lumen Node Doctor"
echo "Home: $HOME_DIR"
echo

ROLE_FILE="$HOME_DIR/validator-kit-role"
if [[ -f "$ROLE_FILE" ]]; then
  ROLE="$(awk -F= '$1 == "role" { print $2; exit }' "$ROLE_FILE")"
  case "$ROLE" in
    fullnode|rpc|validator|sentry|seed)
      pass "Role" "$ROLE"
      ;;
    *)
      ROLE="unknown"
      warn "Role" "invalid role metadata in $ROLE_FILE"
      ;;
  esac
else
  skip "Role" "role metadata not present"
fi

# Binary and node-home checks.
detect_execution_model
if [[ "$SERVICE_MODE" == COSMOVISOR ]]; then
  pass "Execution" "Cosmovisor service model"
  if [[ "$ACTIVE_BINARY_PATH" != UNKNOWN && -x "$ACTIVE_BINARY_PATH" ]]; then
    ACTIVE_VERSION="$(isolated_binary_version "$ACTIVE_BINARY_PATH" 2>/dev/null || true)"
    if [[ -n "$ACTIVE_VERSION" ]]; then
      pass "Running binary" "$ACTIVE_BINARY_PATH: ${ACTIVE_VERSION//$'\n'/ }"
    else
      warn "Running binary" "version could not be read from $ACTIVE_BINARY_PATH"
    fi
  else
    warn "Running binary" "active Cosmovisor child could not be determined"
  fi
else
  if [[ "$SERVICE_MODE" == DIRECT ]]; then
    pass "Execution" "Direct lumend service model"
  else
    skip "Execution" "service execution model is unknown"
  fi
  if [[ -f "$BIN_PATH" && -x "$BIN_PATH" ]]; then
    BINARY_VERSION="$(isolated_binary_version "$BIN_PATH" 2>&1 || true)"
    if [[ -n "$BINARY_VERSION" ]]; then
      pass "Configured binary" "${BIN_PATH}: ${BINARY_VERSION//$'\n'/ }"
    else
      fail "Configured binary" "$BIN_PATH version returned no output."
    fi
  else
    fail "Configured binary" "$BIN_PATH is missing or not executable."
  fi
fi

if [[ -d "$HOME_DIR" ]]; then
  pass "Home" "$HOME_DIR"
else
  fail "Home" "$HOME_DIR does not exist."
fi

CFG_TOML="$HOME_DIR/config/config.toml"
APP_TOML="$HOME_DIR/config/app.toml"
GENESIS_JSON="$HOME_DIR/config/genesis.json"
for required_file in "$CFG_TOML" "$APP_TOML" "$GENESIS_JSON"; do
  if [[ -f "$required_file" ]]; then
    pass "File" "$required_file"
  else
    fail "File" "missing required file: $required_file"
  fi
done

if command -v jq >/dev/null 2>&1 && [[ -f "$GENESIS_JSON" ]]; then
  if EXPECTED_CHAIN_ID="$(jq -er '.chain_id // empty' "$GENESIS_JSON" 2>/dev/null)" && [[ -n "$EXPECTED_CHAIN_ID" ]]; then
    pass "Genesis" "chain ID $EXPECTED_CHAIN_ID"
  else
    fail "Genesis" "could not read chain_id from $GENESIS_JSON"
  fi
else
  fail "Genesis" "jq is required to inspect the expected chain ID."
fi

# Service checks are optional for manually-run nodes, but an installed unit
# must be healthy.
if ! command -v systemctl >/dev/null 2>&1; then
  skip "Service" "systemctl is unavailable; manual process mode"
else
  UNIT_STATE="$(systemctl list-unit-files --no-legend lumend.service 2>/dev/null || true)"
  if [[ -z "$UNIT_STATE" ]]; then
    skip "Service" "lumend.service is not installed"
  else
    pass "Service unit" "lumend.service installed"
    ENABLED_STATE="$(systemctl is-enabled lumend.service 2>/dev/null || true)"
    if [[ "$ENABLED_STATE" == "enabled" ]]; then
      pass "Service enabled" "lumend.service"
    else
      warn "Service enabled" "state is ${ENABLED_STATE:-unknown}"
    fi
    ACTIVE_STATE="$(systemctl is-active lumend.service 2>/dev/null || true)"
    if [[ "$ACTIVE_STATE" == "active" ]]; then
      pass "Service active" "active"
      MAIN_PID="$(systemctl show -p MainPID --value lumend.service 2>/dev/null || true)"
      if [[ "$MAIN_PID" =~ ^[1-9][0-9]*$ ]]; then
        pass "Service process" "MainPID $MAIN_PID"
      else
        fail "Service process" "active service has no usable MainPID"
      fi
    else
      fail "Service active" "state is ${ACTIVE_STATE:-unknown}"
    fi
  fi
fi

# Configuration-derived local RPC endpoint.
if [[ -f "$CFG_TOML" ]]; then
  RPC_LADDR="$(toml_value "$CFG_TOML" "[rpc]" laddr || true)"
  if [[ -z "$RPC_LADDR" ]]; then
    if [[ "$ROLE" == seed ]]; then
      pass "RPC config" "disabled for seed role"
    else
      fail "RPC config" "[rpc].laddr is missing"
    fi
  elif RPC_PORT="$(port_from_address "$RPC_LADDR")"; then
    RPC_HOST="${RPC_LADDR#tcp://}"
    RPC_HOST="${RPC_HOST%:*}"
    if [[ "$RPC_HOST" == "0.0.0.0" || "$RPC_HOST" == "[::]" || "$RPC_HOST" == "" ]]; then
      RPC_HOST="127.0.0.1"
    fi
    RPC_URL="http://${RPC_HOST}:${RPC_PORT}"
    pass "RPC config" "$RPC_LADDR (checking $RPC_URL)"
  else
    fail "RPC config" "unsupported RPC listener '$RPC_LADDR'"
  fi
else
  skip "RPC config" "config.toml is unavailable"
fi

if [[ -n "$RPC_URL" ]] && command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  if STATUS_JSON="$(curl --fail --silent --show-error --location --max-time 5 "$RPC_URL/status" 2>/dev/null)"; then
    if jq -e '.result.node_info.network and .result.sync_info.latest_block_height and (.result.sync_info.catching_up | type == "boolean")' >/dev/null 2>&1 <<< "$STATUS_JSON"; then
      REMOTE_CHAIN_ID="$(jq -r '.result.node_info.network' <<< "$STATUS_JSON")"
      LATEST_HEIGHT="$(jq -r '.result.sync_info.latest_block_height' <<< "$STATUS_JSON")"
      CATCHING_UP="$(jq -r '.result.sync_info.catching_up' <<< "$STATUS_JSON")"
      pass "RPC" "$RPC_URL responding"
      if [[ -n "$EXPECTED_CHAIN_ID" && "$REMOTE_CHAIN_ID" == "$EXPECTED_CHAIN_ID" ]]; then
        pass "Chain ID" "$REMOTE_CHAIN_ID"
      else
        fail "Chain ID" "RPC reports '$REMOTE_CHAIN_ID', expected '${EXPECTED_CHAIN_ID:-unknown}'"
      fi
      if [[ "$LATEST_HEIGHT" =~ ^[0-9]+$ ]] && (( LATEST_HEIGHT > 0 )); then
        pass "Height" "$LATEST_HEIGHT"
      elif [[ "$LATEST_HEIGHT" == "0" ]]; then
        fail "Height" "RPC is responding but height is zero"
      else
        fail "Height" "invalid latest height '$LATEST_HEIGHT'"
      fi
      if [[ "$CATCHING_UP" == "true" ]]; then
        SYNCING=1
        warn "Sync" "node is catching up"
      elif [[ "$CATCHING_UP" == "false" ]]; then
        pass "Sync" "caught up"
      else
        fail "Sync" "catching_up could not be determined"
      fi
    else
      fail "RPC" "invalid or incomplete /status JSON"
    fi
  else
    fail "RPC" "$RPC_URL/status is unreachable"
  fi
elif [[ -n "$RPC_URL" ]]; then
  fail "RPC" "curl and jq are required for RPC checks"
fi

if [[ "$PROGRESS_CHECK" -eq 1 && "$LATEST_HEIGHT" =~ ^[1-9][0-9]*$ && -n "$RPC_URL" ]]; then
  if [[ "$PROGRESS_WAIT" =~ ^[1-9][0-9]*$ ]]; then
    sleep "$PROGRESS_WAIT"
    SECOND_STATUS="$(curl --fail --silent --show-error --location --max-time 5 "$RPC_URL/status" 2>/dev/null || true)"
    SECOND_HEIGHT="$(jq -r '.result.sync_info.latest_block_height // empty' <<< "$SECOND_STATUS" 2>/dev/null || true)"
    if [[ "$SECOND_HEIGHT" =~ ^[0-9]+$ ]] && (( SECOND_HEIGHT > LATEST_HEIGHT )); then
      pass "Progress" "$LATEST_HEIGHT -> $SECOND_HEIGHT in ${PROGRESS_WAIT}s"
    elif [[ "$CATCHING_UP" == "true" ]]; then
      warn "Progress" "height did not advance during sample ($LATEST_HEIGHT -> ${SECOND_HEIGHT:-unknown})"
    else
      warn "Progress" "height did not advance during sample ($LATEST_HEIGHT -> ${SECOND_HEIGHT:-unknown})"
    fi
  else
    warn "Progress" "DOCTOR_PROGRESS_WAIT is not a positive integer"
  fi
elif [[ "$PROGRESS_CHECK" -eq 1 ]]; then
  skip "Progress" "RPC height is unavailable"
fi

# P2P and peer checks use the local RPC only; no peer configuration is changed.
if [[ -n "$RPC_URL" && -n "$STATUS_JSON" ]] && command -v jq >/dev/null 2>&1; then
  NET_INFO="$(curl --fail --silent --show-error --location --max-time 5 "$RPC_URL/net_info" 2>/dev/null || true)"
  if PEER_COUNT="$(jq -er '.result.n_peers' <<< "$NET_INFO" 2>/dev/null)" && [[ "$PEER_COUNT" =~ ^[0-9]+$ ]]; then
    if (( PEER_COUNT > 0 )); then
      pass "P2P peers" "$PEER_COUNT connected"
    else
      warn "P2P peers" "0 connected peers"
    fi
  else
    warn "P2P peers" "could not read /net_info"
  fi
else
  skip "P2P peers" "RPC is unavailable"
fi

if [[ -f "$CFG_TOML" ]]; then
  P2P_LADDR="$(toml_value "$CFG_TOML" "[p2p]" laddr || true)"
  if P2P_PORT="$(port_from_address "$P2P_LADDR")"; then
    if socket_has_port "$P2P_PORT"; then
      pass "P2P listener" "$P2P_LADDR"
    elif [[ "$?" -eq 2 ]]; then
      skip "P2P listener" "ss is unavailable"
    else
      fail "P2P listener" "$P2P_LADDR is not listening"
    fi
  else
    warn "P2P listener" "could not parse [p2p].laddr"
  fi
fi

check_app_listener() {
  local label="$1" key="$2" address_key="$3"
  local enabled address port socket_status
  enabled="$(toml_value "$APP_TOML" "[$key]" enable || true)"
  address="$(toml_value "$APP_TOML" "[$key]" "$address_key" || true)"
  if [[ "$enabled" == "false" ]]; then
    pass "$label" "disabled by configuration"
    return
  fi
  if [[ "$enabled" != "true" ]]; then
    warn "$label" "enable setting is ${enabled:-missing}"
    return
  fi
  if port="$(port_from_address "$address")"; then
    if socket_has_port "$port"; then
      pass "$label" "$address listening"
    else
      socket_status=$?
      if [[ "$socket_status" -eq 2 ]]; then
        skip "$label" "ss unavailable; configured $address"
      else
        fail "$label" "$address is not listening"
      fi
    fi
  else
    warn "$label" "enabled with unparsed address '${address:-missing}'"
  fi
}

if [[ -f "$APP_TOML" ]]; then
  check_app_listener "API" api address
  check_app_listener "gRPC" grpc address
else
  skip "API/gRPC" "app.toml is unavailable"
fi

if [[ -f "$CFG_TOML" && -f "$APP_TOML" && "$ROLE" != unknown ]]; then
  P2P_LADDR="$(toml_value "$CFG_TOML" "[p2p]" laddr || true)"
  P2P_HOST="${P2P_LADDR#tcp://}"
  P2P_HOST="${P2P_HOST%:*}"
  API_ENABLE="$(toml_value "$APP_TOML" "[api]" enable || true)"
  GRPC_ENABLE="$(toml_value "$APP_TOML" "[grpc]" enable || true)"
  SEED_MODE_VALUE="$(toml_value "$CFG_TOML" "[p2p]" seed_mode || true)"
  case "$ROLE" in
    rpc)
      if [[ "$P2P_HOST" == "0.0.0.0" || "$P2P_HOST" == "[::]" ]]; then pass "Role listeners" "rpc role exposes P2P publicly"; else warn "Role listeners" "rpc role P2P is not publicly bound"; fi
      if [[ "$API_ENABLE" == "true" && "$GRPC_ENABLE" == "true" ]]; then pass "Role services" "public API and gRPC enabled"; else warn "Role services" "rpc role expects API and gRPC enabled"; fi
      ;;
    fullnode|validator|sentry)
      if [[ "$P2P_HOST" == "0.0.0.0" || "$P2P_HOST" == "[::]" ]]; then pass "Role listeners" "$ROLE role exposes P2P publicly"; else warn "Role listeners" "$ROLE role P2P is not publicly bound"; fi
      if [[ "$API_ENABLE" == "false" && "$GRPC_ENABLE" == "true" ]]; then pass "Role services" "API disabled and gRPC enabled"; else warn "Role services" "$ROLE role expects API disabled and gRPC enabled"; fi
      ;;
    seed)
      if [[ "$SEED_MODE_VALUE" == "true" ]]; then pass "Seed mode" "p2p.seed_mode=true"; else fail "Seed mode" "p2p.seed_mode is not enabled"; fi
      if [[ "$API_ENABLE" == "false" && "$GRPC_ENABLE" == "false" ]]; then pass "Role services" "API and gRPC disabled"; else warn "Role services" "seed role expects API and gRPC disabled"; fi
      ;;
  esac
fi

# State-sync visibility is local only; remote trust parameters are not revalidated.
if [[ -f "$CFG_TOML" ]]; then
  STATE_SYNC_ENABLE="$(toml_value "$CFG_TOML" "[statesync]" enable || true)"
  STATE_SYNC_RPC="$(toml_value "$CFG_TOML" "[statesync]" rpc_servers || true)"
  STATE_SYNC_HEIGHT="$(toml_value "$CFG_TOML" "[statesync]" trust_height || true)"
  if [[ "$STATE_SYNC_ENABLE" == "true" ]]; then
    if [[ "$STATE_SYNC_RPC" == *,* ]]; then
      STATE_SYNC_MODE="dual/duplicated RPC entries"
    else
      STATE_SYNC_MODE="single RPC entry"
    fi
    if [[ "$STATE_SYNC_HEIGHT" =~ ^[1-9][0-9]*$ ]]; then
      pass "State sync" "enabled; $STATE_SYNC_MODE; trust height $STATE_SYNC_HEIGHT"
    else
      fail "State sync" "enabled with invalid trust height '${STATE_SYNC_HEIGHT:-missing}'"
    fi
  else
    pass "State sync" "disabled"
  fi
fi

# Validator files are factual observations, not proof of active staking.
CONSENSUS_KEY="$HOME_DIR/config/priv_validator_key.json"
SIGNING_STATE="$HOME_DIR/data/priv_validator_state.json"
if [[ -f "$CONSENSUS_KEY" && -f "$SIGNING_STATE" ]]; then
  pass "Consensus files" "key and signing state present"
elif [[ -f "$CONSENSUS_KEY" || -f "$SIGNING_STATE" ]]; then
  warn "Consensus files" "only one consensus file is present"
else
  pass "Consensus files" "not present (node may be non-validator)"
fi

# High-value Phase 2 checks without recursively scanning the host.
for backup_dir in "$HOME_DIR/first-node.bak" "$HOME_DIR/validator-node.bak"; do
  if [[ -d "$backup_dir" ]]; then
    mode="$(stat -c '%a' "$backup_dir" 2>/dev/null || true)"
    if [[ "$mode" =~ ^[0-7]+$ ]] && (( 8#$mode & 77 )); then
      warn "Backup permissions" "$backup_dir is mode $mode"
    else
      pass "Backup permissions" "$backup_dir is owner-only"
    fi
  fi
done

for legacy_mnemonic in "$HOME_DIR/first-node.bak/validator_mnemonic.txt" "$HOME_DIR/validator-node.bak/validator_mnemonic.txt"; do
  if [[ -f "$legacy_mnemonic" ]]; then
    warn "Legacy secret" "plaintext mnemonic backup detected: $legacy_mnemonic"
  fi
done

if command -v df >/dev/null 2>&1 && [[ -d "$HOME_DIR" ]]; then
  DISK_LINE="$(df -P -k "$HOME_DIR" 2>/dev/null | tail -n 1)"
  read -r _ _ _ blocks_available usage _ <<< "$DISK_LINE"
  if [[ "$blocks_available" =~ ^[0-9]+$ && "$usage" =~ ^[0-9]+%$ ]]; then
    available_gb=$((blocks_available / 1024 / 1024))
    usage_number="${usage%%%}"
    if (( usage_number >= 90 || available_gb < 10 )); then
      warn "Disk" "${available_gb} GB available, ${usage} used"
    else
      pass "Disk" "${available_gb} GB available, ${usage} used"
    fi
  else
    warn "Disk" "could not parse filesystem usage"
  fi
else
  skip "Disk" "df or node home unavailable"
fi

echo
if (( FAILURES > 0 )); then
  RESULT="FAILED"
  EXIT_STATUS=1
elif (( SYNCING == 1 )); then
  RESULT="SYNCING"
  EXIT_STATUS=0
elif (( WARNINGS > 0 )); then
  RESULT="DEGRADED"
  EXIT_STATUS=0
else
  RESULT="HEALTHY"
  EXIT_STATUS=0
fi
echo "Result: $RESULT"
echo "Failures: $FAILURES  Warnings: $WARNINGS"
exit "$EXIT_STATUS"
