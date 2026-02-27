#!/usr/bin/env bash
# scripts/install-ruby.sh — Install Ruby tooling for DevRail
#
# Purpose: Installs Ruby linting, formatting, security, and testing tools
#          into the dev-toolchain container.
# Usage:   bash scripts/install-ruby.sh [--help]
# Dependencies: ruby, gem, lib/log.sh, lib/platform.sh
#
# Tools installed:
#   - rubocop              (Ruby linter + formatter)
#   - rubocop-rails        (Rails-specific rubocop rules)
#   - rubocop-rspec        (RSpec-specific rubocop rules)
#   - rubocop-performance  (Performance-focused rubocop rules)
#   - brakeman             (Rails security scanner)
#   - bundler-audit        (Dependency vulnerability scanner)
#   - rspec                (Ruby test framework)
#   - reek                 (Ruby code smell detector)
#   - sorbet               (Ruby static type checker)
#   - sorbet-runtime       (Sorbet runtime type annotations)

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
  log_info "install-ruby.sh — Install Ruby tooling for DevRail"
  log_info "Usage: bash scripts/install-ruby.sh [--help]"
  log_info "Tools: rubocop, rubocop-rails, rubocop-rspec, rubocop-performance, brakeman, bundler-audit, rspec, reek, sorbet, sorbet-runtime"
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

log_info "Starting Ruby tooling installation"

require_cmd "ruby" "ruby is required but not found"
require_cmd "gem" "gem is required but not found"

# Install Ruby tools via gem (idempotent)
# Each entry is "gem_name" or "gem_name:version_constraint"
# reek is pinned to ~> 6.3.0 because 6.5+ requires Ruby 3.4 (dry-schema 1.14)
readonly RUBY_TOOLS=(
  "rubocop"
  "rubocop-rails"
  "rubocop-rspec"
  "rubocop-performance"
  "brakeman"
  "bundler-audit"
  "rspec"
  "reek:~> 6.3.0"
  "sorbet"
  "sorbet-runtime"
)

for entry in "${RUBY_TOOLS[@]}"; do
  tool="${entry%%:*}"
  version="${entry#*:}"
  if [[ "${version}" == "${tool}" ]]; then
    version=""
  fi

  if gem list --exact "${tool}" --installed &>/dev/null; then
    log_info "${tool} is already installed, skipping"
  else
    log_info "Installing ${tool}"
    if [[ -n "${version}" ]]; then
      gem install "${tool}" --version "${version}" --no-document
    else
      gem install "${tool}" --no-document
    fi
  fi
done

log_info "Ruby tooling installation complete"
