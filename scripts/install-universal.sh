#!/usr/bin/env bash
# scripts/install-universal.sh — Install universal security tools for DevRail
#
# Purpose: Installs language-agnostic security scanning tools into the
#          dev-toolchain container.
# Usage:   bash scripts/install-universal.sh [--help]
# Dependencies: curl, lib/log.sh, lib/platform.sh
#
# Tools installed:
#   - trivy     (Vulnerability and misconfiguration scanner)
#   - gitleaks  (Secret detection in git repos — built in Go builder stage)

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
  log_info "install-universal.sh — Install universal security tools for DevRail"
  log_info "Usage: bash scripts/install-universal.sh [--help]"
  log_info "Tools: trivy, gitleaks"
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

log_info "Starting universal security tools installation"

TMPDIR_CLEANUP="$(mktemp -d)"

# Install trivy via APT repository (idempotent)
if command -v trivy &>/dev/null; then
  log_info "trivy is already installed, skipping"
else
  log_info "Installing trivy via APT repository"
  require_cmd "curl" "curl is required to install trivy"

  curl -fsSL https://get.trivy.dev/deb/public.key | gpg --dearmor -o /usr/share/keyrings/trivy.gpg
  echo "deb [signed-by=/usr/share/keyrings/trivy.gpg] https://get.trivy.dev/deb generic main" \
    >/etc/apt/sources.list.d/trivy.list
  apt-get update -qq
  apt-get install -y --no-install-recommends trivy
  rm -rf /var/lib/apt/lists/*

  log_info "trivy installed successfully"
fi

# Verify gitleaks is available (built in Go builder stage and copied)
if command -v gitleaks &>/dev/null; then
  log_info "gitleaks is already installed"
else
  log_warn "gitleaks not found — expected to be copied from Go builder stage"
fi

log_info "Universal security tools installation complete"
