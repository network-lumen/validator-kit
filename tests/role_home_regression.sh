#!/usr/bin/env bash
set -euo pipefail

# Exercise init_node.sh through binary handling and join.sh without downloads,
# systemd changes, or writes outside a temporary fixture.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FIXTURE="$(mktemp -d)"
trap 'rm -rf "${FIXTURE}"' EXIT

cp -a "${REPO_ROOT}" "${FIXTURE}/repo"
mkdir -p "${FIXTURE}/mock" "${FIXTURE}/bin"

cat > "${FIXTURE}/repo/bin/lumend" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == version ]]; then
  echo "lumend v1.4.3"
  exit 0
fi

if [[ "${1:-}" == init ]]; then
  home=""
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == --home ]]; then
      home="$2"
      shift
    fi
    shift
  done
  mkdir -p "${home}/config"
  if [[ "${LUMEN_FAKE_FAIL_INIT:-0}" == 1 ]]; then
    exit 1
  fi
  exit 0
fi

exit 0
EOF
chmod 0755 "${FIXTURE}/repo/bin/lumend"

cat > "${FIXTURE}/repo/scripts/install/download_lumend.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: "${LUMEN_TARGET:?init_node must pass the selected binary target}"
printf '%s\n' "${LUMEN_TARGET}" > "${LUMEN_TARGET_LOG:?}"
EOF
chmod 0755 "${FIXTURE}/repo/scripts/install/download_lumend.sh"

cat > "${FIXTURE}/repo/scripts/install/lumend_service.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
EOF
chmod 0755 "${FIXTURE}/repo/scripts/install/lumend_service.sh"

cat > "${FIXTURE}/repo/scripts/network/reload_peers.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
EOF
chmod 0755 "${FIXTURE}/repo/scripts/network/reload_peers.sh"

cat > "${FIXTURE}/mock/jq" <<'EOF'
#!/usr/bin/env bash
echo lumen
EOF
chmod 0755 "${FIXTURE}/mock/jq"

cat > "${FIXTURE}/mock/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == *=* ]]; then
  exec env "$@"
fi
exec "$@"
EOF
chmod 0755 "${FIXTURE}/mock/sudo"

cat > "${FIXTURE}/mock/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 0755 "${FIXTURE}/mock/systemctl"

run_init() {
  local role="$1"
  local home="$2"
  local fail_init="${3:-0}"
  LUMEN_HOME="${home}" \
  LUMEN_TARGET="${FIXTURE}/bin/lumend" \
  LUMEN_TARGET_LOG="${FIXTURE}/target.log" \
  LUMEN_FAKE_FAIL_INIT="${fail_init}" \
  HOME="${FIXTURE}/operator" \
  PATH="${FIXTURE}/mock:${PATH}" \
    "${FIXTURE}/repo/scripts/init_node.sh" "fixture-${role}" --role "${role}" --non-interactive
}

for role in fullnode validator; do
  home="${FIXTURE}/${role}/.lumen"
  run_init "${role}" "${home}" >/dev/null
  [[ -f "${home}/validator-kit-role" ]]
  [[ "$(cat "${FIXTURE}/target.log")" == "${FIXTURE}/bin/lumend" ]]
done

failed_home="${FIXTURE}/failed/.lumen"
if run_init validator "${failed_home}" 1 >/dev/null 2>&1; then
  echo "expected failed fresh initialization to fail" >&2
  exit 1
fi
[[ ! -e "${failed_home}/validator-kit-role" ]]

existing_home="${FIXTURE}/existing/.lumen"
mkdir -p "${existing_home}"
printf 'keep-me\n' > "${existing_home}/sentinel"
if run_init validator "${existing_home}" >/dev/null 2>&1; then
  echo "expected existing-home protection to fail" >&2
  exit 1
fi
[[ "$(cat "${existing_home}/sentinel")" == keep-me ]]

unsafe_home="${FIXTURE}/unsafe/.lumen"
if LUMEN_HOME="${unsafe_home}" \
  LUMEN_TARGET="${unsafe_home}/lumend" \
  LUMEN_TARGET_LOG="${FIXTURE}/target.log" \
  HOME="${FIXTURE}/operator" \
  PATH="${FIXTURE}/mock:${PATH}" \
    "${FIXTURE}/repo/scripts/init_node.sh" fixture-unsafe --role validator --non-interactive >/dev/null 2>&1; then
  echo "expected binary-inside-home protection to fail" >&2
  exit 1
fi
[[ ! -e "${unsafe_home}" ]]

echo "role home regression: passed"
