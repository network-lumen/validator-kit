#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT

mkdir -p "$FIXTURE/mock" "$FIXTURE/node/config" "$FIXTURE/node/data" "$FIXTURE/snapshot-data/data" "$FIXTURE/snapshots"
printf 'config-preserved\n' > "$FIXTURE/node/config/node_key.json"
printf 'consensus-key\n' > "$FIXTURE/node/config/priv_validator_key.json"
printf 'role=validator\n' > "$FIXTURE/node/validator-kit-role"
printf 'old-chain\n' > "$FIXTURE/node/data/old.db"
printf 'local-state\n' > "$FIXTURE/node/data/priv_validator_state.json"
printf 'new-chain\n' > "$FIXTURE/snapshot-data/data/new.db"
printf 'snapshot-state\n' > "$FIXTURE/snapshot-data/data/priv_validator_state.json"

hash_dir() {
  find "$1" -type f -printf '%P\0' | sort -z |
    while IFS= read -r -d '' rel; do sha256sum "$1/$rel" | awk '{print $1}'; done |
    sha256sum | awk '{print $1}'
}

hash="$(hash_dir "$FIXTURE/snapshot-data/data")"
printf '{"height":123,"timestamp":1,"sha256":"%s"}\n' "$hash" > "$FIXTURE/snapshot-data/snapshot.json"
tar -czf "$FIXTURE/snapshots/block_123_1.tar.gz" -C "$FIXTURE/snapshot-data" data snapshot.json

cat > "$FIXTURE/mock/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  is-active) exit 3 ;;
  stop|start) exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod 0755 "$FIXTURE/mock/systemctl"
cat > "$FIXTURE/mock/pgrep" <<'EOF'
#!/usr/bin/env bash
if [[ "${MOCK_LUMEND_RUNNING:-0}" == 1 ]]; then exit 0; fi
exit 1
EOF
chmod 0755 "$FIXTURE/mock/pgrep"

status_report="$("$REPO_ROOT/scripts/snapshot/snapshots_status.sh" "$FIXTURE/snapshots" --verify)"
grep -q 'Integrity: OK' <<< "$status_report"

fullnode="$FIXTURE/fullnode"
mkdir -p "$fullnode/config" "$fullnode/data"
printf 'fullnode-config\n' > "$fullnode/config/node_key.json"
printf 'fullnode-old\n' > "$fullnode/data/old.db"
PATH="$FIXTURE/mock:$PATH" "$REPO_ROOT/scripts/snapshot/restore_snapshot.sh" \
  --home "$fullnode" --snapshot "$FIXTURE/snapshots/block_123_1.tar.gz" \
  --snapshot-dir "$FIXTURE/snapshots" --non-interactive >/dev/null
[[ -f "$fullnode/data/new.db" ]]
[[ ! -e "$fullnode/data/old.db" ]]
[[ "$(cat "$fullnode/config/node_key.json")" == fullnode-config ]]

PATH="$FIXTURE/mock:$PATH" \
  "$REPO_ROOT/scripts/snapshot/restore_snapshot.sh" \
  --home "$FIXTURE/node" \
  --snapshot "$FIXTURE/snapshots/block_123_1.tar.gz" \
  --snapshot-dir "$FIXTURE/snapshots" \
  --non-interactive >/dev/null

[[ -f "$FIXTURE/node/data/new.db" ]]
[[ ! -e "$FIXTURE/node/data/old.db" ]]
[[ "$(cat "$FIXTURE/node/data/priv_validator_state.json")" == local-state ]]
[[ "$(cat "$FIXTURE/node/config/node_key.json")" == config-preserved ]]
[[ -f "$FIXTURE/node/config/priv_validator_key.json" ]]
[[ -f "$FIXTURE/node/validator-kit-role" ]]
backup="$(find "$FIXTURE/snapshots" -maxdepth 1 -type d -name 'recovery-safety-*' -print -quit)"
[[ -n "$backup" ]]
[[ "$(stat -c '%a' "$backup")" == 700 ]]
[[ "$(stat -c '%a' "$backup/config/priv_validator_key.json")" == 600 ]]

