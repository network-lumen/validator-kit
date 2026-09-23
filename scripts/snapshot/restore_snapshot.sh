#!/usr/bin/env bash
set -euo pipefail
umask 077

usage() {
  cat <<'EOF'
Usage: ./scripts/snapshot/restore_snapshot.sh [options]

Restore blockchain data while preserving node configuration, identity, and
local validator signing state.

Options:
  --home DIR             Node home (default: $HOME/.lumen).
  --snapshot FILE|URL    Local or HTTP(S) snapshot archive.
  --snapshot-dir DIR    Local snapshot directory for selection/backups.
  --service NAME         systemd service name (default: lumend).
  --non-interactive      Require --snapshot and skip confirmation prompts.

The legacy positional form <HOME_DIR> <SNAPSHOT_DIR> remains supported for
interactive selection of the newest local block_*.tar.gz archive.
EOF
}

HOME_DIR="$HOME/.lumen"
SNAP_DIR="$HOME/snapshots"
SERVICE_NAME="lumend"
[[ -v LUMEN_HOME ]] && HOME_DIR="$LUMEN_HOME"
[[ -v LUMEN_SNAPSHOT_DIR ]] && SNAP_DIR="$LUMEN_SNAPSHOT_DIR"
SNAPSHOT_INPUT=""
NON_INTERACTIVE=0
POSITIONAL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --home) [[ $# -ge 2 ]] || { echo "ERROR: --home requires a value." >&2; exit 2; }; HOME_DIR="$2"; shift 2 ;;
    --snapshot) [[ $# -ge 2 ]] || { echo "ERROR: --snapshot requires a value." >&2; exit 2; }; SNAPSHOT_INPUT="$2"; shift 2 ;;
    --snapshot-dir) [[ $# -ge 2 ]] || { echo "ERROR: --snapshot-dir requires a value." >&2; exit 2; }; SNAP_DIR="$2"; shift 2 ;;
    --service) [[ $# -ge 2 ]] || { echo "ERROR: --service requires a value." >&2; exit 2; }; SERVICE_NAME="$2"; shift 2 ;;
    --non-interactive) NON_INTERACTIVE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      if [[ "$1" =~ ^https?:// || "$1" == *.tar.gz ]]; then
        SNAPSHOT_INPUT="$1"
      elif (( POSITIONAL == 0 )); then
        HOME_DIR="$1"
        POSITIONAL=1
      elif (( POSITIONAL == 1 )); then
        SNAP_DIR="$1"
        POSITIONAL=2
      else
        echo "ERROR: unexpected argument '$1'." >&2
        usage >&2
        exit 2
      fi
      shift
      ;;
  esac
done

[[ -d "$HOME_DIR" ]] || { echo "ERROR: node home not found: $HOME_DIR" >&2; exit 1; }
[[ -d "$HOME_DIR/config" ]] || { echo "ERROR: node config directory not found: $HOME_DIR/config" >&2; exit 1; }
command -v realpath >/dev/null 2>&1 || { echo "ERROR: realpath is required." >&2; exit 1; }
NODE_DATA_PATH="$(realpath -m -- "$HOME_DIR/data")"
SNAP_DIR_PATH="$(realpath -m -- "$SNAP_DIR")"
[[ "$SNAP_DIR_PATH" != "$NODE_DATA_PATH" && "$SNAP_DIR_PATH" != "$NODE_DATA_PATH/"* ]] ||
  { echo "ERROR: snapshot directory cannot be inside node data: $SNAP_DIR" >&2; exit 1; }

ROLE=unknown
ROLE_FILE="$HOME_DIR/validator-kit-role"
if [[ -f "$ROLE_FILE" ]]; then
  ROLE="$(awk -F= '$1 == "role" { print $2; exit }' "$ROLE_FILE")"
  case "$ROLE" in validator|fullnode|rpc|sentry|seed) ;; *) ROLE=unknown ;; esac
fi
CONSENSUS_KEY="$HOME_DIR/config/priv_validator_key.json"
LOCAL_STATE="$HOME_DIR/data/priv_validator_state.json"
HAS_CONSENSUS_KEY=0
[[ -f "$CONSENSUS_KEY" ]] && HAS_CONSENSUS_KEY=1
if [[ "$ROLE" == validator || "$HAS_CONSENSUS_KEY" -eq 1 ]]; then
  [[ -f "$CONSENSUS_KEY" ]] || { echo "ERROR: validator role has no consensus key." >&2; exit 1; }
  [[ -f "$LOCAL_STATE" ]] || {
    echo "ERROR: refusing routine restore without $LOCAL_STATE." >&2
    echo "Resolve validator signing-state recovery manually before proceeding." >&2
    exit 1
  }
fi

WORK_DIR="" STAGE_DIR="" DOWNLOAD_DIR="" OLD_DATA="" SAFETY_BACKUP=""
SERVICE_WAS_ACTIVE=0
cleanup() {
  [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]] && rm -rf -- "$WORK_DIR"
  [[ -n "$DOWNLOAD_DIR" && -d "$DOWNLOAD_DIR" ]] && rm -rf -- "$DOWNLOAD_DIR"
  if [[ -n "$OLD_DATA" && -e "$OLD_DATA" && ! -e "$HOME_DIR/data" ]]; then
    mv -- "$OLD_DATA" "$HOME_DIR/data" || true
  fi
}
trap cleanup EXIT
die() {
  echo "ERROR: $*" >&2
  [[ -n "$SAFETY_BACKUP" ]] && echo "Safety backup: $SAFETY_BACKUP" >&2
  exit 1
}

hash_dir() {
  local dir="$1"
  find "$dir" -type f -printf '%P\0' | sort -z |
    while IFS= read -r -d '' rel; do sha256sum "$dir/$rel" | awk '{print $1}'; done |
    sha256sum | awk '{print $1}'
}

if [[ -n "$SNAPSHOT_INPUT" ]]; then
  if [[ "$SNAPSHOT_INPUT" =~ ^https?:// ]]; then
    command -v curl >/dev/null 2>&1 || die "curl is required for remote snapshots."
    DOWNLOAD_DIR="$(mktemp -d)"
    SNAPSHOT_FILE="$DOWNLOAD_DIR/snapshot.tar.gz"
    curl --fail --location --silent --show-error "$SNAPSHOT_INPUT" -o "$SNAPSHOT_FILE" ||
      die "snapshot download failed."
  else
    SNAPSHOT_FILE="$SNAPSHOT_INPUT"
  fi
else
  [[ "$NON_INTERACTIVE" -eq 0 ]] || die "--non-interactive requires --snapshot."
  [[ -d "$SNAP_DIR" ]] || die "snapshot directory not found: $SNAP_DIR"
  SNAPSHOT_FILE="$(find "$SNAP_DIR" -maxdepth 1 -type f -name 'block_*.tar.gz' | sort | tail -n 1)"
  [[ -n "$SNAPSHOT_FILE" ]] || die "no block_*.tar.gz snapshots found in $SNAP_DIR"
  echo "Selected snapshot: $(basename "$SNAPSHOT_FILE")"
fi

[[ -s "$SNAPSHOT_FILE" ]] || die "snapshot archive is missing or empty."
tar -tzf "$SNAPSHOT_FILE" >/dev/null 2>&1 || die "snapshot is not a readable gzip tar archive."
has_data=0
has_manifest=0
while IFS= read -r entry; do
  [[ "$entry" != /* && "$entry" != .. && "$entry" != ../* && "$entry" != */.. && "$entry" != */../* ]] ||
    die "snapshot contains an unsafe path: $entry"
  normalized="$(printf '%s' "$entry" | sed 's#^\./##')"
  case "$normalized" in
    data|data/*) has_data=1 ;;
    snapshot.json) has_manifest=1 ;;
    *) die "snapshot contains unexpected content: $entry" ;;
  esac
done < <(tar -tzf "$SNAPSHOT_FILE")
(( has_data == 1 && has_manifest == 1 )) || die "snapshot must contain data/ and snapshot.json."
while IFS= read -r type; do
  case "$(printf '%s' "$type" | cut -c1)" in
    -|d) ;;
    *) die "snapshot contains a non-regular entry; refusing extraction." ;;
  esac
done < <(tar -tvzf "$SNAPSHOT_FILE")

WORK_DIR="$(mktemp -d)"
STAGE_DIR="$WORK_DIR/stage"
mkdir -m 700 "$STAGE_DIR"
tar -xzf "$SNAPSHOT_FILE" -C "$STAGE_DIR" --no-same-owner --no-same-permissions ||
  die "snapshot extraction failed."
command -v jq >/dev/null 2>&1 || die "jq is required to validate snapshot metadata."
expected="$(jq -er '.sha256 // empty' "$STAGE_DIR/snapshot.json" 2>/dev/null)" ||
  die "snapshot.json has no valid SHA256 value."
[[ "$expected" =~ ^[[:xdigit:]]{64}$ ]] || die "snapshot.json SHA256 value is malformed."
actual="$(hash_dir "$STAGE_DIR/data")"
[[ "$expected" == "$actual" ]] || die "snapshot data integrity check failed."
rm -f -- "$STAGE_DIR/data/priv_validator_state.json"
if [[ -f "$LOCAL_STATE" ]]; then
  cp -- "$LOCAL_STATE" "$STAGE_DIR/preserved-priv_validator_state.json" ||
    die "could not stage local signing state."
fi

if [[ "$NON_INTERACTIVE" -eq 0 ]]; then
  read -r -p "Commit restore into $HOME_DIR? (y/N): " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Restore cancelled before service changes."; exit 0; }
fi

node_process_running() {
  if command -v pgrep >/dev/null 2>&1; then
    pgrep -x lumend >/dev/null 2>&1
  else
    ps -eo comm= 2>/dev/null | awk '$1 == "lumend" { found = 1 } END { exit(found ? 0 : 1) }'
  fi
}
if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet "$SERVICE_NAME"; then
  SERVICE_WAS_ACTIVE=1
  systemctl stop "$SERVICE_NAME" || die "failed to stop $SERVICE_NAME."
fi
for _ in {1..20}; do
  node_process_running || break
  sleep 0.5
done
node_process_running && die "lumend is still running; no filesystem changes were made."

mkdir -p "$SNAP_DIR" || die "could not create snapshot directory $SNAP_DIR."
backup_temp="$(mktemp -d "$SNAP_DIR/.recovery-safety.XXXXXX")"
chmod 700 "$backup_temp"
backup_path="$SNAP_DIR/recovery-safety-$(date +%Y%m%d-%H%M%S)-$(basename "$backup_temp")"
if ! cp -a "$HOME_DIR/config" "$backup_temp/"; then
  rm -rf -- "$backup_temp"
  die "could not back up node configuration."
fi
mkdir -p "$backup_temp/data"
if [[ -f "$LOCAL_STATE" ]]; then
  cp -a "$LOCAL_STATE" "$backup_temp/data/" || { rm -rf -- "$backup_temp"; die "could not back up signing state."; }
fi
shopt -s nullglob
for source in "$HOME_DIR"/keyring-* "$HOME_DIR/pqc_keys" "$ROLE_FILE"; do
  [[ -e "$source" || -L "$source" ]] || continue
  cp -a "$source" "$backup_temp/" || { shopt -u nullglob; rm -rf -- "$backup_temp"; die "could not back up $source."; }
done
shopt -u nullglob
find "$backup_temp" -type d -exec chmod 700 {} +
find "$backup_temp" -type f -exec chmod 600 {} +
mv -- "$backup_temp" "$backup_path" || die "could not finalize safety backup."
SAFETY_BACKUP="$backup_path"

OLD_DATA="$HOME_DIR/.restore-old-data.$$"
if [[ -e "$HOME_DIR/data" || -L "$HOME_DIR/data" ]]; then
  mv -- "$HOME_DIR/data" "$OLD_DATA" || die "could not move existing data aside."
fi
if ! mv -- "$STAGE_DIR/data" "$HOME_DIR/data"; then
    if [[ -e "$OLD_DATA" ]]; then
      mv -- "$OLD_DATA" "$HOME_DIR/data" || true
    fi
  OLD_DATA=""
  die "could not install staged blockchain data."
fi
if [[ -f "$STAGE_DIR/preserved-priv_validator_state.json" ]] &&
   ! cp -- "$STAGE_DIR/preserved-priv_validator_state.json" "$HOME_DIR/data/priv_validator_state.json"; then
  rm -rf -- "$HOME_DIR/data"
  if [[ -e "$OLD_DATA" ]]; then
    mv -- "$OLD_DATA" "$HOME_DIR/data" || true
  fi
  OLD_DATA=""
  die "could not restore local signing state; old data was restored."
fi
if [[ -e "$OLD_DATA" ]]; then
  rm -rf -- "$OLD_DATA" || die "new data is active, but old data cleanup failed: $OLD_DATA"
fi
OLD_DATA=""
if [[ "$SERVICE_WAS_ACTIVE" -eq 1 ]]; then
  systemctl start "$SERVICE_NAME" || die "restore completed, but failed to restart $SERVICE_NAME."
fi
echo "Restore complete: blockchain data replaced from $(basename "$SNAPSHOT_FILE")."
echo "Preserved: config/, node identity, consensus key, and local signing state when present."
echo "Safety backup: $SAFETY_BACKUP"
echo "Run: ./scripts/doctor.sh --home '$HOME_DIR'"
