#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT

HOME_DIR="$FIXTURE/home/.lumen"
mkdir -p "$HOME_DIR/config"
printf '{"chain_id":"lumen"}\n' > "$HOME_DIR/config/genesis.json"
printf '[p2p]\nladdr = "tcp://127.0.0.1:26656"\n' > "$HOME_DIR/config/config.toml"
printf '[api]\nenable = false\n' > "$HOME_DIR/config/app.toml"
printf 'role=fullnode\n' > "$HOME_DIR/validator-kit-role"

cat > "$FIXTURE/lumend" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == version ]]; then
  printf 'lumend %s\n' "${FAKE_LUMEND_VERSION:?}"
fi
EOF
chmod 0755 "$FIXTURE/lumend"

pass_report="$(FAKE_LUMEND_VERSION=2.0.0 LUMEN_NETWORK=mainnet \
  "$REPO_ROOT/scripts/doctor.sh" --home "$HOME_DIR" --binary "$FIXTURE/lumend")"
grep -q 'Network release.*v2.0.0' <<< "$pass_report"
grep -q 'lumend version.*2.0.0' <<< "$pass_report"

if FAKE_LUMEND_VERSION=v1.4.3 LUMEN_NETWORK=mainnet \
  "$REPO_ROOT/scripts/doctor.sh" --home "$HOME_DIR" --binary "$FIXTURE/lumend" \
  >/dev/null 2>&1; then
  echo "doctor accepted a mismatched direct binary" >&2
  exit 1
fi

echo "doctor version regression: passed"
