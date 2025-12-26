#!/usr/bin/env bash
set -euo pipefail

echo ""
echo "=== Lumen Node Snapshot Restore ==="
echo ""

HOME_DIR="${1:-/root/.lumen}"
SNAP_DIR="${2:-/root/snapshots}"
SERVICE_NAME="${SERVICE_NAME:-lumend}"

echo "[i] HOME_DIR  = $HOME_DIR"
echo "[i] SNAP_DIR  = $SNAP_DIR"
echo "[i] SERVICE   = $SERVICE_NAME"
echo ""

if [[ ! -d "$HOME_DIR" ]]; then
    echo "[ERR] Home directory not found"
    exit 1
fi

if [[ ! -d "$SNAP_DIR" ]]; then
    echo "[ERR] Snapshot directory not found"
    exit 1
fi

hash_dir() {
  local dir="$1"
  find "$dir" -type f -printf '%P\0' \
    | sort -z \
    | while IFS= read -r -d '' rel; do
        sha256sum "$dir/$rel" | awk '{print $1}'
      done \
    | sha256sum | awk '{print $1}'
}

echo "[1] Scanning snapshots..."
mapfile -t SNAPSHOTS < <(find "$SNAP_DIR" -maxdepth 1 -type f -name "block_*.tar.gz" | sort)

if (( ${#SNAPSHOTS[@]} == 0 )); then
    echo "[ERR] No snapshots found"
    exit 1
fi

echo ""
echo "Available snapshots:"
idx=1
for s in "${SNAPSHOTS[@]}"; do
    fname=$(basename "$s")
    mtime=$(stat -c '%Y' "$s" 2>/dev/null || stat -f '%m' "$s" 2>/dev/null || echo "")
    if [[ -n "$mtime" ]]; then
        human_date=$(date -d @"$mtime" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$mtime")
        echo "  [$idx] $fname (mtime: $human_date)"
    else
        echo "  [$idx] $fname"
    fi
    ((idx++))
done

default_index=${#SNAPSHOTS[@]}
echo ""
read -p "Select a snapshot [1-${#SNAPSHOTS[@]}] (default: $default_index): " choice
choice=${choice:-$default_index}

if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#SNAPSHOTS[@]} )); then
    echo "[ERR] Invalid choice"
    exit 1
fi

SNAPSHOT="${SNAPSHOTS[$((choice-1))]}"
SNAP_NAME=$(basename "$SNAPSHOT")

echo ""
echo "[i] Selected snapshot: $SNAPSHOT"
read -p "Confirm restore? (y/N): " confirm
confirm=${confirm:-N}
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "Abort."
    exit 0
fi

echo ""
echo "[2] Checking archive readability..."
if ! tar -tzf "$SNAPSHOT" >/dev/null 2>&1; then
    echo "[ERR] Archive is corrupted"
    exit 1
fi
echo "[OK] Archive readable"

RESTORE_TMP="$(mktemp -d)"
tar -xzf "$SNAPSHOT" -C "$RESTORE_TMP"

if [[ ! -f "$RESTORE_TMP/snapshot.json" ]]; then
    echo "[ERR] snapshot.json missing in archive"
    rm -rf "$RESTORE_TMP"
    exit 1
fi

EXPECTED_HASH=$(jq -r .sha256 "$RESTORE_TMP/snapshot.json")

if [[ ! -d "$RESTORE_TMP/data" ]]; then
    echo "[ERR] data directory missing in archive"
    rm -rf "$RESTORE_TMP"
    exit 1
fi

echo ""
echo "[3] Verifying snapshot integrity..."
ACTUAL_HASH=$(hash_dir "$RESTORE_TMP/data")

if [[ "$EXPECTED_HASH" != "$ACTUAL_HASH" ]]; then
    echo "[ERR] Snapshot integrity check failed"
    echo "Expected: $EXPECTED_HASH"
    echo "Actual:   $ACTUAL_HASH"
    rm -rf "$RESTORE_TMP"
    exit 1
fi

echo "[OK] Snapshot integrity verified"

echo ""
echo "[4] Creating pre-restore backup..."
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_NAME="$SNAP_DIR/pre-restore_$TIMESTAMP.tar.gz"

cd "$HOME_DIR"

if [[ -d "$HOME_DIR/data" ]]; then
    if [[ -f "$HOME_DIR/config/priv_validator_state.json" ]]; then
        tar -czf "$BACKUP_NAME" data config/priv_validator_state.json || {
            echo "[ERR] Failed to create backup"
            rm -rf "$RESTORE_TMP"
            exit 1
        }
    else
        tar -czf "$BACKUP_NAME" data || {
            echo "[ERR] Failed to create backup"
            rm -rf "$RESTORE_TMP"
            exit 1
        }
    fi
    echo "[OK] Backup created: $BACKUP_NAME"
else
    echo "[WARN] No existing data directory"
fi

echo ""
echo "[5] Stopping service..."
systemctl stop "$SERVICE_NAME" || true
sleep 1

echo ""
echo "[6] Removing old data..."
rm -rf "$HOME_DIR/data"
mkdir -p "$HOME_DIR/data"

echo ""
echo "[7] Applying snapshot..."
rm -rf "$HOME_DIR/data"
mv "$RESTORE_TMP/data" "$HOME_DIR/"
rm -f "$RESTORE_TMP/snapshot.json"
rm -rf "$RESTORE_TMP"

echo ""
echo "[8] Resetting validator state..."
mkdir -p "$HOME_DIR/config"
cat > "$HOME_DIR/config/priv_validator_state.json" <<EOF
{
  "height": "0",
  "round": "0",
  "step": 0
}
EOF

echo ""
echo "[9] Permissions..."
chown -R root:root "$HOME_DIR"

echo ""
echo "[10] Restarting service..."
systemctl restart "$SERVICE_NAME" || {
    echo "[ERR] Failed to restart service"
    exit 1
}

echo ""
echo "=== RESTORE COMPLETE ==="
echo "Snapshot applied: $SNAP_NAME"
echo "Rollback available: $BACKUP_NAME"
echo "Logs: journalctl -u $SERVICE_NAME -f"