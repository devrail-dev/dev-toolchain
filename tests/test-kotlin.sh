#!/usr/bin/env bash
# tests/test-kotlin.sh — Verify Kotlin tooling is installed correctly
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVRAIL_LIB="${DEVRAIL_LIB:-${SCRIPT_DIR}/../lib}"

# shellcheck source=../lib/log.sh
source "${DEVRAIL_LIB}/log.sh"

log_info "Testing Kotlin tooling installation..."

# Verify JDK
if command -v java &>/dev/null; then
  log_info "PASS: java found — $(java --version 2>&1 | head -1)"
else
  log_error "FAIL: java not found"
  exit 1
fi

# Verify ktlint
if command -v ktlint &>/dev/null; then
  log_info "PASS: ktlint found — $(ktlint --version 2>&1)"
else
  log_error "FAIL: ktlint not found"
  exit 1
fi

# Verify detekt-cli
if command -v detekt-cli &>/dev/null; then
  log_info "PASS: detekt-cli found"
else
  log_error "FAIL: detekt-cli not found"
  exit 1
fi

# Verify gradle
if command -v gradle &>/dev/null; then
  log_info "PASS: gradle found — $(gradle --version 2>&1 | grep 'Gradle' | head -1)"
else
  log_error "FAIL: gradle not found"
  exit 1
fi

log_info "All Kotlin tools verified successfully"
