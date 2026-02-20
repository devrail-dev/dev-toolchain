#!/usr/bin/env bash
# scripts/install-python.sh — Install Python tooling for DevRail
#
# Purpose: Installs Python linting, formatting, security, and testing tools
#          into the dev-toolchain container.
# Usage:   bash scripts/install-python.sh [--help]
# Dependencies: python3, pip3, lib/log.sh, lib/platform.sh
#
# Tools installed:
#   - ruff      (Python linter + formatter)
#   - bandit    (Python security linter)
#   - semgrep   (Multi-language SAST)
#   - pytest    (Python test framework)
#   - mypy      (Python static type checker)

set -euo pipefail

# --- Resolve library path ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVRAIL_LIB="${DEVRAIL_LIB:-${SCRIPT_DIR}/../lib}"

# shellcheck source=../lib/log.sh
source "${DEVRAIL_LIB}/log.sh"
# shellcheck source=../lib/platform.sh
source "${DEVRAIL_LIB}/platform.sh"

# --- Help ---
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  log_info "install-python.sh — Install Python tooling for DevRail"
  log_info "Usage: bash scripts/install-python.sh [--help]"
  log_info "Tools: ruff, bandit, semgrep, pytest, mypy"
  exit 0
fi

# --- Cleanup trap ---
TMPDIR_CLEANUP=""
cleanup() {
  if [[ -n "${TMPDIR_CLEANUP}" && -d "${TMPDIR_CLEANUP}" ]]; then
    rm -rf "${TMPDIR_CLEANUP}"
  fi
}
trap cleanup EXIT

# --- Main ---

log_info "Starting Python tooling installation"

# Ensure pip is available and upgraded
require_cmd "python3" "python3 is required but not found"
if ! command -v pip3 &>/dev/null && ! command -v pip &>/dev/null; then
  log_info "Installing pip via ensurepip"
  python3 -m ensurepip --upgrade 2>/dev/null || true
fi

# Determine pip command
PIP_CMD="pip3"
if ! command -v pip3 &>/dev/null; then
  PIP_CMD="pip"
fi

# Upgrade pip
log_info "Upgrading pip"
python3 -m pip install --upgrade pip --break-system-packages 2>/dev/null \
  || python3 -m pip install --upgrade pip 2>/dev/null \
  || true

# Install Python tools via pip (idempotent)
readonly PYTHON_TOOLS=(
  "ruff"
  "bandit"
  "semgrep"
  "pytest"
  "mypy"
)

for tool in "${PYTHON_TOOLS[@]}"; do
  if command -v "${tool}" &>/dev/null; then
    log_info "${tool} is already installed, skipping"
  else
    log_info "Installing ${tool}"
    python3 -m pip install --break-system-packages "${tool}" 2>/dev/null \
      || python3 -m pip install "${tool}"
  fi
done

log_info "Python tooling installation complete"
