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
# Dependencies: yq v4+, sha256sum, find, sort, lib/log.sh, lib/plugin-cache.sh

set -euo pipefail
LC_ALL=C
export LC_ALL

# --- Resolve library path ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVRAIL_LIB="${DEVRAIL_LIB:-${SCRIPT_DIR}/../lib}"

# shellcheck source=../lib/log.sh
source "${DEVRAIL_LIB}/log.sh"
# shellcheck source=../lib/plugin-cache.sh
source "${DEVRAIL_LIB}/plugin-cache.sh"

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

# Distinguish "yq parse error" from "no plugins declared" (review fix H1).
parse_plugin_count() {
  local count
  if ! count="$(yq -r '.plugins // [] | length' "${DEVRAIL_YML}" 2>&1)"; then
    log_event error "config could not be parsed by yq" \
      path="${DEVRAIL_YML}" reason="${count}" language=_plugins
    return 1
  fi
  printf "%s" "${count}"
}

if ! plugin_count="$(parse_plugin_count)"; then
  exit 2
fi

# --- No-op when no plugins declared (regression-safe for v1.9.x consumers) ---
if [[ "${plugin_count}" == "0" ]]; then
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

  # Pass yml_source via env (strenv) so a malicious source URL with quotes,
  # backslashes, or yq-expression-special characters can't break the query
  # (review fix M1).
  lock_rev="$(yml_source="${yml_source}" yq -r '.plugins[] | select(.source == strenv(yml_source)) | .rev' "${LOCKFILE}" 2>/dev/null | head -1)"
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

  # Content-hash tampering check.
  recorded_hash="$(yml_source="${yml_source}" yq -r '.plugins[] | select(.source == strenv(yml_source)) | .content_hash' "${LOCKFILE}" 2>/dev/null | head -1)"
  recorded_hash="${recorded_hash#sha256:}"

  if ! slug="$(derive_slug "${yml_source}")"; then
    log_event error "plugin source URL produced an invalid slug" \
      source="${yml_source}" rev="${yml_rev}" language=_plugins
    violations=$((violations + 1))
    continue
  fi
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
