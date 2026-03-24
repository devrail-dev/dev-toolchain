#!/usr/bin/env bash
# scripts/install-kotlin.sh — Install and verify Kotlin tooling for DevRail
#
# Purpose: Installs Kotlin development tools (ktlint, detekt, Gradle) and verifies
#          the JDK is available in the dev-toolchain container. JDK 21 is COPY'd
#          from the jdk-builder stage; this script installs additional tools.
# Usage:   bash scripts/install-kotlin.sh [--help]
# Dependencies: lib/log.sh, lib/platform.sh
#
# Tools installed/verified:
#   - java         (JDK 21 — COPY'd from builder)
#   - ktlint       (Linter/formatter — downloaded binary)
#   - detekt-cli   (Static analysis — downloaded JAR)
#   - gradle       (Build tool — downloaded distribution)

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
  log_info "install-kotlin.sh — Install and verify Kotlin tooling for DevRail"
  log_info "Usage: bash scripts/install-kotlin.sh [--help]"
  log_info "Tools: java, ktlint, detekt-cli, gradle"
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

install_ktlint() {
  if command -v ktlint &>/dev/null; then
    log_info "ktlint already installed, skipping"
    return 0
  fi

  log_info "Installing ktlint..."
  local version="1.5.0"
  curl -fsSL "https://github.com/pinterest/ktlint/releases/download/${version}/ktlint" \
    -o /usr/local/bin/ktlint
  chmod +x /usr/local/bin/ktlint

  require_cmd "ktlint" "Failed to install ktlint"
  log_info "ktlint installed successfully"
}

install_detekt() {
  if [ -f /usr/local/lib/detekt-cli.jar ]; then
    log_info "detekt-cli already installed, skipping"
    return 0
  fi

  log_info "Installing detekt-cli..."
  local version="1.23.7"
  curl -fsSL "https://github.com/detekt/detekt/releases/download/v${version}/detekt-cli-${version}-all.jar" \
    -o /usr/local/lib/detekt-cli.jar

  # Create wrapper script
  cat > /usr/local/bin/detekt-cli << 'WRAPPER'
#!/usr/bin/env bash
exec java -jar /usr/local/lib/detekt-cli.jar "$@"
WRAPPER
  chmod +x /usr/local/bin/detekt-cli

  require_cmd "detekt-cli" "Failed to install detekt-cli"
  log_info "detekt-cli installed successfully"
}

install_gradle() {
  if command -v gradle &>/dev/null; then
    log_info "gradle already installed, skipping"
    return 0
  fi

  log_info "Installing Gradle..."
  local version="8.12"
  TMPDIR_CLEANUP="$(mktemp -d)"
  curl -fsSL "https://services.gradle.org/distributions/gradle-${version}-bin.zip" \
    -o "${TMPDIR_CLEANUP}/gradle.zip"
  unzip -q "${TMPDIR_CLEANUP}/gradle.zip" -d /opt
  ln -sf "/opt/gradle-${version}/bin/gradle" /usr/local/bin/gradle

  require_cmd "gradle" "Failed to install Gradle"
  log_info "Gradle installed successfully"
}

# --- Main ---
log_info "Installing Kotlin tools..."

# Verify JDK is available (COPY'd from builder)
if command -v java &>/dev/null; then
  log_info "java is already installed"
else
  log_warn "java not found — expected to be copied from JDK builder stage"
fi

install_ktlint
install_detekt
install_gradle

log_info "Kotlin tools installed successfully"
