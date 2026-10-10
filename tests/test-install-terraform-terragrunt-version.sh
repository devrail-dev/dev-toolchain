#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_TEST}"' EXIT

FAKE_BIN="${TMPDIR_TEST}/bin"
mkdir -p "${FAKE_BIN}"

for tool in tflint terraform-docs checkov terraform; do
  cat >"${FAKE_BIN}/${tool}" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${FAKE_BIN}/${tool}"
done

cat >"${FAKE_BIN}/jq" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' "${DEVRAIL_TEST_JQ_OUTPUT:-}"
EOF
chmod +x "${FAKE_BIN}/jq"

cat >"${FAKE_BIN}/curl" <<'EOF'
#!/usr/bin/env bash
url=""
output=""
while (($#)); do
  case "$1" in
    -o)
      output="$2"
      shift 2
      ;;
    http*)
      url="$1"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

case "${url}" in
  https://api.github.com/repos/gruntwork-io/terragrunt/releases/latest)
    printf '{"tag_name":%s}\n' "${DEVRAIL_TEST_TAG_JSON:-null}"
    ;;
  https://github.com/gruntwork-io/terragrunt/releases/download/*)
    printf '%s\n' "${url}" >"${DEVRAIL_TEST_DOWNLOAD_LOG}"
    printf 'fake terragrunt\n' >"${output}"
    ;;
  *)
    printf 'unexpected curl url: %s\n' "${url}" >&2
    exit 1
    ;;
esac
EOF
chmod +x "${FAKE_BIN}/curl"

cat >"${FAKE_BIN}/install" <<'EOF'
#!/usr/bin/env bash
src=""
for arg in "$@"; do
  src="${arg}"
done
test -n "${src}"
EOF
chmod +x "${FAKE_BIN}/install"

cat >"${FAKE_BIN}/uname" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -s) printf 'Linux\n' ;;
  -m) printf 'aarch64\n' ;;
  *) printf 'Linux\n' ;;
esac
EOF
chmod +x "${FAKE_BIN}/uname"

assert_fallback_for() {
  local name="$1"
  local jq_output="$2"
  local expected="https://github.com/gruntwork-io/terragrunt/releases/download/v0.99.4/terragrunt_linux_arm64"
  local log_file="${TMPDIR_TEST}/${name}.download"

  DEVRAIL_TEST_JQ_OUTPUT="${jq_output}" \
    DEVRAIL_TEST_DOWNLOAD_LOG="${log_file}" \
    PATH="${FAKE_BIN}:/usr/bin:/bin:/usr/sbin:/sbin" \
    DEVRAIL_LOG_FORMAT=human \
    DEVRAIL_LIB="${ROOT}/lib" \
    bash "${ROOT}/scripts/install-terraform.sh" >/dev/null

  if [[ "$(cat "${log_file}")" != "${expected}" ]]; then
    printf 'expected fallback URL %s, got %s\n' "${expected}" "$(cat "${log_file}")" >&2
    exit 1
  fi
}

assert_fallback_for null ""
assert_fallback_for malformed "not-a-version"

echo "terragrunt release tag fallback regression passed"
