#!/usr/bin/env bash
# scripts/install-rust.sh — Verify Rust tooling for DevRail
#
# Purpose: Verifies that the Rust toolchain and Rust-based tools are available
#          in the dev-toolchain container. The Rust SDK (rustup + cargo + rustc)
#          and all tools are COPY'd from the rust-builder stage; this script
#          only confirms they are on PATH.
# Usage:   bash scripts/install-rust.sh [--help]
# Dependencies: lib/log.sh, lib/platform.sh
#
# Tools verified:
#   - rustc         (Rust compiler — COPY'd from builder)
#   - cargo         (Rust package manager — COPY'd from builder)
#   - clippy        (Linter — rustup component, COPY'd from builder)
#   - rustfmt       (Formatter — rustup component, COPY'd from builder)
#   - cargo-audit   (Dependency vulnerability scanner — built in builder)
#   - cargo-deny    (Dependency policy checker — built in builder)

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
  log_info "install-rust.sh — Verify Rust tooling for DevRail"
  log_info "Usage: bash scripts/install-rust.sh [--help]"
  log_info "Tools: rustc, cargo, clippy, rustfmt, cargo-audit, cargo-deny"
  exit 0
fi

# --- Main ---

log_info "Verifying Rust tooling installation"

# Verify rustc is available (COPY'd from builder)
if command -v rustc &>/dev/null; then
  log_info "rustc is already installed"
else
  log_warn "rustc not found — expected to be copied from Rust builder stage"
fi

# Verify cargo is available (COPY'd from builder)
if command -v cargo &>/dev/null; then
  log_info "cargo is already installed"
else
  log_warn "cargo not found — expected to be copied from Rust builder stage"
fi

# Verify clippy is available (rustup component, COPY'd from builder)
if command -v cargo-clippy &>/dev/null; then
  log_info "clippy is already installed"
else
  log_warn "clippy not found — expected to be copied from Rust builder stage"
fi

# Verify rustfmt is available (rustup component, COPY'd from builder)
if command -v rustfmt &>/dev/null; then
  log_info "rustfmt is already installed"
else
  log_warn "rustfmt not found — expected to be copied from Rust builder stage"
fi

# Verify cargo-audit is available (built in builder)
if command -v cargo-audit &>/dev/null; then
  log_info "cargo-audit is already installed"
else
  log_warn "cargo-audit not found — expected to be copied from Rust builder stage"
fi

# Verify cargo-deny is available (built in builder)
if command -v cargo-deny &>/dev/null; then
  log_info "cargo-deny is already installed"
else
  log_warn "cargo-deny not found — expected to be copied from Rust builder stage"
fi

log_info "Rust tooling verification complete"
