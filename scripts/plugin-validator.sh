#!/usr/bin/env bash
# scripts/plugin-validator.sh — Validate a DevRail plugin manifest
#
# Purpose: Parses a `plugin.devrail.yml` manifest with yq and validates it
#          against the v1 plugin manifest schema (Story 13.2). Emits structured
#          JSON error events for each violation. Reports ALL violations
#          cumulatively (does NOT fail-fast on the first one).
#
# Usage:   bash scripts/plugin-validator.sh <manifest-path> [--help]
#          Exit 0 — manifest is valid against schema_version: 1
#          Exit 2 — one or more schema violations (misconfiguration)
#          Exit 3 — manifest file not found / unreadable
#
# Dependencies: yq (v4+, in /usr/local/bin/yq), lib/log.sh, lib/platform.sh

set -euo pipefail

# --- Resolve library path ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVRAIL_LIB="${DEVRAIL_LIB:-${SCRIPT_DIR}/../lib}"

# shellcheck source=../lib/log.sh
source "${DEVRAIL_LIB}/log.sh"
# shellcheck source=../lib/platform.sh
source "${DEVRAIL_LIB}/platform.sh"
# shellcheck source=../lib/version.sh
source "${DEVRAIL_LIB}/version.sh"

# --- Help ---
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  log_info "plugin-validator.sh — Validate a DevRail plugin manifest"
  log_info "Usage: bash scripts/plugin-validator.sh <manifest-path>"
  log_info "Exit 0 — valid; 2 — schema violation; 3 — file not found"
  exit 0
fi

# --- Args ---
MANIFEST="${1:-}"
if [[ -z "${MANIFEST}" ]]; then
  log_error "manifest path argument required" "2"
  log_error "usage: bash scripts/plugin-validator.sh <manifest-path>" "2"
  exit 2
fi

if [[ ! -r "${MANIFEST}" ]]; then
  log_error "manifest not found or unreadable: ${MANIFEST}" "3"
  exit 3
fi

require_cmd "yq" "yq is required (apt install yq, or use the dev-toolchain image)"

# --- Constants ---
readonly EXPECTED_SCHEMA_VERSION=1
readonly NAME_REGEX='^[a-z][a-z0-9_-]*$'
readonly SEMVER_REGEX='^[0-9]+\.[0-9]+\.[0-9]+$'
readonly VALID_TARGETS=(lint format_check format_fix fix test security)

# --- State ---
VIOLATIONS=0
PLUGIN_NAME="unknown"

# emit_violation outputs a structured JSON event for one schema violation.
# Arguments: field, reason
emit_violation() {
  local field="$1"
  local reason="$2"
  local ts
  ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  printf '{"level":"error","msg":"plugin schema violation","plugin":"%s","field":"%s","reason":"%s","language":"_plugins","script":"plugin-validator.sh","ts":"%s"}\n' \
    "${PLUGIN_NAME}" "${field}" "${reason}" "${ts}" >&2
  VIOLATIONS=$((VIOLATIONS + 1))
}

# emit_info outputs a structured JSON event with `language: "_plugins"`.
# Arguments: msg, [extra-key=value pairs as a single string]
emit_info() {
  local msg="$1"
  local extra="${2:-}"
  local ts
  ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  if [[ -n "${extra}" ]]; then
    printf '{"level":"info","msg":"%s","plugin":"%s","language":"_plugins","script":"plugin-validator.sh","ts":"%s",%s}\n' \
      "${msg}" "${PLUGIN_NAME}" "${ts}" "${extra}" >&2
  else
    printf '{"level":"info","msg":"%s","plugin":"%s","language":"_plugins","script":"plugin-validator.sh","ts":"%s"}\n' \
      "${msg}" "${PLUGIN_NAME}" "${ts}" >&2
  fi
}

# yq_field reads a scalar field; prints empty string when missing.
yq_field() {
  local field="$1"
  yq -r ".${field} // \"\"" "${MANIFEST}" 2>/dev/null
}

# yq_type reports the !!type of a field; prints "missing" when absent.
yq_type() {
  local field="$1"
  local result
  result=$(yq -r ".${field} | type" "${MANIFEST}" 2>/dev/null || true)
  if [[ -z "${result}" || "${result}" == "null" || "${result}" == "!!null" ]]; then
    printf "missing"
  else
    printf "%s" "${result}"
  fi
}

# --- Best-effort plugin name extraction (used in error events) ---
_name_value="$(yq_field "name")"
if [[ -n "${_name_value}" ]]; then
  PLUGIN_NAME="${_name_value}"
fi

emit_info "validating manifest" "\"path\":\"${MANIFEST}\""

