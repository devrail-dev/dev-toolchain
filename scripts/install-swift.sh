#!/usr/bin/env bash
# scripts/install-swift.sh — Verify Swift tooling for DevRail
#
# Purpose: Verifies that the Swift toolchain, SwiftLint, and swift-format are
#          available in the dev-toolchain container. All tools are built in the
#          swift-builder Dockerfile stage and COPY'd to the runtime image; this
#          script only confirms they are on PATH.
# Usage:   bash scripts/install-swift.sh [--help]
# Dependencies: lib/log.sh, lib/platform.sh
#
# Tools verified:
#   - swift         (Swift compiler — COPY'd from builder)
#   - swiftlint     (Linter — built from source in builder)
#   - swift-format  (Formatter — built from source in builder)

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
  log_info "install-swift.sh — Verify Swift tooling for DevRail"
  log_info "Usage: bash scripts/install-swift.sh [--help]"
  log_info "Tools: swift, swiftlint, swift-format"
  exit 0
fi

# --- Main ---
log_info "Verifying Swift tooling installation"

# Verify Swift compiler (COPY'd from builder)
if command -v swift &>/dev/null; then
  log_info "swift is already installed"
else
  log_warn "swift not found — expected to be copied from Swift builder stage"
fi

# Verify SwiftLint (built from source in builder)
if command -v swiftlint &>/dev/null; then
  log_info "swiftlint is already installed"
else
  log_warn "swiftlint not found — expected to be copied from Swift builder stage"
fi

# Verify swift-format (built from source in builder)
if command -v swift-format &>/dev/null; then
  log_info "swift-format is already installed"
else
  log_warn "swift-format not found — expected to be copied from Swift builder stage"
fi

log_info "Swift tooling verification complete"
