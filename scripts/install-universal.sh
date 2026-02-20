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

# Install trivy (idempotent)
if command -v trivy &>/dev/null; then
  log_info "trivy is already installed, skipping"
else
  log_info "Installing trivy"
  require_cmd "curl" "curl is required to install trivy"

  ARCH="$(get_arch)"
  OS="$(get_os)"

  # Map architecture names for trivy release artifacts
  case "${ARCH}" in
    amd64) TRIVY_ARCH="64bit" ;;
    arm64) TRIVY_ARCH="ARM64" ;;
    *)     TRIVY_ARCH="${ARCH}" ;;
  esac

  case "${OS}" in
    linux)  TRIVY_OS="Linux" ;;
    darwin) TRIVY_OS="macOS" ;;
    *)      TRIVY_OS="${OS}" ;;
  esac

  # Fetch latest trivy version from GitHub releases
  TRIVY_VERSION=$(curl -fsSL https://api.github.com/repos/aquasecurity/trivy/releases/latest | jq -r '.tag_name' | sed 's/^v//')
  if is_empty "${TRIVY_VERSION}"; then
    log_warn "Could not determine latest trivy version, using fallback"
    TRIVY_VERSION="0.58.0"
  fi

  log_info "Downloading trivy ${TRIVY_VERSION} for ${TRIVY_OS}/${TRIVY_ARCH}"
  TRIVY_URL="https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_${TRIVY_OS}-${TRIVY_ARCH}.tar.gz"
  curl -fsSL "${TRIVY_URL}" -o "${TMPDIR_CLEANUP}/trivy.tar.gz"
  tar -xzf "${TMPDIR_CLEANUP}/trivy.tar.gz" -C "${TMPDIR_CLEANUP}"
  install -m 0755 "${TMPDIR_CLEANUP}/trivy" /usr/local/bin/trivy

  log_info "trivy ${TRIVY_VERSION} installed successfully"
fi

# Verify gitleaks is available (built in Go builder stage and copied)
if command -v gitleaks &>/dev/null; then
  log_info "gitleaks is already installed"
else
  log_warn "gitleaks not found — expected to be copied from Go builder stage"
fi

log_info "Universal security tools installation complete"
