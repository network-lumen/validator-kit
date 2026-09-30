#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT

mkdir -p "$FIXTURE/bin"
cp -a "$REPO_ROOT" "$FIXTURE/repo"
TEST_REPO="$FIXTURE/repo"
cat > "$FIXTURE/bin/lumend" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == version ]]; then
  printf 'lumend %s\n' "${FAKE_LUMEND_VERSION:-VERSION_PLACEHOLDER}"
fi
EOF
chmod 0755 "$FIXTURE/bin/lumend"

make_archive() {
  local version="$1"
  sed "s/VERSION_PLACEHOLDER/$version/" "$FIXTURE/bin/lumend" > "$FIXTURE/lumend"
  chmod 0755 "$FIXTURE/lumend"
  tar -czf "$FIXTURE/linux-amd64-$version.tar.gz" \
    --transform="s,^lumend$,linux-amd64-$version," \
    -C "$FIXTURE" lumend
  sha256sum "$FIXTURE/linux-amd64-$version.tar.gz" |
    awk "{print \$1 \"  linux-amd64-$version.tar.gz\"}" > "$FIXTURE/SHA256SUMS-$version"
}

make_archive v2.0.0
make_archive v1.4.3

target="$FIXTURE/installed-lumend"
metadata_report="$(LUMEN_NETWORK=mainnet LUMEN_TARGET="$target" \
  LUMEN_RELEASE_URL="file://$FIXTURE/linux-amd64-v2.0.0.tar.gz" \
  LUMEN_CHECKSUM_URL="file://$FIXTURE/SHA256SUMS-v2.0.0" \
  "$TEST_REPO/scripts/install/download_lumend.sh")"
grep -q 'Network:  mainnet' <<< "$metadata_report"
grep -q 'Source:   network metadata' <<< "$metadata_report"
[[ -x "$target" ]]

override_report="$(LUMEN_NETWORK=mainnet LUMEN_RELEASE_TAG=v1.4.3 \
  LUMEN_TARGET="$FIXTURE/override-lumend" \
  LUMEN_RELEASE_URL="file://$FIXTURE/linux-amd64-v1.4.3.tar.gz" \
  LUMEN_CHECKSUM_URL="file://$FIXTURE/SHA256SUMS-v1.4.3" \
  "$TEST_REPO/scripts/install/download_lumend.sh")"
grep -q 'Source:   explicit override (LUMEN_RELEASE_TAG)' <<< "$override_report"

if LUMEN_NETWORK=missing-network LUMEN_TARGET="$FIXTURE/missing" \
  "$TEST_REPO/scripts/install/download_lumend.sh" >/dev/null 2>&1; then
  echo "missing network metadata unexpectedly succeeded" >&2
  exit 1
fi

invalid_env="$TEST_REPO/networks/mainnet/release.env"
printf 'LUMEND_VERSION="not-a-version"\n' > "$invalid_env"
trap 'rm -rf "$FIXTURE" "$invalid_env"' EXIT
if LUMEN_NETWORK=mainnet LUMEN_TARGET="$FIXTURE/invalid" \
  LUMEN_RELEASE_URL="file://$FIXTURE/linux-amd64-v2.0.0.tar.gz" \
  LUMEN_CHECKSUM_URL="file://$FIXTURE/SHA256SUMS-v2.0.0" \
  "$TEST_REPO/scripts/install/download_lumend.sh" >/dev/null 2>&1; then
  echo "invalid network metadata unexpectedly succeeded" >&2
  exit 1
fi

echo "version resolution regression: passed"
