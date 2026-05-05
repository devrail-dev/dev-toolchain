#!/usr/bin/env bash
# lib/plugin-execute.sh — Plugin execution dispatcher (Story 13.5)
#
# Purpose: Sourceable library that dispatches each loaded plugin's target
#          inside the existing _lint/_format/_fix/_test/_security Makefile
#          recipes. Reads from the loader cache (Story 13.2) and updates
#          caller-scope shell variables (overall_exit, ran_languages,
#          failed_languages) so plugin results aggregate into the same JSON
#          shape as core languages.
#
# Usage:   source /opt/devrail/lib/plugin-execute.sh
#          dispatch_plugin_target lint    # or format_check|format_fix|test|security
#
# Contract with Makefile recipes:
#   - Caller MUST have these shell vars in scope: overall_exit, ran_languages,
#     failed_languages (the recipe's own accounting variables).
#   - Caller is responsible for the per-block DEVRAIL_FAIL_FAST short-circuit;
#     dispatch_plugin_target itself stops iterating on first failure when
#     DEVRAIL_FAIL_FAST=1, and sets overall_exit=1.
#   - No-op when the loader cache contains no plugins.
#
# Dependencies: lib/log.sh (log_event), yq (v4+), bash 5+

# Guard against double-sourcing
# shellcheck disable=SC2317
if [[ -n "${_DEVRAIL_PLUGIN_EXECUTE_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
readonly _DEVRAIL_PLUGIN_EXECUTE_LOADED=1

# Resolve log_event from lib/log.sh if not already sourced. Inside the
# container the canonical path is /opt/devrail/lib; tests can override via
# DEVRAIL_LIB.
if ! declare -f log_event >/dev/null 2>&1; then
  # shellcheck source=./log.sh
  source "${DEVRAIL_LIB:-/opt/devrail/lib}/log.sh"
fi

# _devrail_plugin_cache_path returns the cache file path.
# Single helper so future relocation only changes this function.
_devrail_plugin_cache_path() {
  printf '%s' "${DEVRAIL_PLUGINS_CACHE:-/tmp/devrail-plugins-loaded.yaml}"
}

# _devrail_plugin_count returns the number of loaded plugins (0 when cache
# is missing/empty/malformed). Always exits 0 — the dispatcher uses the
# count as a gate, not as a parse-validity signal (the loader has already
# validated the cache by the time the dispatcher runs).
_devrail_plugin_count() {
  local cache
  cache="$(_devrail_plugin_cache_path)"
  if [[ ! -s "${cache}" ]]; then
    printf '0'
    return 0
  fi
  yq -r '.plugins // [] | length' "${cache}" 2>/dev/null || printf '0'
}

# evaluate_gate <plugin-index> <target-name>
# Returns 0 if every gate path exists (file/dir/glob match), 1 otherwise.
# A skip emits a structured "plugin gate skipped" event listing the missing
# path(s). Empty list or missing key = pass (always run).
#
# Gate path semantics (per design doc § "Manifest schema rules"):
#   - Workspace-relative only; absolute paths rejected (config error)
#   - Each path matches if it exists as a file OR directory OR has at least
#     one glob match (compgen -G)
#   - ALL paths must match for the gate to pass
evaluate_gate() {
  local idx="${1:?evaluate_gate requires a plugin index}"
  local target="${2:?evaluate_gate requires a target name}"
  local cache plugin_name gate_count i path missing=""

  cache="$(_devrail_plugin_cache_path)"
  plugin_name="$(yq -r ".plugins[${idx}].name // \"\"" "${cache}" 2>/dev/null)"

  gate_count="$(yq -r ".plugins[${idx}].gates.${target} // [] | length" "${cache}" 2>/dev/null || printf '0')"
  if [[ "${gate_count}" == "0" ]]; then
    return 0
  fi

  for ((i = 0; i < gate_count; i++)); do
    path="$(yq -r ".plugins[${idx}].gates.${target}[${i}]" "${cache}" 2>/dev/null)"
    if [[ -z "${path}" || "${path}" == "null" ]]; then
      continue
    fi
    if [[ "${path}" == /* ]]; then
      log_event error "plugin gate path must be workspace-relative" \
        plugin="${plugin_name}" target="${target}" path="${path}" \
        language=_plugins
      return 1
    fi
    # File or directory check first (cheap), then glob fallback.
    if [[ -e "${path}" ]]; then
      continue
    fi
    if compgen -G "${path}" >/dev/null 2>&1; then
      continue
    fi
    missing="${missing:+${missing}, }${path}"
  done

  if [[ -n "${missing}" ]]; then
    log_event info "plugin gate skipped" \
      plugin="${plugin_name}" target="${target}" missing="${missing}" \
      language=_plugins
    return 1
  fi
  return 0
}

# render_cmd <plugin-index> <target-name>
# Prints the rendered command string on stdout.
# Substitutes {paths} with the runtime value of ${<paths_var>} filtered to
# existing paths (mirroring how RUBY_PATHS is filtered in the Ruby block of
# the core Makefile). Falls back to paths_default if the env var is unset.
# When cmd contains literal `{paths}` but no paths_var is declared, exits 2
# with a structured error (configuration mistake).
render_cmd() {
  local idx="${1:?render_cmd requires a plugin index}"
  local target="${2:?render_cmd requires a target name}"
  local cache cmd paths_var paths_default plugin_name p filtered=""

  cache="$(_devrail_plugin_cache_path)"
  plugin_name="$(yq -r ".plugins[${idx}].name // \"\"" "${cache}" 2>/dev/null)"
  cmd="$(yq -r ".plugins[${idx}].targets.${target}.cmd // \"\"" "${cache}" 2>/dev/null)"

  if [[ "${cmd}" != *"{paths}"* ]]; then
    printf '%s' "${cmd}"
    return 0
  fi

  paths_var="$(yq -r ".plugins[${idx}].targets.${target}.paths_var // \"\"" "${cache}" 2>/dev/null)"
  paths_default="$(yq -r ".plugins[${idx}].targets.${target}.paths_default // \"\"" "${cache}" 2>/dev/null)"

  if [[ -z "${paths_var}" || "${paths_var}" == "null" ]]; then
    log_event error "plugin cmd uses {paths} but declares no paths_var" \
      plugin="${plugin_name}" target="${target}" cmd="${cmd}" \
      language=_plugins
    exit 2
  fi

  local raw="${!paths_var:-${paths_default}}"
  for p in ${raw}; do
    if [[ -e "${p}" ]]; then
      filtered="${filtered:+${filtered} }${p}"
    fi
  done

  printf '%s' "${cmd//\{paths\}/${filtered}}"
}

# apply_override <language> <target-name> <default-cmd>
# Prints the user-supplied override from .devrail.yml when present, otherwise
# echoes the default cmd back. Override key by target:
#   lint         → linter
#   format_check → formatter
#   format_fix   → formatter (same as format_check; symmetric with core)
#   fix          → fixer
#   test         → test
#   security     → security
# The override replaces the entire cmd string (no {paths} interpolation).
apply_override() {
  local language="${1:?apply_override requires a language}"
  local target="${2:?apply_override requires a target name}"
  local default_cmd="${3:-}"
  local devrail_yml="${DEVRAIL_CONFIG:-/workspace/.devrail.yml}"
  local key override

  if [[ ! -r "${devrail_yml}" ]]; then
    printf '%s' "${default_cmd}"
    return 0
  fi

  case "${target}" in
  lint) key="linter" ;;
  format_check | format_fix) key="formatter" ;;
  fix) key="fixer" ;;
  test) key="test" ;;
  security) key="security" ;;
  *)
    printf '%s' "${default_cmd}"
    return 0
    ;;
  esac

  override="$(LANG_KEY="${language}" KEY="${key}" yq -r '.[strenv(LANG_KEY)][strenv(KEY)] // ""' "${devrail_yml}" 2>/dev/null)"
  if [[ -n "${override}" && "${override}" != "null" ]]; then
    printf '%s' "${override}"
    return 0
  fi
  printf '%s' "${default_cmd}"
}

# dispatch_plugin_target <target-name>
# Iterates over loaded plugins; for each plugin that defines this target,
# evaluates the gate, renders the command, applies any per-language override,
# and runs the cmd via `bash -c`. Updates caller-scope shell variables
# (overall_exit, ran_languages, failed_languages) and honours
# DEVRAIL_FAIL_FAST=1 by returning early after the first failure.
#
# No-op when no plugins are loaded.
dispatch_plugin_target() {
  local target="${1:?dispatch_plugin_target requires a target name}"
  local plugin_count i name cmd rendered final_cmd plugin_exit

  plugin_count="$(_devrail_plugin_count)"
  if [[ "${plugin_count}" == "0" ]]; then
    return 0
  fi

  local cache
  cache="$(_devrail_plugin_cache_path)"

  for ((i = 0; i < plugin_count; i++)); do
    name="$(yq -r ".plugins[${i}].name" "${cache}")"
    cmd="$(yq -r ".plugins[${i}].targets.${target}.cmd // \"\"" "${cache}" 2>/dev/null)"
    if [[ -z "${cmd}" || "${cmd}" == "null" ]]; then
      # Plugin doesn't expose this target — silent skip (no event).
      continue
    fi

    if ! evaluate_gate "${i}" "${target}"; then
      continue
    fi

    rendered="$(render_cmd "${i}" "${target}")"
    final_cmd="$(apply_override "${name}" "${target}" "${rendered}")"

    log_event info "plugin target executing" \
      plugin="${name}" target="${target}" language=_plugins
    plugin_exit=0
    bash -c "${final_cmd}" || plugin_exit=$?
    if [[ "${plugin_exit}" -eq 0 ]]; then
      # shellcheck disable=SC2034  # caller-scope variable from Makefile recipe
      ran_languages="${ran_languages}\"${name}\","
      log_event info "plugin target passed" \
        plugin="${name}" target="${target}" language=_plugins
    else
      # shellcheck disable=SC2034  # caller-scope variables from Makefile recipe
      ran_languages="${ran_languages}\"${name}\","
      # shellcheck disable=SC2034
      failed_languages="${failed_languages}\"${name}\","
      # shellcheck disable=SC2034
      overall_exit=1
      log_event error "plugin target failed" \
        plugin="${name}" target="${target}" exit_code:="${plugin_exit}" \
        language=_plugins
      if [[ "${DEVRAIL_FAIL_FAST}" == "1" ]]; then
        return 1
      fi
    fi
  done

  return 0
}
