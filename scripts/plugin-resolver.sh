#!/usr/bin/env bash
# scripts/plugin-resolver.sh — Resolve plugin refs and write .devrail.lock
#
# Purpose: For each plugin declared in `.devrail.yml`, resolve the `rev:`
#          (tag or SHA) to an immutable SHA via `git ls-remote`, fetch the
#          plugin repo to a content-addressed cache directory, compute a
#          deterministic content_hash of the tree, and write a sorted YAML
#          lockfile atomically.
#
# Usage:   bash scripts/plugin-resolver.sh [<devrail-yml-path>] [--help]
#          Default config path: .devrail.yml in CWD.
#          Exit 0 — lockfile written (or no-op if no plugins declared)
#          Exit 2 — resolution / fetch / configuration failure
#
# Dependencies: yq v4+, git 2+, sha256sum, find, sort, lib/log.sh,
#               lib/version.sh

set -euo pipefail
LC_ALL=C
export LC_ALL

# --- Resolve library path ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVRAIL_LIB="${DEVRAIL_LIB:-${SCRIPT_DIR}/../lib}"

# shellcheck source=../lib/log.sh
source "${DEVRAIL_LIB}/log.sh"
# shellcheck source=../lib/version.sh
source "${DEVRAIL_LIB}/version.sh"

# --- Help ---
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  log_info "plugin-resolver.sh — Resolve plugin refs and write .devrail.lock"
  log_info "Usage: bash scripts/plugin-resolver.sh [<devrail-yml-path>]"
  log_info "Default config: .devrail.yml; default plugins dir: \$DEVRAIL_PLUGINS_DIR"
  log_info "Exit 0 — success or no-op; 2 — resolution/fetch failure"
  exit 0
fi

# --- Constants ---
readonly LOCKFILE_SCHEMA_VERSION=1
readonly SHA_REGEX='^[a-f0-9]{40}$'

# --- Args ---
DEVRAIL_YML="${1:-.devrail.yml}"
PLUGINS_DIR="${DEVRAIL_PLUGINS_DIR:-/opt/devrail/plugins}"
LOCKFILE="$(dirname "${DEVRAIL_YML}")/.devrail.lock"
LOCKFILE_TMP="${LOCKFILE}.tmp.$$"

if [[ ! -r "${DEVRAIL_YML}" ]]; then
  log_event error "config not readable" path="${DEVRAIL_YML}" language=_plugins
  exit 2
fi

require_cmd "yq" "yq is required (v4+)"
require_cmd "git" "git is required"
require_cmd "sha256sum" "sha256sum is required (coreutils)"

# Always remove the temp lockfile on exit (atomic-write contract).
trap 'rm -f "${LOCKFILE_TMP}"' EXIT

# resolve_ref <source-url> <rev>
# Echoes the resolved SHA on stdout.
# Rejects branch refs and unrecognised refs with a non-zero return.
resolve_ref() {
  local source_url="$1"
  local rev="$2"

  # Branch detection — if the rev matches a remote head, reject.
  local heads_match
  heads_match="$(git -c protocol.file.allow=always ls-remote --heads "${source_url}" "${rev}" 2>/dev/null || true)"
  if [[ -n "${heads_match}" ]]; then
    log_event error "branch refs are not allowed" \
      source="${source_url}" rev="${rev}" \
      reason="pin a tag or 40-char SHA, not a branch" \
      language=_plugins
    return 1
  fi

  # SHA passthrough: if rev looks like a 40-char hex, accept it directly.
  if [[ "${rev}" =~ ${SHA_REGEX} ]]; then
    printf "%s" "${rev}"
    return 0
  fi

  # Tag resolution. Prefer the dereferenced (peeled) tag entry "<sha> refs/tags/<tag>^{}"
  # for annotated tags; fall back to the lightweight tag entry.
  local refs sha=""
  refs="$(git -c protocol.file.allow=always ls-remote --tags "${source_url}" "${rev}" 2>/dev/null || true)"
  if [[ -z "${refs}" ]]; then
    log_event error "ref not found at source" \
      source="${source_url}" rev="${rev}" \
      reason="not a tag, branch, or recognisable SHA at the given source" \
      language=_plugins
    return 1
  fi
  # Look for peeled annotated form first (suffix ^{})
  sha="$(printf '%s\n' "${refs}" | awk '$2 ~ /\^\{\}$/ {print $1; exit}')"
  if [[ -z "${sha}" ]]; then
    sha="$(printf '%s\n' "${refs}" | awk 'NR==1 {print $1}')"
  fi
  if [[ ! "${sha}" =~ ${SHA_REGEX} ]]; then
    log_event error "ref resolution produced invalid SHA" \
      source="${source_url}" rev="${rev}" got="${sha}" \
      language=_plugins
    return 1
  fi
  printf "%s" "${sha}"
}

