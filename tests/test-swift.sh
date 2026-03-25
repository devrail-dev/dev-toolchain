#!/usr/bin/env bash
# tests/test-swift.sh — Verify Swift tooling is installed correctly
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVRAIL_LIB="${DEVRAIL_LIB:-${SCRIPT_DIR}/../lib}"

# shellcheck source=../lib/log.sh
source "${DEVRAIL_LIB}/log.sh"

log_info "Testing Swift tooling installation..."

# Verify swift
if command -v swift &>/dev/null; then
  log_info "PASS: swift found — $(swift --version 2>&1 | head -1)"
else
  log_error "FAIL: swift not found"
  exit 1
fi

# Verify swiftlint
if command -v swiftlint &>/dev/null; then
  log_info "PASS: swiftlint found — $(swiftlint version)"
else
  log_error "FAIL: swiftlint not found"
  exit 1
fi

# Verify swift-format
if command -v swift-format &>/dev/null; then
  log_info "PASS: swift-format found — $(swift-format --version 2>&1 || echo 'version check N/A')"
else
  log_error "FAIL: swift-format not found"
  exit 1
fi

log_info "All Swift tools verified successfully"
