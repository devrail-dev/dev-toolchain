#!/usr/bin/env bash
# scripts/report-tool-versions.sh — Report all tool versions as JSON
#
# Purpose: Generates a JSON manifest of every tool installed in the
#          dev-toolchain container. Unlike the Makefile _docs target,
#          this script reports ALL tools unconditionally (no HAS_* gates).
# Usage:   bash scripts/report-tool-versions.sh [OUTPUT_FILE]
#          If OUTPUT_FILE is given, JSON is written to that file.
#          If omitted, JSON is written to stdout.
# Dependencies: lib/log.sh
#
# Tool ecosystems:
#   Python    — ruff, bandit, mypy, pytest, semgrep
#   Bash      — shellcheck, shfmt, bats
#   Terraform — terraform, tflint, checkov, terraform-docs
#   Ansible   — ansible-lint, molecule
#   Ruby      — rubocop, reek, brakeman, bundler-audit, rspec, srb
#   Go        — go, golangci-lint, gofumpt, govulncheck
#   JS/TS     — node, npm, eslint, prettier, tsc, vitest
#   Rust      — rustc, cargo, clippy, rustfmt, cargo-audit, cargo-deny
#   Universal — trivy, gitleaks, git-cliff

set -euo pipefail

# --- Resolve library path ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVRAIL_LIB="${DEVRAIL_LIB:-${SCRIPT_DIR}/../lib}"

# shellcheck source=../lib/log.sh
source "${DEVRAIL_LIB}/log.sh"

# --- Help ---
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  log_info "report-tool-versions.sh — Report all tool versions as JSON"
  log_info "Usage: bash scripts/report-tool-versions.sh [OUTPUT_FILE]"
  log_info "  OUTPUT_FILE  Write JSON to file (default: stdout)"
  exit 0
fi

# --- Output target ---
OUTPUT_FILE="${1:-}"

# --- Version extraction helper ---
# _tv NAME VERSION_CMD [BINARY]
#   NAME        — tool key in the JSON output
#   VERSION_CMD — command string to extract version (eval'd)
#   BINARY      — binary to check with command -v (defaults to NAME)
#
# Outputs:
#   Tool found + version parsed → "1.2.3"
#   Tool found + parse fails   → "unknown"
#   Tool not on PATH            → "not installed"
_sep=""
_tv() {
  local name="$1"
  local version_cmd="$2"
  local binary="${3:-$1}"
  local version

  if ! command -v "${binary}" &>/dev/null; then
    log_warn "${name}: not installed (${binary} not on PATH)"
    version="not installed"
  else
    local raw
    raw=$(eval "${version_cmd}" 2>&1) || true
    version=$(printf '%s' "${raw}" | grep -oE '[0-9]+\.[0-9]+[^ ]*' | head -1 || true)
    # Reject versions parsed from error messages (e.g. broken rustup components)
    if printf '%s' "${raw}" | grep -qi 'error\|not installed'; then
      log_warn "${name}: command reported an error"
      version="unknown"
    elif [[ -z "${version}" ]]; then
      log_warn "${name}: could not parse version from '${version_cmd}'"
      version="unknown"
    else
      log_debug "${name}: ${version}"
    fi
  fi

  printf '%s"%s":"%s"' "${_sep}" "${name}" "${version}"
  _sep=","
}

# --- Generate JSON ---
log_info "Generating tool version manifest"

_json() {
  printf '{"generated_at":"%s","tools":{' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Python
  _tv ruff "ruff --version"
  _tv bandit "bandit --version"
  _tv mypy "mypy --version"
  _tv pytest "pytest --version"
  _tv semgrep "semgrep --version"

  # Bash
  _tv shellcheck "shellcheck --version"
  _tv shfmt "shfmt --version"
  _tv bats "bats --version"

  # Terraform
  _tv terraform "terraform version"
  _tv tflint "tflint --version"
  _tv checkov "checkov --version"
  _tv terraform-docs "terraform-docs --version"

  # Ansible
  _tv ansible-lint "ansible-lint --version"
  _tv molecule "molecule --version"

  # Ruby
  _tv rubocop "rubocop --version"
  _tv reek "reek --version"
  _tv brakeman "brakeman --version"
  _tv bundler-audit "bundler-audit --version"
  _tv rspec "rspec --version"
  _tv srb "srb --version"

  # Go
  _tv go "go version"
  _tv golangci-lint "golangci-lint version"
  _tv gofumpt "gofumpt --version"
  _tv govulncheck "govulncheck -version"

  # JavaScript/TypeScript
  _tv node "node --version"
  _tv npm "npm --version"
  _tv eslint "eslint --version"
  _tv prettier "prettier --version"
  _tv tsc "tsc --version"
  _tv vitest "vitest --version"

  # Rust
  _tv rustc "rustc --version"
  _tv cargo "cargo --version"
  _tv clippy "cargo clippy --version" cargo-clippy
  _tv rustfmt "rustfmt --version"
  _tv cargo-audit "cargo audit --version" cargo-audit
  _tv cargo-deny "cargo deny --version" cargo-deny

  # Universal
  _tv trivy "trivy --version"
  _tv gitleaks "gitleaks version"
  _tv git-cliff "git-cliff --version"

  printf '}}\n'
}

if [[ -n "${OUTPUT_FILE}" ]]; then
  _json >"${OUTPUT_FILE}"
  log_info "Tool version manifest written to ${OUTPUT_FILE}"
else
  _json
fi
