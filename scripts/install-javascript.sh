#!/usr/bin/env bash
# scripts/install-javascript.sh — Install JavaScript/TypeScript tooling for DevRail
#
# Purpose: Installs JS/TS linting, formatting, security, and testing tools
#          into the dev-toolchain container via npm.
# Usage:   bash scripts/install-javascript.sh [--help]
# Dependencies: node, npm, lib/log.sh, lib/platform.sh
#
# Tools installed:
#   - eslint               (JavaScript/TypeScript linter)
#   - @eslint/js            (ESLint core rules for flat config)
#   - typescript-eslint     (TypeScript ESLint plugin for flat config)
#   - prettier              (Opinionated code formatter)
#   - typescript            (TypeScript compiler — tsc --noEmit for type checking)
#   - vitest                (Fast ESM-native test runner)

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
  log_info "install-javascript.sh — Install JavaScript/TypeScript tooling for DevRail"
  log_info "Usage: bash scripts/install-javascript.sh [--help]"
  log_info "Tools: eslint, @eslint/js, typescript-eslint, prettier, typescript, vitest"
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

log_info "Starting JavaScript/TypeScript tooling installation"

require_cmd "node" "node is required but not found"
require_cmd "npm" "npm is required but not found"

# Install JS/TS tools via npm (idempotent)
readonly JS_TOOLS=(
  "eslint"
  "@eslint/js"
  "typescript-eslint"
  "prettier"
  "typescript"
  "vitest"
)

for tool in "${JS_TOOLS[@]}"; do
  if npm list -g "${tool}" --depth=0 &>/dev/null; then
    log_info "${tool} is already installed, skipping"
  else
    log_info "Installing ${tool}"
    npm install -g "${tool}"
  fi
done

log_info "JavaScript/TypeScript tooling installation complete"
