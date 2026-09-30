#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT

cp -a "$REPO_ROOT" "$FIXTURE/repo"
mkdir -p "$FIXTURE/mock" "$FIXTURE/archive"

cat > "$FIXTURE/repo/bin/lumend" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  version)
    printf '%s\n' 'lumend v1.4.3'
    ;;
  init)
    home=""
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == --home ]]; then home="$2"; shift; fi
      shift
    done
    mkdir -p "$home/config"
    ;;
  config) ;;
  *) echo "unexpected lumend command: $*" >&2; exit 1 ;;
esac
EOF
chmod 0755 "$FIXTURE/repo/bin/lumend"
cp "$FIXTURE/repo/bin/lumend" "$FIXTURE/archive/linux-amd64-v1.4.3"
tar -czf "$FIXTURE/linux-amd64-v1.4.3.tar.gz" -C "$FIXTURE/archive" linux-amd64-v1.4.3
sha256sum "$FIXTURE/linux-amd64-v1.4.3.tar.gz" |
  awk '{print $1 "  linux-amd64-v1.4.3.tar.gz"}' > "$FIXTURE/SHA256SUMS"

cat > "$FIXTURE/cosmovisor" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == version ]]; then printf '%s\n' 'cosmovisor v1.7.3'; fi
EOF
chmod 0755 "$FIXTURE/cosmovisor"

cat > "$FIXTURE/mock/jq" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' lumen
EOF
chmod 0755 "$FIXTURE/mock/jq"

cat > "$FIXTURE/mock/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == *=* ]]; then
  exec env "$@"
fi
exec "$@"
EOF
chmod 0755 "$FIXTURE/mock/sudo"

cat > "$FIXTURE/repo/scripts/install/lumend_service.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mode=direct
cosmovisor=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) mode="$2"; shift 2 ;;
    --cosmovisor-bin) cosmovisor="$2"; shift 2 ;;
    --non-interactive) shift ;;
    *) break ;;
  esac
done
home="${1:?missing home}"
printf '%s|%s|%s\n' "$mode" "$cosmovisor" "$home" >> "${SERVICE_LOG:?}"
if [[ "$mode" == cosmovisor ]]; then
  [[ -x "$home/cosmovisor/genesis/bin/lumend" ]]
  cat > "${UNIT_OUTPUT:?}" <<UNIT
Environment=DAEMON_NAME=lumend
Environment=DAEMON_HOME=$home
Environment=DAEMON_ALLOW_DOWNLOAD_BINARIES=false
Environment=DAEMON_RESTART_AFTER_UPGRADE=true
ExecStart=$cosmovisor run start --home $home
Restart=on-failure
LimitNOFILE=65535
UNIT
else
  cat > "${UNIT_OUTPUT:?}" <<UNIT
ExecStart=$LUMEND_BIN start --home $home
UNIT
fi
EOF
chmod 0755 "$FIXTURE/repo/scripts/install/lumend_service.sh"

run_deploy() {
  local role="$1" home="$FIXTURE/$1/.lumen" unit="$FIXTURE/$1.unit"
  SERVICE_LOG="$FIXTURE/services.log" UNIT_OUTPUT="$unit" \
  LUMEN_HOME="$home" COSMOVISOR_BIN="$FIXTURE/cosmovisor" \
  LUMEN_RELEASE_TAG=v1.4.3 \
  LUMEN_RELEASE_URL="file://$FIXTURE/linux-amd64-v1.4.3.tar.gz" \
  LUMEN_CHECKSUM_URL="file://$FIXTURE/SHA256SUMS" \
  HOME="$FIXTURE/$role" PATH="$FIXTURE/mock:$PATH" \
    "$FIXTURE/repo/scripts/lumen-node" deploy "fixture-$role" \
    --role "$role" --network mainnet --non-interactive >/dev/null
  [[ -x "$home/cosmovisor/genesis/bin/lumend" ]]
  [[ -d "$home/cosmovisor/upgrades" ]]
  [[ "$(cat "$home/validator-kit-role")" == "role=$role" ]]
  grep -q "Environment=DAEMON_NAME=lumend" "$unit"
  grep -q "Environment=DAEMON_HOME=$home" "$unit"
grep -q "Environment=DAEMON_ALLOW_DOWNLOAD_BINARIES=false" "$unit"
grep -q "ExecStart=$FIXTURE/cosmovisor run start --home $home" "$unit"
grep -q "Restart=on-failure" "$unit"
grep -q "LimitNOFILE=65535" "$unit"
}

: > "$FIXTURE/services.log"
# Prove fresh deployment can consume network metadata without an explicit
# LUMEN_RELEASE_TAG override. The fixture uses v1.4.3 only to avoid downloads.
printf 'LUMEND_VERSION="v1.4.3"\n' > "$FIXTURE/repo/networks/mainnet/release.env"
network_default_home="$FIXTURE/network-default/.lumen"
SERVICE_LOG="$FIXTURE/services.log" UNIT_OUTPUT="$FIXTURE/network-default.unit" \
  LUMEN_HOME="$network_default_home" COSMOVISOR_BIN="$FIXTURE/cosmovisor" \
  LUMEN_RELEASE_URL="file://$FIXTURE/linux-amd64-v1.4.3.tar.gz" \
  LUMEN_CHECKSUM_URL="file://$FIXTURE/SHA256SUMS" \
  HOME="$FIXTURE/network-default" PATH="$FIXTURE/mock:$PATH" \
    "$FIXTURE/repo/scripts/lumen-node" deploy network-default --non-interactive >/dev/null
