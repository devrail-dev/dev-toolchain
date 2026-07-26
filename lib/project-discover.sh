#!/usr/bin/env bash
# lib/project-discover.sh — Project-root autodiscovery for monorepos (Story 15.1)
#
# Purpose: Discover the directory (or directories) a given language's project
#          lives in, so Makefile recipes can run that language's tools with
#          the correct cwd instead of always assuming repo root. Closes
#          issue #53 (tools ignore subdir project configs in monorepos).
#
# Usage:   source "${DEVRAIL_LIB}/project-discover.sh"
#          while IFS= read -r root; do ...; done < <(discover_project_roots python)
#
# Contract:
#   - Output: newline-separated relative paths, no trailing slash, one or
#     more per call — NEVER empty. Callers can always safely loop over the
#     result without a "did we find anything" branch.
#   - `.devrail.yml` `projects:` (list of {path, languages}) overrides
#     autodetection for any language it names. Entries not naming a
#     language fall through to autodetection for that language.
#   - Autodetection rules (see _project_discover_normalize):
#       * a manifest at repo root (.) wins outright — output is just "."
#         even if unrelated nested manifests exist elsewhere (e.g. inside an
#         examples/ directory) — avoids double-running tools over the same
#         files once from "." (which already recurses) and again per nested
#         dir.
#       * no manifest found anywhere — output is "." — preserves
#         pre-Story-15.1 behavior verbatim (tools always ran from repo root
#         when no per-project signal existed; Story 15.1 AC 4).
#       * otherwise — output is every directory containing a manifest (the
#         true monorepo case; Story 15.1 AC 1/AC 7).
#   - Excludes .git, node_modules, vendor, .venv, venv, dist, build, target,
#     .terraform subtrees (mirrors the per-language find excludes already
#     used in _lint/_format/_fix).
#
# Supported languages: python, javascript, go, rust (Story 15.3). Ansible
# was evaluated for Story 15.3 and explicitly excluded — ansible-lint
# already recursively discovers playbooks from cwd regardless of where
# they live, with no root-marker file needed the way go.mod/Cargo.toml
# are for their respective toolchains; there is nothing here for it to
# autodetect. Any other language returns "." with a warning.
#
# Dependencies: lib/log.sh (log_warn), yq (v4+), bash 5+, coreutils (find)

# Guard against double-sourcing
# shellcheck disable=SC2317
if [[ -n "${_DEVRAIL_PROJECT_DISCOVER_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
readonly _DEVRAIL_PROJECT_DISCOVER_LOADED=1

_PROJECT_DISCOVER_CONFIG="${DEVRAIL_CONFIG:-.devrail.yml}"
_PROJECT_DISCOVER_FIND_EXCLUDES=(
  -not -path './.git/*'
  -not -path './node_modules/*'
  -not -path './vendor/*'
  -not -path './.venv/*'
  -not -path './venv/*'
  -not -path './dist/*'
  -not -path './build/*'
  -not -path './target/*'
  -not -path './.terraform/*'
)

# _project_discover_override emits the projects: path(s) declared for a
# language in .devrail.yml, one per line. Empty if no override applies.
_project_discover_override() {
  local language="$1"
  [[ -r "${_PROJECT_DISCOVER_CONFIG}" ]] || return 0
  # Delimiter is "::" rather than a tab: yq (mikefarah) does not reliably
  # expand \t as an escape in its expression string, so a literal two-char
  # backslash-t was previously emitted instead of a real tab, silently
  # breaking the awk field split below (caught in Story 15.1 testing).
  yq -r '.projects // [] | .[] | [.path, (.languages // [])[]] | join("::")' \
    "${_PROJECT_DISCOVER_CONFIG}" 2>/dev/null |
    awk -F'::' -v lang="${language}" '$2 == lang { print $1 }'
}

# _project_discover_normalize reads candidate directory paths on stdin (one
# per line, already de-duplicated) and applies the "root wins" / "fallback
# to root" rules documented above. Always emits at least one line.
_project_discover_normalize() {
  local candidates
  candidates="$(cat)"
  if [[ -z "${candidates}" ]]; then
    printf '.\n'
  elif grep -qx '\.' <<<"${candidates}"; then
    printf '.\n'
  else
    printf '%s\n' "${candidates}"
  fi
}

# _project_discover_autodetect_python finds directories containing a Python
# project manifest (pyproject.toml, setup.py, or setup.cfg — first match per
# directory wins so a directory isn't reported twice).
_project_discover_autodetect_python() {
  find . \( -name 'pyproject.toml' -o -name 'setup.py' -o -name 'setup.cfg' \) \
    "${_PROJECT_DISCOVER_FIND_EXCLUDES[@]}" -print0 2>/dev/null |
    xargs -0 -I{} dirname {} |
    sort -u |
    sed 's#^\./##' |
    _project_discover_normalize
}

# _project_discover_autodetect_javascript finds directories containing a
# package.json.
_project_discover_autodetect_javascript() {
  find . -name 'package.json' \
    "${_PROJECT_DISCOVER_FIND_EXCLUDES[@]}" -print0 2>/dev/null |
    xargs -0 -I{} dirname {} |
    sort -u |
    sed 's#^\./##' |
    _project_discover_normalize
}

# _project_discover_autodetect_go finds directories containing a go.mod.
_project_discover_autodetect_go() {
  find . -name 'go.mod' \
    "${_PROJECT_DISCOVER_FIND_EXCLUDES[@]}" -print0 2>/dev/null |
    xargs -0 -I{} dirname {} |
    sort -u |
    sed 's#^\./##' |
    _project_discover_normalize
}

# _project_discover_autodetect_rust finds directories containing a
# Cargo.toml.
_project_discover_autodetect_rust() {
  find . -name 'Cargo.toml' \
    "${_PROJECT_DISCOVER_FIND_EXCLUDES[@]}" -print0 2>/dev/null |
    xargs -0 -I{} dirname {} |
    sort -u |
    sed 's#^\./##' |
    _project_discover_normalize
}

# discover_project_roots <language> emits newline-separated project root
# paths for the given language. Never empty — see _project_discover_normalize.
discover_project_roots() {
  local language="${1:?discover_project_roots requires a language}"

  local override
  override="$(_project_discover_override "${language}")"
  if [[ -n "${override}" ]]; then
    local override_path
    while IFS= read -r override_path; do
      [[ -d "${override_path}" ]] || log_warn "projects: path '${override_path}' (language '${language}') does not exist in the repository"
    done <<<"${override}"
    printf '%s\n' "${override}"
    return 0
  fi

  case "${language}" in
  python) _project_discover_autodetect_python ;;
  javascript) _project_discover_autodetect_javascript ;;
  go) _project_discover_autodetect_go ;;
  rust) _project_discover_autodetect_rust ;;
  *)
    log_warn "discover_project_roots: no autodetection rule for language '${language}'"
    printf '.\n'
    ;;
  esac
}
