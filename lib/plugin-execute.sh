#!/usr/bin/env bash
# lib/plugin-execute.sh — Plugin execution dispatcher (Story 13.5)
#
# Purpose: Sourceable library that dispatches each loaded plugin's target
#          inside the existing _lint/_format/_fix/_test/_security Makefile
#          recipes. Reads from the loader cache (Story 13.2) and updates
#          caller-scope shell variables (overall_exit, ran_languages,
#          failed_languages, skipped_languages) so plugin results aggregate
#          into the same JSON shape as core languages.
#
# Usage:   source /opt/devrail/lib/plugin-execute.sh
#          dispatch_plugin_target lint    # or format_check|format_fix|fix|test|security
#
# Contract with Makefile recipes:
#   - Caller MUST have these shell vars in scope: overall_exit, ran_languages,
#     failed_languages (the recipe's own accounting variables). For _test and
#     _security recipes, skipped_languages is also updated on gate-skip.
#   - Caller is responsible for the per-block DEVRAIL_FAIL_FAST short-circuit;
#     dispatch_plugin_target itself stops iterating on first failure when
#     DEVRAIL_FAIL_FAST=1, and sets overall_exit=1.
#   - No-op when the loader cache contains no plugins.
#   - Internal helpers MUST NOT exit; they return non-zero so the dispatcher
#     can surface failures via the recipe's JSON envelope (review H1).
#
# Performance:
#   The cache and `.devrail.yml` are converted to JSON once at the start of
#   each dispatch and re-used via jq for all per-plugin / per-target lookups.
#   Earlier revisions invoked yq ~8N times per recipe (review M3); the
#   current path is 2 yq calls + ~3N jq calls.
#
# Optional env:
#   DEVRAIL_PLUGIN_TIMEOUT_SECONDS — wraps each plugin cmd in `timeout -k 5 N`
#       (review M4). Unset = no timeout (default).
#
# Dependencies: lib/log.sh (log_event), yq (v4+), jq, bash 5+, coreutils
#               (timeout — only when DEVRAIL_PLUGIN_TIMEOUT_SECONDS is set)

# Guard against double-sourcing (review L2 — covered by tests case 14)
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
_devrail_plugin_cache_path() {
  printf '%s' "${DEVRAIL_PLUGINS_CACHE:-/tmp/devrail-plugins-loaded.yaml}"
}

# Note: the cache + .devrail.yml load is inlined into dispatch_plugin_target
# rather than factored into a helper. A helper that returned both JSON blobs
# via `printf -v <out-var>` would shadow the caller's var when both used the
# same name (bash's `local` scoping breaks indirect assignment that way), so
# we keep the parse inline. The single yq → JSON conversion still happens
# only once per dispatch (review M3).