[[ -x "$network_default_home/cosmovisor/genesis/bin/lumend" ]]

for role in fullnode rpc validator sentry seed; do
  run_deploy "$role"
done
[[ "$(grep -c '^cosmovisor|' "$FIXTURE/services.log")" -eq 5 ]]

existing_cosmovisor="$FIXTURE/existing-cosmovisor"
rm -f "$FIXTURE/cosmovisor"
cat > "$existing_cosmovisor" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == version && "${2:-}" == --cosmovisor-only ]]; then
  printf '%s\n' 'cosmovisor v1.7.3'
else
  printf '%s\n' 'DAEMON_NAME is not set' >&2
  printf '%s\n' 'cosmovisor version: v1.7.3'
fi
EOF
chmod 0755 "$existing_cosmovisor"
ln -s "$existing_cosmovisor" "$FIXTURE/cosmovisor"
existing_before="$(sha256sum "$existing_cosmovisor")"
existing_home="$FIXTURE/reused/.lumen"
no_go_path="$FIXTURE/mock:$FIXTURE:/usr/bin:/bin"
no_go_no_cosmo_path="$FIXTURE/mock:/usr/bin:/bin"
existing_output="$(SERVICE_LOG="$FIXTURE/services.log" UNIT_OUTPUT="$FIXTURE/reused.unit" \
  LUMEN_HOME="$existing_home" LUMEN_RELEASE_TAG=v1.4.3 \
  LUMEN_RELEASE_URL="file://$FIXTURE/linux-amd64-v1.4.3.tar.gz" \
  LUMEN_CHECKSUM_URL="file://$FIXTURE/SHA256SUMS" \
  HOME="$FIXTURE/reused" PATH="$no_go_path" \
  "$FIXTURE/repo/scripts/lumen-node" deploy reused-node --non-interactive 2>&1)"
grep -q "ExecStart=$existing_cosmovisor run start --home $existing_home" "$FIXTURE/reused.unit"
[[ "$(sha256sum "$existing_cosmovisor")" == "$existing_before" ]]
grep -q "Version: cosmovisor v1.7.3" <<< "$existing_output"
if grep -q 'DAEMON_NAME is not set' <<< "$existing_output"; then
  echo "Cosmovisor probe leaked daemon configuration errors" >&2
  exit 1
fi

cat > "$existing_cosmovisor" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == version && "${2:-}" == --cosmovisor-only ]]; then
  printf '%s\n' 'cosmovisor v9.8.7'
fi
EOF
if SERVICE_LOG="$FIXTURE/services.log" UNIT_OUTPUT="$FIXTURE/mismatch.unit" \
  LUMEN_HOME="$FIXTURE/mismatch/.lumen" LUMEN_RELEASE_TAG=v1.4.3 \
  LUMEN_RELEASE_URL="file://$FIXTURE/linux-amd64-v1.4.3.tar.gz" \
  LUMEN_CHECKSUM_URL="file://$FIXTURE/SHA256SUMS" HOME="$FIXTURE/mismatch" \
  PATH="$no_go_path" "$FIXTURE/repo/scripts/lumen-node" deploy mismatch-node \
  --non-interactive >/dev/null 2>&1; then
  echo "incompatible Cosmovisor was accepted" >&2
  exit 1
fi

rm -f "$FIXTURE/cosmovisor"
if PATH="$no_go_path" command -v go >/dev/null 2>&1; then
  echo "test fixture unexpectedly exposed Go" >&2
  exit 1
fi

cat > "$FIXTURE/repo/scripts/install/install_cosmovisor.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
command -v go >/dev/null 2>&1 || { echo "Go was not visible through forwarded PATH" >&2; exit 1; }
cat > "$FIXTURE_COSMOVISOR" <<'COSMOVISOR'
#!/usr/bin/env bash
if [[ "${1:-}" == version ]]; then printf '%s\n' 'cosmovisor v1.7.3'; fi
COSMOVISOR
chmod 0755 "$FIXTURE_COSMOVISOR"
printf 'installed fixture Cosmovisor\nCOSMOVISOR_PATH=%s\n' "$FIXTURE_COSMOVISOR"
EOF
chmod 0755 "$FIXTURE/repo/scripts/install/install_cosmovisor.sh"
cat > "$FIXTURE/mock/go" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'go version go1.26.4 linux/amd64'
EOF
chmod 0755 "$FIXTURE/mock/go"
install_home="$FIXTURE/installed/.lumen"
SERVICE_LOG="$FIXTURE/services.log" UNIT_OUTPUT="$FIXTURE/installed.unit" \
  FIXTURE_COSMOVISOR="$FIXTURE/mock/cosmovisor" LUMEN_HOME="$install_home" \
  LUMEN_RELEASE_TAG=v1.4.3 LUMEN_RELEASE_URL="file://$FIXTURE/linux-amd64-v1.4.3.tar.gz" \
  LUMEN_CHECKSUM_URL="file://$FIXTURE/SHA256SUMS" HOME="$FIXTURE/installed" \
  PATH="$FIXTURE/mock:$PATH" "$FIXTURE/repo/scripts/lumen-node" deploy installed-node \
  --non-interactive >/dev/null
