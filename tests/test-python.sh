#!/usr/bin/env bash
# tests/test-python.sh — Validate Python tooling installation
#
# Purpose: Verifies that all Python tools are installed and executable.
# Usage:   bash tests/test-python.sh [--help]
# Dependencies: lib/log.sh

set -euo pipefail

# --- Resolve library path ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVRAIL_LIB="${DEVRAIL_LIB:-${SCRIPT_DIR}/../lib}"

# shellcheck source=../lib/log.sh
source "${DEVRAIL_LIB}/log.sh"

# --- Help ---
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  log_info "test-python.sh — Validate Python tooling installation"
  log_info "Usage: bash tests/test-python.sh [--help]"
  log_info "Checks: ruff, bandit, semgrep, pytest, mypy"
  exit 0
fi

# --- Main ---

log_info "Validating Python tooling installation"

FAILURES=0

# check_tool verifies a tool is on PATH and can report its version
check_tool() {
  local tool="$1"
  local version_flag="${2:---version}"

  if ! command -v "${tool}" &>/dev/null; then
    log_error "${tool} is not on PATH"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if ${tool} ${version_flag} &>/dev/null; then
    log_info "${tool} — OK"
  else
    log_error "${tool} found but failed to execute ${version_flag}"
    FAILURES=$((FAILURES + 1))
  fi
}

check_tool "ruff" "--version"
check_tool "bandit" "--version"
check_tool "semgrep" "--version"
check_tool "pytest" "--version"
check_tool "mypy" "--version"

if [[ "${FAILURES}" -gt 0 ]]; then
  log_error "Python tooling validation failed: ${FAILURES} tool(s) missing or broken"
  exit 1
fi

log_info "All Python tools validated successfully"
