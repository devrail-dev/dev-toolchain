#!/usr/bin/env bash
# scripts/install-bash.sh — Install Bash tooling for DevRail
#
# Purpose: Installs Bash linting, formatting, and testing tools
#          into the dev-toolchain container.
# Usage:   bash scripts/install-bash.sh [--help]
# Dependencies: git, lib/log.sh, lib/platform.sh
#
# Tools installed:
#   - shellcheck  (Bash/shell linter — installed via apt-get in Dockerfile)
#   - shfmt       (Shell script formatter — built in Go builder stage)
#   - bats        (Bash test framework — installed via git clone)

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
  log_info "install-bash.sh — Install Bash tooling for DevRail"
  log_info "Usage: bash scripts/install-bash.sh [--help]"
  log_info "Tools: shellcheck, shfmt, bats"
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

log_info "Starting Bash tooling installation"

# Verify shellcheck is available (installed via apt-get in Dockerfile)
if command -v shellcheck &>/dev/null; then
  log_info "shellcheck is already installed"
else
  log_warn "shellcheck not found — expected to be installed via apt-get in Dockerfile"
fi

# Verify shfmt is available (built in Go builder stage and copied)
if command -v shfmt &>/dev/null; then
  log_info "shfmt is already installed"
else
  log_warn "shfmt not found — expected to be copied from Go builder stage"
fi

# Install bats via git clone (idempotent)
readonly BATS_INSTALL_DIR="/opt/bats"

if command -v bats &>/dev/null; then
  log_info "bats is already installed, skipping"
else
  log_info "Installing bats-core"
  require_cmd "git" "git is required to install bats-core"

  TMPDIR_CLEANUP="$(mktemp -d)"
  git clone --depth 1 https://github.com/bats-core/bats-core.git "${TMPDIR_CLEANUP}/bats-core"
  "${TMPDIR_CLEANUP}/bats-core/install.sh" "${BATS_INSTALL_DIR}"

  # Add bats to PATH if not already there
  if [[ ! -L /usr/local/bin/bats ]]; then
    ln -sf "${BATS_INSTALL_DIR}/bin/bats" /usr/local/bin/bats
  fi

  log_info "bats-core installed successfully"
fi

log_info "Bash tooling installation complete"