# --- Validate schema_version ---
sv_type="$(yq_type "schema_version")"
if [[ "${sv_type}" == "missing" ]]; then
  emit_violation "schema_version" "required field is missing"
elif [[ "${sv_type}" != "!!int" ]]; then
  emit_violation "schema_version" "must be an integer; got ${sv_type}"
else
  sv_value="$(yq -r '.schema_version' "${MANIFEST}")"
  if [[ "${sv_value}" != "${EXPECTED_SCHEMA_VERSION}" ]]; then
    emit_violation "schema_version" "unsupported version ${sv_value}; this loader supports schema_version: ${EXPECTED_SCHEMA_VERSION}"
  fi
fi

# --- Validate name ---
name_type="$(yq_type "name")"
if [[ "${name_type}" == "missing" ]]; then
  emit_violation "name" "required field is missing"
elif [[ "${name_type}" != "!!str" ]]; then
  emit_violation "name" "must be a string; got ${name_type}"
else
  name_value="$(yq -r '.name' "${MANIFEST}")"
  if [[ ! "${name_value}" =~ ${NAME_REGEX} ]]; then
    emit_violation "name" "value '${name_value}' does not match ${NAME_REGEX}"
  fi
fi

# --- Validate version ---
version_type="$(yq_type "version")"
if [[ "${version_type}" == "missing" ]]; then
  emit_violation "version" "required field is missing"
elif [[ "${version_type}" != "!!str" ]]; then
  emit_violation "version" "must be a string; got ${version_type}"
else
  version_value="$(yq -r '.version' "${MANIFEST}")"
  if [[ ! "${version_value}" =~ ${SEMVER_REGEX} ]]; then
    emit_violation "version" "value '${version_value}' is not a dotted-numeric semver (expected MAJOR.MINOR.PATCH)"
  fi
fi

# --- Validate devrail_min_version ---
mv_type="$(yq_type "devrail_min_version")"
if [[ "${mv_type}" == "missing" ]]; then
  emit_violation "devrail_min_version" "required field is missing"
elif [[ "${mv_type}" != "!!str" ]]; then
  emit_violation "devrail_min_version" "must be a string; got ${mv_type}"
else
  mv_value="$(yq -r '.devrail_min_version' "${MANIFEST}")"
  if [[ ! "${mv_value}" =~ ${SEMVER_REGEX} ]]; then
    emit_violation "devrail_min_version" "value '${mv_value}' is not a dotted-numeric semver (expected MAJOR.MINOR.PATCH)"
  else
    image_version="$(get_devrail_version)"
    if ! version_gte "${image_version}" "${mv_value}"; then
      emit_violation "devrail_min_version" "manifest requires ${mv_value} but this image is ${image_version}"
    fi
  fi
fi

# --- Validate targets ---
targets_type="$(yq_type "targets")"
if [[ "${targets_type}" == "missing" ]]; then
  emit_violation "targets" "required field is missing"
elif [[ "${targets_type}" != "!!map" ]]; then
  emit_violation "targets" "must be a mapping; got ${targets_type}"
else
  declared_targets="$(yq -r '.targets | keys | .[]' "${MANIFEST}" 2>/dev/null || true)"
  if [[ -z "${declared_targets}" ]]; then
    emit_violation "targets" "must declare at least one of: ${VALID_TARGETS[*]}"
  else
    found_valid=0
    while IFS= read -r target_name; do
      [[ -z "${target_name}" ]] && continue
      is_valid=0
      for valid in "${VALID_TARGETS[@]}"; do
        if [[ "${target_name}" == "${valid}" ]]; then
          is_valid=1
          found_valid=1
          break
        fi
      done
      if [[ "${is_valid}" -eq 0 ]]; then
        emit_violation "targets.${target_name}" "unknown target '${target_name}' (valid: ${VALID_TARGETS[*]})"
      else
        # Each declared (valid) target needs a `cmd` string
        cmd_type="$(yq_type "targets.${target_name}.cmd")"
        if [[ "${cmd_type}" == "missing" ]]; then
          emit_violation "targets.${target_name}.cmd" "required field is missing"
        elif [[ "${cmd_type}" != "!!str" ]]; then
          emit_violation "targets.${target_name}.cmd" "must be a string; got ${cmd_type}"
        fi
      fi
    done <<<"${declared_targets}"
    if [[ "${found_valid}" -eq 0 ]]; then
      emit_violation "targets" "must declare at least one of: ${VALID_TARGETS[*]}"
    fi
  fi
fi

# --- Final outcome ---
if [[ "${VIOLATIONS}" -gt 0 ]]; then
  emit_info "manifest validation failed" "\"violations\":${VIOLATIONS}"
  exit 2
fi

emit_info "manifest valid" "\"schema_version\":${EXPECTED_SCHEMA_VERSION}"
exit 0