grep -q "ExecStart=$FIXTURE/mock/cosmovisor run start --home $install_home" "$FIXTURE/installed.unit"
rm -f "$FIXTURE/mock/cosmovisor"

direct_home="$FIXTURE/direct/.lumen"
direct_unit="$FIXTURE/direct.unit"
SERVICE_LOG="$FIXTURE/services.log" UNIT_OUTPUT="$direct_unit" \
LUMEN_HOME="$direct_home" LUMEN_TARGET="$FIXTURE/direct-lumend" \
LUMEN_RELEASE_TAG=v1.4.3 \
LUMEN_RELEASE_URL="file://$FIXTURE/linux-amd64-v1.4.3.tar.gz" \
LUMEN_CHECKSUM_URL="file://$FIXTURE/SHA256SUMS" \
  HOME="$FIXTURE/direct" PATH="$FIXTURE/mock:$PATH" \
  "$FIXTURE/repo/scripts/lumen-node" deploy direct-node \
  --role fullnode --service-mode direct --non-interactive >/dev/null
grep -q '^direct|' "$FIXTURE/services.log"
grep -q "ExecStart=$FIXTURE/direct-lumend start --home $direct_home" "$direct_unit"
if grep -q 'DAEMON_NAME' "$direct_unit"; then
  echo "direct deployment unexpectedly generated Cosmovisor unit" >&2
  exit 1
fi

existing_home="$FIXTURE/existing/.lumen"
mkdir -p "$existing_home"
if LUMEN_HOME="$existing_home" HOME="$FIXTURE/existing" \
  PATH="$FIXTURE/mock:$PATH" "$FIXTURE/repo/scripts/lumen-node" deploy existing >/dev/null 2>&1; then
  echo "existing node home was not refused" >&2
  exit 1
fi

cat > "$FIXTURE/repo/scripts/install/install_cosmovisor.sh" <<'EOF'
#!/usr/bin/env bash
echo "mock Cosmovisor installation failure" >&2
exit 77
EOF
chmod 0755 "$FIXTURE/repo/scripts/install/install_cosmovisor.sh"
rm -f "$FIXTURE/failing-services.log"
if SERVICE_LOG="$FIXTURE/failing-services.log" UNIT_OUTPUT="$FIXTURE/failing.unit" \
  LUMEN_HOME="$FIXTURE/cosmo-failure/.lumen" HOME="$FIXTURE/cosmo-failure" \
  LUMEN_RELEASE_TAG=v1.4.3 \
  LUMEN_RELEASE_URL="file://$FIXTURE/linux-amd64-v1.4.3.tar.gz" \
  LUMEN_CHECKSUM_URL="file://$FIXTURE/SHA256SUMS" PATH="$no_go_no_cosmo_path" \
  "$FIXTURE/repo/scripts/lumen-node" deploy failed-cosmo --non-interactive >/dev/null 2>&1; then
  echo "Cosmovisor installation failure was swallowed" >&2
  exit 1
fi
[[ ! -e "$FIXTURE/failing-services.log" ]]

cp "$FIXTURE/repo/scripts/network/state_sync.sh" "$FIXTURE/repo/scripts/network/state_sync.real"
cat > "$FIXTURE/repo/scripts/network/state_sync.sh" <<'EOF'
#!/usr/bin/env bash
echo "mock state-sync failure" >&2
exit 78
EOF
chmod 0755 "$FIXTURE/repo/scripts/network/state_sync.sh"
rm -f "$FIXTURE/state-sync-services.log"
if SERVICE_LOG="$FIXTURE/state-sync-services.log" UNIT_OUTPUT="$FIXTURE/state-sync.unit" \
  LUMEN_HOME="$FIXTURE/sync-failure/.lumen" COSMOVISOR_BIN="$FIXTURE/cosmovisor" \
  LUMEN_RELEASE_TAG=v1.4.3 \
  LUMEN_RELEASE_URL="file://$FIXTURE/linux-amd64-v1.4.3.tar.gz" \
  LUMEN_CHECKSUM_URL="file://$FIXTURE/SHA256SUMS" PATH="$FIXTURE/mock:$PATH" \
  "$FIXTURE/repo/scripts/lumen-node" deploy failed-sync --rpc http://rpc.invalid:26657 \
  --non-interactive >/dev/null 2>&1; then
  echo "state-sync failure was swallowed" >&2
  exit 1
fi
[[ ! -e "$FIXTURE/state-sync-services.log" ]]

echo "deployment regression: passed"
