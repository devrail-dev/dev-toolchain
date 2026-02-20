#!/usr/bin/env bash
# scripts/install-terraform.sh — Install Terraform tooling for DevRail
#
# Purpose: Installs Terraform linting, security, documentation, and testing tools
#          into the dev-toolchain container.
# Usage:   bash scripts/install-terraform.sh [--help]
# Dependencies: curl, unzip, python3, pip, lib/log.sh, lib/platform.sh
#
# Tools installed:
#   - tflint          (Terraform linter — built in Go builder stage)
#   - tfsec           (Terraform security scanner — built in Go builder stage)
#   - checkov         (IaC security scanner — installed via pip)
#   - terraform-docs  (Terraform documentation gen — built in Go builder stage)
#   - terraform       (Terraform CLI — downloaded from HashiCorp)
#
# Notes:
#   - terratest is a Go module dependency, not a standalone binary.
#     Consumer projects use `go get` to install it as needed.

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
  log_info "install-terraform.sh — Install Terraform tooling for DevRail"
  log_info "Usage: bash scripts/install-terraform.sh [--help]"
  log_info "Tools: tflint, tfsec, checkov, terraform-docs, terraform"
  log_info "Note: terratest is a Go module dependency — not installed as a binary"
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

log_info "Starting Terraform tooling installation"

TMPDIR_CLEANUP="$(mktemp -d)"

# Verify tflint is available (built in Go builder stage and copied)
if command -v tflint &>/dev/null; then
  log_info "tflint is already installed"
else
  log_warn "tflint not found — expected to be copied from Go builder stage"
fi

# Verify tfsec is available (built in Go builder stage and copied)
if command -v tfsec &>/dev/null; then
  log_info "tfsec is already installed"
else
  log_warn "tfsec not found — expected to be copied from Go builder stage"
fi

# Verify terraform-docs is available (built in Go builder stage and copied)
if command -v terraform-docs &>/dev/null; then
  log_info "terraform-docs is already installed"
else
  log_warn "terraform-docs not found — expected to be copied from Go builder stage"
fi

# Install checkov via pip (idempotent)
if command -v checkov &>/dev/null; then
  log_info "checkov is already installed, skipping"
else
  log_info "Installing checkov via pip"
  require_cmd "python3" "python3 is required but not found"
  python3 -m pip install --break-system-packages checkov 2>/dev/null \
    || python3 -m pip install checkov
  log_info "checkov installed successfully"
fi

# Install terraform CLI (idempotent)
if command -v terraform &>/dev/null; then
  log_info "terraform is already installed, skipping"
else
  log_info "Installing terraform CLI"
  require_cmd "curl" "curl is required to download terraform"
  require_cmd "unzip" "unzip is required to extract terraform"

  ARCH="$(get_arch)"
  OS="$(get_os)"

  # Fetch the latest stable terraform version
  TERRAFORM_VERSION=$(curl -s https://checkpoint-api.hashicorp.com/v1/check/terraform | jq -r '.current_version')
  if is_empty "${TERRAFORM_VERSION}"; then
    log_warn "Could not determine latest terraform version, using fallback"
    TERRAFORM_VERSION="1.9.8"
  fi

  log_info "Downloading terraform ${TERRAFORM_VERSION} for ${OS}/${ARCH}"
  TERRAFORM_URL="https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_${OS}_${ARCH}.zip"
  curl -fsSL "${TERRAFORM_URL}" -o "${TMPDIR_CLEANUP}/terraform.zip"
  unzip -o "${TMPDIR_CLEANUP}/terraform.zip" -d "${TMPDIR_CLEANUP}"
  install -m 0755 "${TMPDIR_CLEANUP}/terraform" /usr/local/bin/terraform

  log_info "terraform ${TERRAFORM_VERSION} installed successfully"
fi

# Note about terratest
log_info "terratest is a Go module dependency — not installed as a binary"
log_info "Consumer projects use 'go get github.com/gruntwork-io/terratest' as needed"

log_info "Terraform tooling installation complete"