missing_state="$FIXTURE/missing-state"
cp -a "$FIXTURE/node" "$missing_state"
rm -f "$missing_state/data/priv_validator_state.json"
printf 'must-remain\\n' > "$missing_state/data/untouched.marker"
if PATH="$FIXTURE/mock:$PATH" "$REPO_ROOT/scripts/snapshot/restore_snapshot.sh" \
  --home "$missing_state" --snapshot "$FIXTURE/snapshots/block_123_1.tar.gz" \
  --snapshot-dir "$FIXTURE/snapshots" --non-interactive >/dev/null 2>&1; then
  echo "validator restore should reject missing signing state" >&2
  exit 1
fi
[[ -f "$missing_state/data/untouched.marker" ]]

unknown_state="$FIXTURE/unknown-state"
cp -a "$FIXTURE/node" "$unknown_state"
rm -f "$unknown_state/validator-kit-role" "$unknown_state/data/priv_validator_state.json"
if PATH="$FIXTURE/mock:$PATH" "$REPO_ROOT/scripts/snapshot/restore_snapshot.sh" \
  --home "$unknown_state" --snapshot "$FIXTURE/snapshots/block_123_1.tar.gz" \
  --snapshot-dir "$FIXTURE/snapshots" --non-interactive >/dev/null 2>&1; then
  echo "unknown role with consensus material should reject missing signing state" >&2
  exit 1
fi

corrupt="$FIXTURE/snapshots/corrupt.tar.gz"
printf 'not a tar archive\n' > "$corrupt"
if PATH="$FIXTURE/mock:$PATH" "$REPO_ROOT/scripts/snapshot/restore_snapshot.sh" \
  --home "$FIXTURE/node" --snapshot "$corrupt" --snapshot-dir "$FIXTURE/snapshots" \
  --non-interactive >/dev/null 2>&1; then
  echo "restore should reject a corrupt archive" >&2
  exit 1
fi
[[ -f "$FIXTURE/node/data/new.db" ]]

backup_blocker="$FIXTURE/backup-blocker"
printf 'not a directory\n' > "$backup_blocker"
if PATH="$FIXTURE/mock:$PATH" "$REPO_ROOT/scripts/snapshot/restore_snapshot.sh" \
  --home "$FIXTURE/node" --snapshot "$FIXTURE/snapshots/block_123_1.tar.gz" \
  --snapshot-dir "$backup_blocker" --non-interactive >/dev/null 2>&1; then
  echo "restore should fail when the safety-backup location is unavailable" >&2
  exit 1
fi
[[ -f "$FIXTURE/node/data/new.db" ]]

if MOCK_LUMEND_RUNNING=1 PATH="$FIXTURE/mock:$PATH" \
  "$REPO_ROOT/scripts/snapshot/restore_snapshot.sh" \
  --home "$FIXTURE/node" --snapshot "$FIXTURE/snapshots/block_123_1.tar.gz" \
  --snapshot-dir "$FIXTURE/snapshots" --non-interactive >/dev/null 2>&1; then
  echo "restore should reject a running lumend process" >&2
  exit 1
fi

bad="$FIXTURE/snapshots/bad.tar.gz"
mkdir -p "$FIXTURE/bad/data"
printf 'bad\n' > "$FIXTURE/bad/data/file"
printf '{}\n' > "$FIXTURE/bad/snapshot.json"
tar -czf "$bad" -C "$FIXTURE/bad" --transform='s,^data,../escape,' data snapshot.json
if PATH="$FIXTURE/mock:$PATH" "$REPO_ROOT/scripts/snapshot/restore_snapshot.sh" \
  --home "$FIXTURE/node" --snapshot "$bad" --non-interactive >/dev/null 2>&1; then
  echo "restore should reject archive traversal" >&2
  exit 1
fi
[[ -f "$FIXTURE/node/data/new.db" ]]

echo "snapshot restore regression: passed"
