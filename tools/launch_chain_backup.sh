#!/usr/bin/env bash
set -euo pipefail

echo ""
echo "=== Lumen Snapshot Auto-Installer ==="
echo ""

read -p "Node HOME directory? (/root/.lumen): " HOME_DIR
HOME_DIR=${HOME_DIR:-/root/.lumen}

read -p "Block interval between snapshots? (50): " INTERVAL
INTERVAL=${INTERVAL:-50}

read -p "Snapshots to keep? (10): " RETENTION
RETENTION=${RETENTION:-10}

read -p "Snapshot directory? (/root/snapshots): " SNAP_DIR
SNAP_DIR=${SNAP_DIR:-/root/snapshots}

echo ""
read -p "Install systemd service? (Y/n): " INSTALL_SYSTEMD
INSTALL_SYSTEMD=${INSTALL_SYSTEMD:-Y}

RPC="http://127.0.0.1:26657"
SNAP_SCRIPT="/usr/local/bin/lumen-snapshot.sh"

cat > "$SNAP_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

RPC="__RPC__"
SNAP_DIR="__SNAP_DIR__"
INTERVAL=__INTERVAL__
RETENTION=__RETENTION__
HOME_DIR="__HOME_DIR__"
SERVICE_NAME="${SERVICE_NAME:-lumend}"

hash_dir() {
  local dir="$1"
  find "$dir" -type f -printf '%P\0' \
    | sort -z \
    | while IFS= read -r -d '' rel; do
        sha256sum "$dir/$rel" | awk '{print $1}'
      done \
    | sha256sum | awk '{print $1}'
}

mkdir -p "$SNAP_DIR"

LOCK_FILE="$SNAP_DIR/.lumen-snapshot.lock"
exec 9> "$LOCK_FILE" || exit 0
if ! flock -n 9; then
  echo "[warn] snapshot script already running"
  exit 0
fi

while true; do
    raw=$(curl -s "$RPC/status" || true)
    if [[ -z "$raw" ]]; then
        sleep 1
        continue
    fi

    catching_up=$(echo "$raw" | jq -r '.result.sync_info.catching_up // empty')
    if [[ "$catching_up" == "true" ]]; then
        sleep 1
        continue
    fi

    height=$(echo "$raw" | jq -r '.result.sync_info.latest_block_height // empty')
    if [[ -z "$height" ]]; then
        sleep 1
        continue
    fi

    found=$(find "$SNAP_DIR" -maxdepth 1 -type f -name "block_${height}_*.tar.gz" | wc -l)
    if (( found > 0 )); then
        sleep 1
        continue
    fi

    if ! (( height % INTERVAL == 0 )); then
        sleep 1
        continue
    fi

    echo "[*] Stopping $SERVICE_NAME for snapshot..."
    systemctl stop "$SERVICE_NAME" || true

    TMP_DIR=$(mktemp -d)
    if ! cp -r "$HOME_DIR/data" "$TMP_DIR/data" 2>/dev/null; then
        echo "[error] failed to copy data directory"
        rm -rf "$TMP_DIR"
        systemctl start "$SERVICE_NAME" || true
        sleep 1
        continue
    fi

    echo "[*] Starting $SERVICE_NAME again..."
    systemctl start "$SERVICE_NAME" || true

    DATA_HASH=$(hash_dir "$TMP_DIR/data")
    now_ts=$(date +%s)

    cat > "$TMP_DIR/snapshot.json" <<JSON
{
  "height": $height,
  "timestamp": $now_ts,
  "sha256": "$DATA_HASH"
}
JSON

    SNAP_NAME="block_${height}_${now_ts}.tar.gz"
    echo "[+] Snapshot height=$height -> $SNAP_DIR/$SNAP_NAME"

    if ! tar -czf "$SNAP_DIR/$SNAP_NAME" -C "$TMP_DIR" data snapshot.json; then
        echo "[error] tar failed"
        rm -rf "$TMP_DIR"
        sleep 1
        continue
    fi

    rm -rf "$TMP_DIR"

    total=$(find "$SNAP_DIR" -maxdepth 1 -type f -name "block_*.tar.gz" | wc -l)
    if (( total > RETENTION )); then
        to_delete=$(( total - RETENTION ))
        echo "[*] purging $to_delete old snapshots"
        find "$SNAP_DIR" -maxdepth 1 -type f -name "block_*.tar.gz" -printf "%T@ %p\n" | sort -n | head -n "$to_delete" | awk '{print $2}' | xargs -r rm -f --
    fi

    sleep 1
done
EOF

sed -i \
  -e "s|__RPC__|$RPC|g" \
  -e "s|__SNAP_DIR__|$SNAP_DIR|g" \
  -e "s|__INTERVAL__|$INTERVAL|g" \
  -e "s|__RETENTION__|$RETENTION|g" \
  -e "s|__HOME_DIR__|$HOME_DIR|g" \
  "$SNAP_SCRIPT"

chmod +x "$SNAP_SCRIPT"
echo "[OK] Snapshot script installed at $SNAP_SCRIPT"

if [[ "$INSTALL_SYSTEMD" =~ ^[Yy]$ ]]; then

    SERVICE_FILE="/etc/systemd/system/lumen-snapshot.service"
    TIMER_FILE="/etc/systemd/system/lumen-snapshot.timer"

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Lumen automatic snapshots
After=network-online.target lumen.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=$SNAP_SCRIPT
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    cat > "$TIMER_FILE" <<EOF
[Unit]
Description=Lumen snapshot timer

[Timer]
OnBootSec=10
OnUnitActiveSec=2
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now lumen-snapshot.timer

    echo "[OK] Systemd service installed: $SERVICE_FILE"
    echo "[OK] Systemd timer installed: $TIMER_FILE"
    echo "[OK] Snapshot loop is active"
else
    echo "Systemd installation skipped."
fi

echo ""
echo "Installation complete"
echo "Check: systemctl status lumen-snapshot"