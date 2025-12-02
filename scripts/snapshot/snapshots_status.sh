#!/usr/bin/env bash
set -euo pipefail

SNAP_DIR="${1:-/root/snapshots}"
MODE="${2:---verify}"

echo "========================================="
echo "         Snapshot Status Report"
echo "========================================="
echo "[i] Snapshot directory: $SNAP_DIR"
echo "[i] Verify integrity:   $MODE"
echo ""

if [[ ! -d "$SNAP_DIR" ]]; then
    echo "[ERR] Snapshot directory not found"
    exit 1
fi

mapfile -t FILES < <(find "$SNAP_DIR" -maxdepth 1 -type f -name "block_*.tar.gz" | sort)

if (( ${#FILES[@]} == 0 )); then
    echo "[i] No snapshots found."
    exit 0
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

idx=1
for f in "${FILES[@]}"; do
    fname=$(basename "$f")
    height=$(echo "$fname" | sed -E 's/^block_([0-9]+)_.*/\1/')
    ts=$(echo "$fname" | sed -E 's/^block_[0-9]+_([0-9]+)\.tar\.gz/\1/')

    if [[ "$ts" =~ ^[0-9]+$ ]]; then
        human_ts=$(date -d @"$ts" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$ts")
    else
        human_ts="unknown"
    fi

    size=$(du -h "$f" | awk '{print $1}')

    echo "[$idx] $fname"
    echo "     Height:    $height"
    echo "     Timestamp: $human_ts"
    echo "     Size:      $size"

    if tar -tzf "$f" >/dev/null 2>&1; then
        echo "     Readable:  yes"
    else
        echo "     Readable:  NO"
        echo ""
        ((idx++))
        continue
    fi

    if [[ "$MODE" == "--verify" ]]; then
        tmp=$(mktemp -d)
        tar -xzf "$f" -C "$tmp"

        if [[ ! -f "$tmp/snapshot.json" ]]; then
            echo "     Integrity: snapshot.json missing"
            rm -rf "$tmp"
            echo ""
            ((idx++))
            continue
        fi

        expected=$(jq -r .sha256 "$tmp/snapshot.json")

        if [[ ! -d "$tmp/data" ]]; then
            echo "     Integrity: data missing"
            rm -rf "$tmp"
            echo ""
            ((idx++))
            continue
        fi

        actual=$(hash_dir "$tmp/data")

        if [[ "$expected" == "$actual" ]]; then
            echo "     Integrity: OK"
        else
            echo "     Integrity: FAIL"
            echo "       expected: $expected"
            echo "       actual:   $actual"
        fi

        rm -rf "$tmp"
    fi

    echo ""
    ((idx++))
done

echo "========================================="
echo "Done."