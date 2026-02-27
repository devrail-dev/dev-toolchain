#!/usr/bin/env bash
# scripts/install-go.sh — Verify Go tooling for DevRail
#
# Purpose: Verifies that Go SDK and Go-based tools are available in the
#          dev-toolchain container. All tools are compiled in the Go builder
#          stage and COPY'd into the runtime image; this script only confirms
#          they are on PATH.
# Usage:   bash scripts/install-go.sh [--help]
# Dependencies: lib/log.sh, lib/platform.sh
#
# Tools verified:
#   - go            (Go SDK — COPY'd from builder)
#   - golangci-lint (Meta-linter — built in builder)
#   - gofumpt       (Strict gofmt superset — built in builder)
#   - govulncheck   (Vulnerability scanner — built in builder)

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
  log_info "install-go.sh — Verify Go tooling for DevRail"
  log_info "Usage: bash scripts/install-go.sh [--help]"
  log_info "Tools: go, golangci-lint, gofumpt, govulncheck"
  exit 0
fi

# --- Main ---

log_info "Verifying Go tooling installation"

# Verify Go SDK is available (COPY'd from builder)
if command -v go &>/dev/null; then
  log_info "go is already installed"
else
  log_warn "go not found — expected to be copied from Go builder stage"
fi

# Verify golangci-lint is available (built in builder)
if command -v golangci-lint &>/dev/null; then
  log_info "golangci-lint is already installed"
else
  log_warn "golangci-lint not found — expected to be copied from Go builder stage"
fi

# Verify gofumpt is available (built in builder)
if command -v gofumpt &>/dev/null; then
  log_info "gofumpt is already installed"
else
  log_warn "gofumpt not found — expected to be copied from Go builder stage"
fi

# Verify govulncheck is available (built in builder)
if command -v govulncheck &>/dev/null; then
  log_info "govulncheck is already installed"
else
  log_warn "govulncheck not found — expected to be copied from Go builder stage"
fi

log_info "Go tooling verification complete"
