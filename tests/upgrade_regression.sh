#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT

mkdir -p "$FIXTURE/home/config" "$FIXTURE/home/data" "$FIXTURE/home/cosmovisor/genesis/bin"
cp "$REPO_ROOT/config/fullnode/"*.toml "$FIXTURE/home/config/"
cp "$REPO_ROOT/networks/mainnet/genesis.json" "$FIXTURE/home/config/"
printf 'old-chain\n' > "$FIXTURE/home/data/chain.db"
printf 'local-signing-state\n' > "$FIXTURE/home/data/priv_validator_state.json"
printf 'role=fullnode\n' > "$FIXTURE/home/validator-kit-role"

cat > "$FIXTURE/direct-lumend" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == version ]]; then echo "lumend v1.6.0"; fi
EOF
chmod 0755 "$FIXTURE/direct-lumend"
cp "$FIXTURE/direct-lumend" "$FIXTURE/home/cosmovisor/genesis/bin/lumend"
chmod 0755 "$FIXTURE/home/cosmovisor/genesis/bin/lumend"

cat > "$FIXTURE/cosmovisor" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == version ]]; then echo "cosmovisor v1.6.0"; fi
EOF
chmod 0755 "$FIXTURE/cosmovisor"

direct_unit="$(LUMEND_BIN="$FIXTURE/direct-lumend" \
  "$REPO_ROOT/scripts/install/lumend_service.sh" --print-unit \
  --mode direct "$FIXTURE/home" nodeuser)"
grep -q "ExecStart=$FIXTURE/direct-lumend start --home $FIXTURE/home" <<< "$direct_unit"
if grep -q "DAEMON_NAME" <<< "$direct_unit"; then
  echo "direct unit unexpectedly contains Cosmovisor environment" >&2
  exit 1
fi

cosmo_unit="$("$REPO_ROOT/scripts/install/lumend_service.sh" --print-unit \
  --mode cosmovisor --cosmovisor-bin "$FIXTURE/cosmovisor" "$FIXTURE/home" nodeuser)"
grep -q "Environment=DAEMON_NAME=lumend" <<< "$cosmo_unit"
grep -q "Environment=DAEMON_HOME=$FIXTURE/home" <<< "$cosmo_unit"
grep -q "Environment=DAEMON_ALLOW_DOWNLOAD_BINARIES=false" <<< "$cosmo_unit"
grep -q "ExecStart=$FIXTURE/cosmovisor run start --home $FIXTURE/home" <<< "$cosmo_unit"

mkdir -p "$FIXTURE/archive"
cp "$FIXTURE/direct-lumend" "$FIXTURE/archive/linux-amd64-v1.6.0"
tar -czf "$FIXTURE/linux-amd64-v1.6.0.tar.gz" -C "$FIXTURE/archive" linux-amd64-v1.6.0
sha256sum "$FIXTURE/linux-amd64-v1.6.0.tar.gz" |
  awk '{print $1 "  linux-amd64-v1.6.0.tar.gz"}' > "$FIXTURE/SHA256SUMS"

mkdir -p "$FIXTURE/mock"
cat > "$FIXTURE/mock/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl must not be called during preparation" >&2
exit 99
EOF
chmod 0755 "$FIXTURE/mock/systemctl"

LUMEN_RELEASE_URL="file://$FIXTURE/linux-amd64-v1.6.0.tar.gz" \
LUMEN_CHECKSUM_URL="file://$FIXTURE/SHA256SUMS" \
PATH="$FIXTURE/mock:$PATH" \
  "$REPO_ROOT/scripts/upgrade/prepare_upgrade.sh" \
  --home "$FIXTURE/home" --name governance-v1 --version v1.6.0

target="$FIXTURE/home/cosmovisor/upgrades/governance-v1/bin/lumend"
[[ -x "$target" ]]
[[ "$("$target" version)" == "lumend v1.6.0" ]]
[[ "$(cat "$FIXTURE/home/data/chain.db")" == old-chain ]]
[[ "$(cat "$FIXTURE/home/data/priv_validator_state.json")" == local-signing-state ]]

LUMEN_RELEASE_URL="file://$FIXTURE/linux-amd64-v1.6.0.tar.gz" \
LUMEN_CHECKSUM_URL="file://$FIXTURE/SHA256SUMS" \
  "$REPO_ROOT/scripts/upgrade/prepare_upgrade.sh" \
  --home "$FIXTURE/home" --name governance-v1 --version v1.6.0 >/dev/null

if LUMEN_RELEASE_URL="file://$FIXTURE/linux-amd64-v1.6.0.tar.gz" \
  LUMEN_CHECKSUM_URL="file://$FIXTURE/SHA256SUMS" \
  "$REPO_ROOT/scripts/upgrade/prepare_upgrade.sh" \
  --home "$FIXTURE/home" --name governance-v1 --version v1.7.0 >/dev/null 2>&1; then
  echo "already-prepared upgrade accepted a mismatched version" >&2
  exit 1
fi

mkdir -p "$FIXTURE/home/cosmovisor/upgrades/partial"
if "$REPO_ROOT/scripts/upgrade/prepare_upgrade.sh" \
  --home "$FIXTURE/home" --name partial --version v1.6.0 >/dev/null 2>&1; then
  echo "partial upgrade directory should be rejected" >&2
  exit 1
fi
for bad_name in "../escape" "bad/name" "-bad"; do
  if "$REPO_ROOT/scripts/upgrade/prepare_upgrade.sh" \
    --home "$FIXTURE/home" --name "$bad_name" --version v1.6.0 >/dev/null 2>&1; then
    echo "malformed upgrade name accepted: $bad_name" >&2
    exit 1
  fi
done

status_output="$("$REPO_ROOT/scripts/upgrade/status_upgrade.sh" --home "$FIXTURE/home")"
grep -q "Prepared upgrade governance-v1" <<< "$status_output"
mkdir -p "$FIXTURE/empty"
empty_status="$("$REPO_ROOT/scripts/upgrade/status_upgrade.sh" --home "$FIXTURE/empty")"
grep -q "Prepared upgrades: none" <<< "$empty_status"

cat > "$FIXTURE/mock/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  list-unit-files) echo "lumend.service enabled" ;;
  is-enabled) echo enabled ;;
  is-active) echo active ;;
  show)
    if [[ "$*" == *"ExecStart"* ]]; then
      if [[ -v MOCK_SERVICE_MODE && "$MOCK_SERVICE_MODE" == cosmovisor ]]; then
        echo "/tmp/cosmovisor run start --home /tmp/home"
      else
        echo "/tmp/lumend start --home /tmp/home"
      fi
    else
      echo 0
    fi
    ;;
esac
EOF
chmod 0755 "$FIXTURE/mock/systemctl"

direct_doctor="$(PATH="$FIXTURE/mock:$PATH" MOCK_SERVICE_MODE=direct \
  "$REPO_ROOT/scripts/doctor.sh" --home "$FIXTURE/home" --binary "$FIXTURE/direct-lumend" 2>&1 || true)"
grep -q "Direct lumend service model" <<< "$direct_doctor"

cosmo_doctor="$(PATH="$FIXTURE/mock:$PATH" MOCK_SERVICE_MODE=cosmovisor \
  "$REPO_ROOT/scripts/doctor.sh" --home "$FIXTURE/home" --binary "$FIXTURE/direct-lumend" 2>&1 || true)"
grep -q "Cosmovisor service model" <<< "$cosmo_doctor"
grep -q "active Cosmovisor child could not be determined" <<< "$cosmo_doctor"

echo "upgrade regression: passed"
