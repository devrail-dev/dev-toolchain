#!/usr/bin/env bash
# lib/platform.sh — DevRail platform detection library
#
# Purpose: Provides platform and architecture detection helpers.
# Usage:   source "${DEVRAIL_LIB}/platform.sh"
# Dependencies: lib/log.sh (must be sourced first)
#
# Functions:
#   on_mac     - Returns 0 on macOS, 1 otherwise
#   on_linux   - Returns 0 on Linux, 1 otherwise
#   on_arm64   - Returns 0 on ARM64/aarch64, 1 otherwise
#   on_amd64   - Returns 0 on x86_64/amd64, 1 otherwise
#   get_arch   - Prints normalized architecture name (amd64 or arm64)
#   get_os     - Prints normalized OS name (linux or darwin)

# Guard against double-sourcing
if [[ -n "${_DEVRAIL_PLATFORM_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
readonly _DEVRAIL_PLATFORM_LOADED=1

# --- Platform detection functions ---

# on_mac returns 0 on macOS, 1 otherwise
on_mac() {
  [[ "$(uname -s)" == "Darwin" ]]
}

# on_linux returns 0 on Linux, 1 otherwise
on_linux() {
  [[ "$(uname -s)" == "Linux" ]]
}

# on_arm64 returns 0 on ARM64/aarch64, 1 otherwise
on_arm64() {
  local arch
  arch="$(uname -m)"
  [[ "${arch}" == "aarch64" || "${arch}" == "arm64" ]]
}

# on_amd64 returns 0 on x86_64/amd64, 1 otherwise
on_amd64() {
  local arch
  arch="$(uname -m)"
  [[ "${arch}" == "x86_64" || "${arch}" == "amd64" ]]
}

# get_arch prints the normalized architecture name
# Returns: "amd64" or "arm64"
get_arch() {
  local arch
  arch="$(uname -m)"
  case "${arch}" in
    x86_64 | amd64)
      printf "amd64"
      ;;
    aarch64 | arm64)
      printf "arm64"
      ;;
    *)
      printf "%s" "${arch}"
      ;;
  esac
}

# get_os prints the normalized OS name
# Returns: "linux" or "darwin"
get_os() {
  local os
  os="$(uname -s)"
  case "${os}" in
    Linux)
      printf "linux"
      ;;
    Darwin)
      printf "darwin"
      ;;
    *)
      printf "%s" "${os}"
      ;;
  esac
}
