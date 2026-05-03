#!/usr/bin/env bash
# lib/plugin-cache.sh — Plugin cache helpers (Story 13.3)
#
# Purpose: Single source of truth for the plugin-cache slug derivation and
#          content-hash computation. Sourced by both `plugin-resolver.sh`
#          and `plugin-lockfile-verify.sh` so the two stay in lockstep.
#
# Usage:   source "${DEVRAIL_LIB}/plugin-cache.sh"
# Dependencies: lib/log.sh
#
# Functions:
#   derive_slug <source-url>          - Plugin cache directory slug
#   compute_content_hash <dir>        - Deterministic sha256 of tree content

# Guard against double-sourcing
# shellcheck disable=SC2317
if [[ -n "${_DEVRAIL_PLUGIN_CACHE_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
readonly _DEVRAIL_PLUGIN_CACHE_LOADED=1

# derive_slug prints the on-disk cache slug for a plugin source URL.
#
# - basename of the URL (so `https://github.com/foo/bar` → `bar`)
# - strips a trailing `.git` suffix (so `bar.git` → `bar`)
# - rejects empty input and slugs that contain shell-special characters
#   (slashes, colons, etc.) — those would mean basename failed
#
# Example: derive_slug https://github.com/community/devrail-plugin-elixir.git
#          → devrail-plugin-elixir
derive_slug() {
  local source_url="${1:-}"
  if [[ -z "${source_url}" ]]; then
    return 1
  fi
  local slug
  slug="$(basename "${source_url}")"
  # Strip optional .git suffix
  slug="${slug%.git}"
  # Reject anything that's not a typical project-name shape — defense against
  # weird URLs that basename can't parse cleanly.
  if [[ ! "${slug}" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    return 1
  fi
  printf "%s" "${slug}"
}

# compute_content_hash prints a sha256 hex digest over a directory's
# non-.git/, non-sentinel files. Stable across machines via LC_ALL=C.
# Returns non-zero if the directory doesn't exist.
compute_content_hash() {
  local dir="${1:-}"
  if [[ ! -d "${dir}" ]]; then
    if declare -f log_event >/dev/null 2>&1; then
      log_event error "content_hash directory missing" path="${dir}" language=_plugins
    fi
    return 1
  fi
  (cd "${dir}" &&
    LC_ALL=C find . -type f \
      -not -path './.git/*' \
      -not -name '.devrail.sha' \
      -print0 |
    LC_ALL=C sort -z |
      xargs -0 sha256sum |
      sha256sum |
      cut -d' ' -f1)
}