# evaluate_gate <cache-json> <plugin-index> <target-name> <plugin-name>
# Returns:
#   0 — gate passed (target should run)
#   1 — gate skip (path missing); emits structured info event
#   2 — gate config error (absolute path); emits structured error event
#
# The caller treats 1 as silent skip, 2 as plugin failure (review M1).
evaluate_gate() {
  local cache_json="${1:?evaluate_gate requires cache JSON}"
  local idx="${2:?evaluate_gate requires a plugin index}"
  local target="${3:?evaluate_gate requires a target name}"
  local plugin_name="${4:?evaluate_gate requires a plugin name}"
  local gates path missing=""

  gates="$(IDX="${idx}" TARGET="${target}" \
    jq -r '.plugins[env.IDX|tonumber].gates[env.TARGET] // [] | .[]' \
    <<<"${cache_json}")"
  if [[ -z "${gates}" ]]; then
    return 0
  fi

  while IFS= read -r path; do
    [[ -z "${path}" || "${path}" == "null" ]] && continue
    if [[ "${path}" == /* ]]; then
      log_event error "plugin gate path must be workspace-relative" \
        plugin="${plugin_name}" target="${target}" path="${path}" \
        language=_plugins
      return 2
    fi
    # File or directory check first (cheap), then glob fallback.
    if [[ -e "${path}" ]]; then
      continue
    fi
    if compgen -G "${path}" >/dev/null 2>&1; then
      continue
    fi
    missing="${missing:+${missing}, }${path}"
  done <<<"${gates}"

  if [[ -n "${missing}" ]]; then
    log_event info "plugin gate skipped" \
      plugin="${plugin_name}" target="${target}" missing="${missing}" \
      language=_plugins
    return 1
  fi
  return 0
}

# render_cmd <cache-json> <plugin-index> <target-name> <plugin-name> <cmd>
# Prints the rendered command on stdout. `{paths}` is substituted with the
# value of `${<paths_var>}` filtered to existing paths whose names contain
# no shell-meta characters (review M6). Returns:
#   0 — rendered successfully
#   2 — config error (`{paths}` referenced but `paths_var` not declared);
#       emits structured error event (review H1: returns instead of exit)
render_cmd() {
  local cache_json="${1:?render_cmd requires cache JSON}"
  local idx="${2:?render_cmd requires a plugin index}"
  local target="${3:?render_cmd requires a target name}"
  local plugin_name="${4:?render_cmd requires a plugin name}"
  local cmd="${5:-}"
  local paths_var paths_default raw p filtered=""

  if [[ "${cmd}" != *"{paths}"* ]]; then
    printf '%s' "${cmd}"
    return 0
  fi

  paths_var="$(IDX="${idx}" TARGET="${target}" \
    jq -r '.plugins[env.IDX|tonumber].targets[env.TARGET].paths_var // ""' \
    <<<"${cache_json}")"
  paths_default="$(IDX="${idx}" TARGET="${target}" \
    jq -r '.plugins[env.IDX|tonumber].targets[env.TARGET].paths_default // ""' \
    <<<"${cache_json}")"

  if [[ -z "${paths_var}" || "${paths_var}" == "null" ]]; then
    log_event error "plugin cmd uses {paths} but declares no paths_var" \
      plugin="${plugin_name}" target="${target}" cmd="${cmd}" \
      language=_plugins
    return 2
  fi

  raw="${!paths_var:-${paths_default}}"
  for p in ${raw}; do
    # Reject shell-meta chars to keep `bash -c "${final_cmd}"` injection-free
    # when paths come from user-controlled env vars (review M6).
    case "${p}" in
    *[\;\|\&\$\<\>\(\)\`\\\"\']*)
      log_event warn "plugin path contains shell-meta characters; skipping" \
        plugin="${plugin_name}" target="${target}" path="${p}" \
        language=_plugins
      continue
      ;;
    esac
    if [[ -e "${p}" ]]; then
      filtered="${filtered:+${filtered} }${p}"
    fi
  done

  printf '%s' "${cmd//\{paths\}/${filtered}}"
}

# apply_override <devrail-json> <language> <target-name> <default-cmd>
# Prints the user-supplied override from `.devrail.yml` when present,
# otherwise echoes the default cmd back.
#
# Override key by target:
#   lint         → linter
#   format_check → formatter
#   format_fix   → formatter (same as format_check; symmetric with core)
#   fix          → fixer
#   test         → test
#   security     → security
#
# The override replaces the entire cmd string (no `{paths}` interpolation).
apply_override() {
  local devrail_json="${1:?apply_override requires devrail JSON}"
  local language="${2:?apply_override requires a language}"
  local target="${3:?apply_override requires a target name}"
  local default_cmd="${4:-}"
  local key override

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

  override="$(LANG_KEY="${language}" KEY="${key}" \
    jq -r '.[env.LANG_KEY][env.KEY] // ""' <<<"${devrail_json}")"
  if [[ -n "${override}" && "${override}" != "null" ]]; then
    printf '%s' "${override}"
    return 0
  fi
  printf '%s' "${default_cmd}"
}

# dispatch_plugin_target <target-name>
# Iterates over loaded plugins; for each plugin that defines this target,
# evaluates the gate, renders the command, applies any per-language override,
# and runs the cmd via `bash -c` (optionally wrapped in `timeout` when
# DEVRAIL_PLUGIN_TIMEOUT_SECONDS is set). Updates caller-scope shell
# variables and honours DEVRAIL_FAIL_FAST=1.
#
# Caller-scope vars updated:
#   overall_exit        — set to 1 on plugin failure (or config error)
#   ran_languages       — appended on success or failure (the plugin ran)
#   failed_languages    — appended on cmd failure or config error
#   skipped_languages   — appended on gate-skip (review L5; harmless when
#                         the recipe doesn't use it)
#
# No-op when no plugins are loaded.
dispatch_plugin_target() {
  local target="${1:?dispatch_plugin_target requires a target name}"

  # Register caller-scope vars so shellcheck doesn't flag the writes below
  # as SC2034 (review L1). The `:` builtin and `:=` default-assign keep the
  # vars alive in the caller's shell without overwriting existing values.
  : "${overall_exit:=0}" "${ran_languages:=}" "${failed_languages:=}" "${skipped_languages:=}"

  local cache cache_json devrail_yml devrail_json="{}" parsed plugin_count i
  cache="$(_devrail_plugin_cache_path)"
  if [[ ! -s "${cache}" ]]; then
    return 0
  fi
  if ! cache_json="$(yq -o=json . "${cache}" 2>&1)"; then
    log_event error "loader cache could not be parsed by yq" \
      cache="${cache}" stderr="${cache_json}" language=_plugins
    overall_exit=1
    failed_languages="${failed_languages}\"_plugins:cache-parse\","
    return 1
  fi
  devrail_yml="${DEVRAIL_CONFIG:-/workspace/.devrail.yml}"
  if [[ -r "${devrail_yml}" ]]; then
    if parsed="$(yq -o=json . "${devrail_yml}" 2>&1)"; then
      devrail_json="${parsed}"
    else
      log_event warn ".devrail.yml could not be parsed; per-language overrides disabled" \
        path="${devrail_yml}" stderr="${parsed}" language=_plugins
    fi
  fi

  plugin_count="$(jq -r '.plugins | length' <<<"${cache_json}")"
  if [[ -z "${plugin_count}" || "${plugin_count}" == "null" || "${plugin_count}" == "0" ]]; then
    return 0
  fi

  for ((i = 0; i < plugin_count; i++)); do
    local name cmd rendered render_status final_cmd plugin_exit gate_status
    name="$(IDX="${i}" jq -r '.plugins[env.IDX|tonumber].name // ""' <<<"${cache_json}")"
    cmd="$(IDX="${i}" TARGET="${target}" \
      jq -r '.plugins[env.IDX|tonumber].targets[env.TARGET].cmd // ""' \
      <<<"${cache_json}")"
    if [[ -z "${cmd}" || "${cmd}" == "null" ]]; then
      # Plugin doesn't expose this target — silent skip (review L3).
      continue
    fi

    gate_status=0
    evaluate_gate "${cache_json}" "${i}" "${target}" "${name}" || gate_status=$?
    case "${gate_status}" in
    0) ;; # gate passed; run target
    1)    # gate skip — silent (event already emitted)
      skipped_languages="${skipped_languages}\"${name}\","
      continue
      ;;
    2) # gate config error — surface as plugin failure
      overall_exit=1
      failed_languages="${failed_languages}\"${name}:gate-config\","
      if [[ "${DEVRAIL_FAIL_FAST}" == "1" ]]; then
        return 1
      fi
      continue
      ;;
    esac

    rendered=""
    render_status=0
    rendered="$(render_cmd "${cache_json}" "${i}" "${target}" "${name}" "${cmd}")" || render_status=$?
    if [[ "${render_status}" -ne 0 ]]; then
      overall_exit=1
      failed_languages="${failed_languages}\"${name}:cmd-config\","
      if [[ "${DEVRAIL_FAIL_FAST}" == "1" ]]; then
        return 1
      fi
      continue
    fi

    final_cmd="$(apply_override "${devrail_json}" "${name}" "${target}" "${rendered}")"

    log_event info "plugin target executing" \
      plugin="${name}" target="${target}" language=_plugins
    plugin_exit=0
    if [[ -n "${DEVRAIL_PLUGIN_TIMEOUT_SECONDS:-}" ]]; then
      timeout -k 5 "${DEVRAIL_PLUGIN_TIMEOUT_SECONDS}" \
        bash -c "${final_cmd}" || plugin_exit=$?
    else
      bash -c "${final_cmd}" || plugin_exit=$?
    fi
    if [[ "${plugin_exit}" -eq 0 ]]; then
      ran_languages="${ran_languages}\"${name}\","
      log_event info "plugin target passed" \
        plugin="${name}" target="${target}" language=_plugins
    else
      ran_languages="${ran_languages}\"${name}\","
      failed_languages="${failed_languages}\"${name}\","
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
