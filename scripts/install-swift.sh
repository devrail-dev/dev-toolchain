#!/usr/bin/env bash
# scripts/install-swift.sh — Install and verify Swift tooling for DevRail
#
# Purpose: Installs SwiftLint and swift-format, and verifies the Swift toolchain
#          is available in the dev-toolchain container. The Swift SDK (swiftc, swift
#          build, swift test, Swift Package Manager) is COPY'd from the swift-builder
#          stage; this script installs additional tools and confirms all are on PATH.
# Usage:   bash scripts/install-swift.sh [--help]
# Dependencies: lib/log.sh, lib/platform.sh
#
# Tools installed/verified:
#   - swift         (Swift compiler — COPY'd from builder)
#   - swiftlint     (Linter — installed from GitHub releases)
#   - swift-format  (Formatter — installed from GitHub releases)

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
  log_info "install-swift.sh — Install and verify Swift tooling for DevRail"
  log_info "Usage: bash scripts/install-swift.sh [--help]"
  log_info "Tools: swift, swiftlint, swift-format"
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

# --- Tool installation functions ---

install_swiftlint() {
  if command -v swiftlint &>/dev/null; then
    log_info "swiftlint already installed, skipping"
    return 0
  fi

  log_info "Installing SwiftLint..."
  TMPDIR_CLEANUP="$(mktemp -d)"
  local arch
  arch="$(dpkg --print-architecture)"
  # SwiftLint provides pre-built Linux binaries
  local version="0.58.0"
  if [ "${arch}" = "amd64" ]; then
    curl -fsSL "https://github.com/realm/SwiftLint/releases/download/${version}/swiftlint_linux.zip" \
      -o "${TMPDIR_CLEANUP}/swiftlint.zip"
    unzip -q "${TMPDIR_CLEANUP}/swiftlint.zip" -d "${TMPDIR_CLEANUP}"
    install -m 755 "${TMPDIR_CLEANUP}/swiftlint" /usr/local/bin/swiftlint
  elif [ "${arch}" = "arm64" ]; then
    curl -fsSL "https://github.com/realm/SwiftLint/releases/download/${version}/swiftlint_linux_aarch64.zip" \
      -o "${TMPDIR_CLEANUP}/swiftlint.zip"
    unzip -q "${TMPDIR_CLEANUP}/swiftlint.zip" -d "${TMPDIR_CLEANUP}"
    install -m 755 "${TMPDIR_CLEANUP}/swiftlint" /usr/local/bin/swiftlint
  else
    log_error "SwiftLint: unsupported architecture ${arch}"
    return 1
  fi

  require_cmd "swiftlint" "Failed to install SwiftLint"
  log_info "SwiftLint installed successfully"
}

verify_swift_format() {
  # swift-format is built from source in the Dockerfile swift-builder stage
  # and COPY'd to /usr/local/bin/swift-format. This function only verifies.
  if command -v swift-format &>/dev/null; then
    log_info "swift-format is already installed"
  else
    log_warn "swift-format not found — expected to be copied from Swift builder stage"
  fi
}

# --- Main ---
log_info "Installing Swift tools..."

# Verify Swift compiler is available (COPY'd from builder)
if command -v swift &>/dev/null; then
  log_info "swift is already installed"
else
  log_warn "swift not found — expected to be copied from Swift builder stage"
fi

install_swiftlint
verify_swift_format

log_info "Swift tools installed successfully"