# fetch_to_cache <source-url> <slug> <rev>
# Clones the source at <sha> into ${PLUGINS_DIR}/<slug>/<rev>/ if not already
# present. Idempotent — if the cached tree exists, no fetch occurs.
fetch_to_cache() {
  local source_url="$1"
  local slug="$2"
  local rev="$3"
  local sha="$4"
  local target="${PLUGINS_DIR}/${slug}/${rev}"

  if [[ -f "${target}/plugin.devrail.yml" && -f "${target}/.devrail.sha" ]]; then
    local existing
    existing="$(cat "${target}/.devrail.sha")"
    if [[ "${existing}" == "${sha}" ]]; then
      log_event info "plugin already cached" slug="${slug}" rev="${rev}" sha="${sha}" language=_plugins
      return 0
    fi
  fi

  log_event info "fetching plugin" source="${source_url}" rev="${rev}" sha="${sha}" language=_plugins

  mkdir -p "${target}"
  local fetch_dir
  fetch_dir="$(mktemp -d "${target}.fetch.XXXXXX")"
  if ! (cd "${fetch_dir}" && git init --quiet &&
    git -c protocol.file.allow=always remote add origin "${source_url}" &&
    git -c protocol.file.allow=always fetch --quiet --depth 1 origin "${sha}" &&
    git checkout --quiet FETCH_HEAD); then
    log_event error "git fetch failed" source="${source_url}" sha="${sha}" language=_plugins
    rm -rf "${fetch_dir}"
    return 1
  fi

  # Move the fetched tree contents into target/, atomically replacing any
  # stale cached copy of the same slug/rev.
  rm -rf "${target}"
  mv "${fetch_dir}" "${target}"
  printf "%s\n" "${sha}" >"${target}/.devrail.sha"
}

# compute_content_hash <dir>
# Deterministic hash of all non-.git/ files in the directory.
# Stable across machines (LC_ALL=C, find+sort+sha256sum chain).
compute_content_hash() {
  local dir="$1"
  if [[ ! -d "${dir}" ]]; then
    log_event error "content_hash directory missing" path="${dir}" language=_plugins
    return 1
  fi
  (cd "${dir}" && find . -type f \
    -not -path './.git/*' \
    -not -name '.devrail.sha' \
    -print0 |
    sort -z |
    xargs -0 sha256sum |
    sha256sum |
    cut -d' ' -f1)
}

# --- Main ---

plugin_count="$(yq -r '.plugins // [] | length' "${DEVRAIL_YML}" 2>/dev/null || echo 0)"
if [[ "${plugin_count}" == "0" ]]; then
  log_event info "no plugins declared; lockfile not generated" language=_plugins
  exit 0
fi

log_event info "resolving plugins" plugin_count:="${plugin_count}" language=_plugins

# Build entries in a deterministic-by-source-URL order. We collect them in an
# associative-array-keyed-by-source map, then sort the keys before writing.
declare -a SOURCES_ORDER=()
declare -A ENTRY_BY_SOURCE=()

failed=0
for i in $(seq 0 $((plugin_count - 1))); do
  source_url="$(yq -r ".plugins[${i}].source // \"\"" "${DEVRAIL_YML}")"
  rev="$(yq -r ".plugins[${i}].rev // \"\"" "${DEVRAIL_YML}")"

  if [[ -z "${source_url}" || -z "${rev}" ]]; then
    log_event error "plugin entry missing source or rev" \
      index:="${i}" source="${source_url}" rev="${rev}" language=_plugins
    failed=$((failed + 1))
    continue
  fi

  slug="$(basename "${source_url}")"

  if ! sha="$(resolve_ref "${source_url}" "${rev}")"; then
    failed=$((failed + 1))
    continue
  fi

  if ! fetch_to_cache "${source_url}" "${slug}" "${rev}" "${sha}"; then
    failed=$((failed + 1))
    continue
  fi

  manifest="${PLUGINS_DIR}/${slug}/${rev}/plugin.devrail.yml"
  if [[ ! -r "${manifest}" ]]; then
    log_event error "fetched tree is missing plugin.devrail.yml" \
      source="${source_url}" rev="${rev}" path="${manifest}" language=_plugins
    failed=$((failed + 1))
    continue
  fi

  schema_version="$(yq -r '.schema_version' "${manifest}" 2>/dev/null || echo "")"
  if [[ -z "${schema_version}" || "${schema_version}" == "null" ]]; then
    log_event error "manifest schema_version not readable" \
      source="${source_url}" rev="${rev}" language=_plugins
    failed=$((failed + 1))
    continue
  fi

  if ! content_hash="$(compute_content_hash "${PLUGINS_DIR}/${slug}/${rev}")"; then
    failed=$((failed + 1))
    continue
  fi

  # Build an entry for this source. Entries get sorted by `source` before write.
  entry_block="$(printf '  - source: %s\n    rev: %s\n    sha: %s\n    schema_version: %s\n    content_hash: sha256:%s\n' \
    "${source_url}" "${rev}" "${sha}" "${schema_version}" "${content_hash}")"
  if [[ -z "${ENTRY_BY_SOURCE[${source_url}]:-}" ]]; then
    SOURCES_ORDER+=("${source_url}")
  fi
  ENTRY_BY_SOURCE["${source_url}"]="${entry_block}"
done

if [[ "${failed}" -gt 0 ]]; then
  log_event error "plugin resolver failed" failed:="${failed}" language=_plugins
  # Atomic: do NOT touch the existing lockfile on partial failure.
  exit 2
fi

# Sort sources alphabetically for deterministic lockfile output.
mapfile -t SOURCES_SORTED < <(printf '%s\n' "${SOURCES_ORDER[@]}" | sort)

{
  printf 'schema_version: %s\n' "${LOCKFILE_SCHEMA_VERSION}"
  printf 'plugins:\n'
  for src in "${SOURCES_SORTED[@]}"; do
    printf '%s\n' "${ENTRY_BY_SOURCE[${src}]}"
  done
} >"${LOCKFILE_TMP}"

mv "${LOCKFILE_TMP}" "${LOCKFILE}"

log_event info "lockfile written" path="${LOCKFILE}" plugins:="${plugin_count}" language=_plugins
exit 0
