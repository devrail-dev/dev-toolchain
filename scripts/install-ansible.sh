#!/usr/bin/env bash
# scripts/install-ansible.sh — Install Ansible tooling for DevRail
#
# Purpose: Installs Ansible linting and testing tools into the dev-toolchain container.
# Usage:   bash scripts/install-ansible.sh [--help]
# Dependencies: python3, pip, lib/log.sh, lib/platform.sh
#
# Tools installed:
#   - ansible-lint  (Ansible playbook/role linter — pulls ansible-core as dependency)
#   - molecule      (Ansible role testing framework)

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
  log_info "install-ansible.sh — Install Ansible tooling for DevRail"
  log_info "Usage: bash scripts/install-ansible.sh [--help]"
  log_info "Tools: ansible-lint, molecule"
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

log_info "Starting Ansible tooling installation"

# Ensure pip is available
require_cmd "python3" "python3 is required but not found"
if ! command -v pip3 &>/dev/null && ! command -v pip &>/dev/null; then
  log_info "Installing pip via ensurepip"
  python3 -m ensurepip --upgrade 2>/dev/null || true
fi

# Install ansible-lint via pip (idempotent)
# ansible-lint pulls in ansible-core as a dependency — this is expected
if command -v ansible-lint &>/dev/null; then
  log_info "ansible-lint is already installed, skipping"
else
  log_info "Installing ansible-lint (will pull ansible-core as dependency)"
  python3 -m pip install --break-system-packages ansible-lint 2>/dev/null \
    || python3 -m pip install ansible-lint
  log_info "ansible-lint installed successfully"
fi

# Install molecule via pip (idempotent)
if command -v molecule &>/dev/null; then
  log_info "molecule is already installed, skipping"
else
  log_info "Installing molecule"
  python3 -m pip install --break-system-packages molecule 2>/dev/null \
    || python3 -m pip install molecule
  log_info "molecule installed successfully"
fi

log_info "Ansible tooling installation complete"
