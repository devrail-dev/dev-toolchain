#!/usr/bin/env bash
# scripts/plugin-lockfile-verify.sh — Verify .devrail.lock matches .devrail.yml
#
# Purpose: Fast verification — runs as a `_plugins-load` prerequisite on every
#          `make check` invocation. Compares each `.devrail.yml` `plugins:`
#          entry against `.devrail.lock`, then re-computes content_hash for
#          each cached tree and compares to the lockfile-recorded hash.
#
# Usage:   bash scripts/plugin-lockfile-verify.sh [<devrail-yml-path>] [--help]
#          Exit 0 — verified or no-op (no plugins declared)
#          Exit 2 — disagreement, missing lockfile, or tampering detected
#
# Dependencies: yq v4+, sha256sum, find, sort, lib/log.sh

set -euo pipefail
LC_ALL=C
export LC_ALL

# --- Resolve library path ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVRAIL_LIB="${DEVRAIL_LIB:-${SCRIPT_DIR}/../lib}"

# shellcheck source=../lib/log.sh
source "${DEVRAIL_LIB}/log.sh"

# --- Help ---
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  log_info "plugin-lockfile-verify.sh — Verify .devrail.lock matches .devrail.yml"
  log_info "Usage: bash scripts/plugin-lockfile-verify.sh [<devrail-yml-path>]"
  log_info "Exit 0 — verified; 2 — mismatch / missing lockfile / tampered cache"
  exit 0
fi

# --- Args ---
DEVRAIL_YML="${1:-.devrail.yml}"
PLUGINS_DIR="${DEVRAIL_PLUGINS_DIR:-/opt/devrail/plugins}"
LOCKFILE="$(dirname "${DEVRAIL_YML}")/.devrail.lock"

if [[ ! -r "${DEVRAIL_YML}" ]]; then
  log_event error "config not readable" path="${DEVRAIL_YML}" language=_plugins
  exit 2
fi

require_cmd "yq" "yq is required (v4+)"

# --- No-op when no plugins declared (regression-safe for v1.9.x consumers) ---
plugin_count="$(yq -r '.plugins // [] | length' "${DEVRAIL_YML}" 2>/dev/null || echo 0)"
if [[ "${plugin_count}" == "0" ]]; then
  # Even if .devrail.lock exists, having no plugins declared means there is
  # nothing for the loader to load. Quietly succeed.
  exit 0
fi

# --- Lockfile must exist when plugins are declared ---
if [[ ! -r "${LOCKFILE}" ]]; then
  log_event error "lockfile missing" \
    path="${LOCKFILE}" \
    reason="run \`make plugins-update\` to generate .devrail.lock" \
    language=_plugins
  exit 2
fi

require_cmd "sha256sum" "sha256sum is required (coreutils)"

# compute_content_hash <dir>
compute_content_hash() {
  local dir="$1"
  (cd "${dir}" && find . -type f \
    -not -path './.git/*' \
    -not -name '.devrail.sha' \
    -print0 |
    sort -z |
    xargs -0 sha256sum |
    sha256sum |
    cut -d' ' -f1)
}

# --- Cross-check every yml entry has a matching lock entry with same rev ---
violations=0
for i in $(seq 0 $((plugin_count - 1))); do
  yml_source="$(yq -r ".plugins[${i}].source // \"\"" "${DEVRAIL_YML}")"
  yml_rev="$(yq -r ".plugins[${i}].rev // \"\"" "${DEVRAIL_YML}")"
  if [[ -z "${yml_source}" || -z "${yml_rev}" ]]; then
    log_event error "plugin entry missing source or rev" \
      index:="${i}" source="${yml_source}" rev="${yml_rev}" language=_plugins
    violations=$((violations + 1))
    continue
  fi

  lock_rev="$(yq -r ".plugins[] | select(.source == \"${yml_source}\") | .rev" "${LOCKFILE}" 2>/dev/null | head -1)"
  if [[ -z "${lock_rev}" || "${lock_rev}" == "null" ]]; then
    log_event error "lockfile mismatch" \
      source="${yml_source}" \
      reason="no entry in .devrail.lock; run \`make plugins-update\`" \
      language=_plugins
    violations=$((violations + 1))
    continue
  fi
  if [[ "${lock_rev}" != "${yml_rev}" ]]; then
    log_event error "lockfile mismatch" \
      source="${yml_source}" \
      yml_rev="${yml_rev}" lock_rev="${lock_rev}" \
      reason="rev disagreement; run \`make plugins-update\`" \
      language=_plugins
    violations=$((violations + 1))
    continue
  fi

  # Content-hash tampering check: re-compute hash of cached tree, compare
  # to the lockfile-recorded hash.
  recorded_hash="$(yq -r ".plugins[] | select(.source == \"${yml_source}\") | .content_hash" "${LOCKFILE}" 2>/dev/null | head -1)"
  recorded_hash="${recorded_hash#sha256:}"

  slug="$(basename "${yml_source}")"
  cached_dir="${PLUGINS_DIR}/${slug}/${yml_rev}"
  if [[ ! -d "${cached_dir}" ]]; then
    log_event error "cached tree missing" \
      source="${yml_source}" rev="${yml_rev}" path="${cached_dir}" \
      reason="run \`make plugins-update\` to repopulate the cache" \
      language=_plugins
    violations=$((violations + 1))
    continue
  fi

  actual_hash="$(compute_content_hash "${cached_dir}")"
  if [[ "${actual_hash}" != "${recorded_hash}" ]]; then
    log_event error "content_hash mismatch (tampering or stale cache)" \
      source="${yml_source}" rev="${yml_rev}" \
      recorded="sha256:${recorded_hash}" actual="sha256:${actual_hash}" \
      reason="cached tree differs from lockfile; run \`make plugins-update\`" \
      language=_plugins
    violations=$((violations + 1))
    continue
  fi
done

if [[ "${violations}" -gt 0 ]]; then
  log_event error "lockfile verification failed" violations:="${violations}" language=_plugins
  exit 2
fi

log_event info "lockfile verified" plugins:="${plugin_count}" language=_plugins
exit 0
