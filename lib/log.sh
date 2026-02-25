#!/usr/bin/env bash
# lib/log.sh — DevRail shared logging library
#
# Purpose: Provides structured logging functions for all DevRail scripts.
# Usage:   source "${DEVRAIL_LIB}/log.sh"
# Dependencies: None (standalone library)
#
# Environment variables:
#   DEVRAIL_LOG_FORMAT - Output format: "json" (default) or "human"
#   DEVRAIL_QUIET      - Set to "1" to suppress info messages
#   DEVRAIL_DEBUG      - Set to "1" to enable debug messages
#
# Functions:
#   log_info "message"    - Info-level message (suppressed by DEVRAIL_QUIET=1)
#   log_warn "message"    - Warning-level message (always shown)
#   log_error "message"   - Error-level message (always shown)
#   log_debug "message"   - Debug-level message (only when DEVRAIL_DEBUG=1)
#   die "message"         - log_error + exit 1
#   is_empty "$var"       - Returns 0 if variable is empty or unset
#   is_not_empty "$var"   - Returns 0 if variable has a value
#   is_set "var_name"     - Returns 0 if variable is declared
#   require_cmd "cmd" "msg" - Exit 2 if command not found

# Guard against double-sourcing
# shellcheck disable=SC2317
if [[ -n "${_DEVRAIL_LOG_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
readonly _DEVRAIL_LOG_LOADED=1

# --- Configuration ---

readonly DEVRAIL_LOG_FORMAT="${DEVRAIL_LOG_FORMAT:-json}"
readonly DEVRAIL_QUIET="${DEVRAIL_QUIET:-0}"
readonly DEVRAIL_DEBUG="${DEVRAIL_DEBUG:-0}"

# --- Internal helpers ---

# _log_get_script_name returns the basename of the calling script
_log_get_script_name() {
  local caller_script="${BASH_SOURCE[-1]:-unknown}"
  basename "${caller_script}"
}

# _log_get_timestamp returns the current time in ISO 8601 format
_log_get_timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# _log_json outputs a JSON log entry to stderr
# Arguments: level, message, [exit_code]
_log_json() {
  local level="$1"
  local msg="$2"
  local exit_code="${3:-}"
  local script_name
  script_name="$(_log_get_script_name)"
  local ts
  ts="$(_log_get_timestamp)"

  local json_entry
  if [[ -n "${exit_code}" ]]; then
    json_entry=$(printf '{"level":"%s","msg":"%s","script":"%s","ts":"%s","exit_code":%s}' \
      "${level}" \
      "$(printf '%s' "${msg}" | sed 's/\\/\\\\/g; s/"/\\"/g')" \
      "${script_name}" \
      "${ts}" \
      "${exit_code}")
  else
    json_entry=$(printf '{"level":"%s","msg":"%s","script":"%s","ts":"%s"}' \
      "${level}" \
      "$(printf '%s' "${msg}" | sed 's/\\/\\\\/g; s/"/\\"/g')" \
      "${script_name}" \
      "${ts}")
  fi

  printf '%s\n' "${json_entry}" >&2
}

# _log_human outputs a human-readable log entry to stderr
# Arguments: level, message
_log_human() {
  local level="$1"
  local msg="$2"
  local prefix

  case "${level}" in
  info) prefix="[INFO]  " ;;
  warn) prefix="[WARN]  " ;;
  error) prefix="[ERROR] " ;;
  debug) prefix="[DEBUG] " ;;
  *) prefix="[${level^^}] " ;;
  esac

  printf '%s%s\n' "${prefix}" "${msg}" >&2
}

# _log dispatches to the appropriate format handler
# Arguments: level, message, [exit_code]
_log() {
  local level="$1"
  local msg="$2"
  local exit_code="${3:-}"

  case "${DEVRAIL_LOG_FORMAT}" in
  human)
    _log_human "${level}" "${msg}"
    ;;
  *)
    _log_json "${level}" "${msg}" "${exit_code}"
    ;;
  esac
}

# --- Public logging functions ---

# log_info logs an info-level message (suppressed by DEVRAIL_QUIET=1)
log_info() {
  local msg="${1:?log_info requires a message}"
  if [[ "${DEVRAIL_QUIET}" != "1" ]]; then
    _log "info" "${msg}"
  fi
}

# log_warn logs a warning-level message (always shown)
log_warn() {
  local msg="${1:?log_warn requires a message}"
  _log "warn" "${msg}"
}

# log_error logs an error-level message (always shown)
log_error() {
  local msg="${1:?log_error requires a message}"
  local exit_code="${2:-}"
  _log "error" "${msg}" "${exit_code}"
}

# log_debug logs a debug-level message (only when DEVRAIL_DEBUG=1)
log_debug() {
  local msg="${1:?log_debug requires a message}"
  if [[ "${DEVRAIL_DEBUG}" == "1" ]]; then
    _log "debug" "${msg}"
  fi
}

# die logs an error message and exits with code 1
die() {
  local msg="${1:?die requires a message}"
  local exit_code="${2:-1}"
  log_error "${msg}" "${exit_code}"
  exit "${exit_code}"
}

# --- Validation helpers ---

# is_empty returns 0 if the argument is empty or unset
is_empty() {
  [[ -z "${1:-}" ]]
}

# is_not_empty returns 0 if the argument has a value
is_not_empty() {
  [[ -n "${1:-}" ]]
}

# is_set returns 0 if the named variable is declared
# Usage: is_set "MY_VAR"
is_set() {
  local var_name="${1:?is_set requires a variable name}"
  declare -p "${var_name}" &>/dev/null
}

# require_cmd exits with code 2 if the specified command is not found
# Arguments: command_name, [error_message]
require_cmd() {
  local cmd="${1:?require_cmd requires a command name}"
  local msg="${2:-Required command not found: ${cmd}}"
  if ! command -v "${cmd}" &>/dev/null; then
    log_error "${msg}" "2"
    exit 2
  fi
}
