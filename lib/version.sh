#!/usr/bin/env bash
# lib/version.sh — DevRail semver helpers
#
# Purpose: Provides semver comparison and image-version detection for the
#          plugin loader and other version-aware code paths.
# Usage:   source "${DEVRAIL_LIB}/version.sh"
# Dependencies: lib/log.sh (must be sourced first)
#
# Functions:
#   version_gte <a> <b>   - Returns 0 if dotted-numeric a >= b, 1 otherwise.
#                           Recognises a "0.0.0-dev" or empty image version as
#                           "unknown" and returns 0 (lenient for local dev).
#   get_devrail_version   - Prints the running dev-toolchain image version.
#                           Reads $DEVRAIL_VERSION first, then /opt/devrail/VERSION,
#                           else prints "0.0.0-dev".

# Guard against double-sourcing
# shellcheck disable=SC2317
if [[ -n "${_DEVRAIL_VERSION_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
readonly _DEVRAIL_VERSION_LOADED=1

# get_devrail_version prints the running dev-toolchain image version.
# Resolution order:
#   1. $DEVRAIL_VERSION env var (used by tests and CI overrides)
#   2. /opt/devrail/VERSION file (written by Dockerfile from ARG DEVRAIL_VERSION)
#   3. "0.0.0-dev" sentinel (treated as unknown by version_gte)
get_devrail_version() {
  if [[ -n "${DEVRAIL_VERSION:-}" ]]; then
    printf "%s" "${DEVRAIL_VERSION}"
    return 0
  fi
  if [[ -r /opt/devrail/VERSION ]]; then
    tr -d '[:space:]' </opt/devrail/VERSION
    return 0
  fi
  printf "0.0.0-dev"
}

# version_gte returns 0 if dotted-numeric "a" >= "b" semver-wise.
# Special cases:
#   - "0.0.0-dev" or empty `a` → returns 0 (lenient: dev/unknown image passes)
#   - non-semver inputs → returns 1 (strict: bad data fails closed)
# Compares MAJOR.MINOR.PATCH numerically; ignores any -prerelease/+build suffix on b.
version_gte() {
  local a="${1:-}"
  local b="${2:-}"

  # Lenient: an unknown/dev image version cannot meaningfully be compared
  if [[ -z "${a}" || "${a}" == "0.0.0-dev" || "${a}" == "unknown" ]]; then
    return 0
  fi

  # Strip any -prerelease or +build metadata from both sides for the compare
  a="${a%%-*}"
  a="${a%%+*}"
  b="${b%%-*}"
  b="${b%%+*}"

  # Strict: both sides must be dotted-numeric MAJOR.MINOR.PATCH
  local semver_re='^[0-9]+\.[0-9]+\.[0-9]+$'
  if [[ ! "${a}" =~ ${semver_re} || ! "${b}" =~ ${semver_re} ]]; then
    return 1
  fi

  local a_major a_minor a_patch b_major b_minor b_patch
  IFS='.' read -r a_major a_minor a_patch <<<"${a}"
  IFS='.' read -r b_major b_minor b_patch <<<"${b}"

  if ((a_major != b_major)); then ((a_major > b_major)) && return 0 || return 1; fi
  if ((a_minor != b_minor)); then ((a_minor > b_minor)) && return 0 || return 1; fi
  if ((a_patch != b_patch)); then ((a_patch > b_patch)) && return 0 || return 1; fi
  return 0
}
