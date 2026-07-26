#!/usr/bin/env bash
# lib/dependency-install.sh — Dependency installation before `make test` (Story 15.2)
#
# Purpose: Autodetect and install a project's own dependencies before
#          pytest/vitest run, so tests don't fail at import time with
#          ModuleNotFoundError / unresolved-import errors. Closes issue #52.
#
# Usage:   source "${DEVRAIL_LIB}/dependency-install.sh"
#          install_project_deps python "$root" || overall_exit=1
#          run_project_setup "$root" || overall_exit=1
#
# Contract:
#   - install_project_deps <language> <root>: installs dependencies for
#     <language> in project root <root> (a path relative to the repo root
#     the caller is already cwd'd in — the function cd's into it itself).
#     Returns the real exit code of the install command. 0 means either
#     success or "nothing to install" (no lockfile/manifest found) — never
#     swallows a real failure.
#   - `.devrail.yml` `test.install` (a shell command string) overrides
#     autodetection entirely when present — language-agnostic, applies to
#     every root of every declared language.
#   - Autodetection (only when no `test.install` override):
#       python:     uv.lock present           -> `uv sync --frozen`
#                   requirements*.txt present  -> `pip install -r <file>`
#                                                 (sorted, first match)
#                   pyproject.toml/setup.py    -> `pip install -e .`
#                   none of the above          -> no-op
#       javascript: package-lock.json present  -> `npm ci`
#                   none                       -> no-op
#     Only uv/pip/npm are supported — poetry/pipenv/pnpm/yarn are not
#     installed in the container (Story 15.3+ follow-up); their lockfiles
#     are intentionally NOT detected here (see Dev Notes in Story 15.2).
#   - run_project_setup <root>: runs `.devrail.yml` `test.setup` (a shell
#     command string) if present, after a successful install. No-op (0) if
#     absent. Also language-agnostic.
#
# Dependencies: lib/log.sh (log_event), yq (v4+), bash 5+, uv, pip, npm

# Guard against double-sourcing
# shellcheck disable=SC2317
if [[ -n "${_DEVRAIL_DEPENDENCY_INSTALL_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
readonly _DEVRAIL_DEPENDENCY_INSTALL_LOADED=1

# Resolved to an ABSOLUTE path at source time (before any caller `cd`s into
# a project root) — install_project_deps/run_project_setup both cd around
# per-root, and .devrail.yml always lives at the repo root regardless of
# which project root is currently active.
_DEPENDENCY_INSTALL_CONFIG="$(pwd)/${DEVRAIL_CONFIG:-.devrail.yml}"

# _dependency_install_config_value <yq-path> emits the string value at the
# given yq path in .devrail.yml, or empty if missing/absent/unreadable.
_dependency_install_config_value() {
  local yq_path="$1"
  [[ -r "${_DEPENDENCY_INSTALL_CONFIG}" ]] || return 0
  yq -r "${yq_path} // \"\"" "${_DEPENDENCY_INSTALL_CONFIG}" 2>/dev/null
}

# _dependency_install_autodetect_python emits the install command to run
# from within the current directory (assumed to already be the project
# root), or emits nothing when there's no recognized manifest/lockfile.
#
# Installs land in the container's SYSTEM Python site-packages, not an
# isolated venv — this container's model is "tools are installed once,
# globally" (pytest et al. already live in system site-packages), so a
# project dependency has to land there too or the globally-installed
# `pytest` binary (invoked bare, not via any project-local wrapper) will
# never see it. Concretely this means NOT `uv sync` (which creates and
# populates an isolated `.venv/` that bare `pytest` cannot see at all —
# confirmed by hand during Story 15.2 implementation: `uv sync --frozen`
# followed by bare `pytest` still raised ModuleNotFoundError). Instead,
# `uv export` converts the lockfile to a requirements list and `uv pip
# install --system` installs it system-wide, mirroring how the
# requirements.txt/pyproject.toml paths already work below. Both `uv` and
# `pip` need `--break-system-packages` on this container's Debian/PEP 668
# "externally managed" Python — same flag `scripts/install-python.sh`
# already uses to install the tools themselves.
_dependency_install_autodetect_python() {
  if [[ -f "uv.lock" ]]; then
    printf 'uv export --frozen --no-hashes --format requirements-txt | uv pip install --system --break-system-packages -r -'
  elif compgen -G "requirements*.txt" >/dev/null 2>&1; then
    local req_file
    req_file="$(compgen -G "requirements*.txt" | sort | head -1)"
    printf 'pip install --break-system-packages -r %q' "${req_file}"
  elif [[ -f "pyproject.toml" || -f "setup.py" ]]; then
    printf 'pip install --break-system-packages -e .'
  fi
}

# _dependency_install_autodetect_javascript emits the install command, or
# nothing when there's no package-lock.json.
_dependency_install_autodetect_javascript() {
  if [[ -f "package-lock.json" ]]; then
    printf 'npm ci'
  fi
}

# install_project_deps <language> <root> installs dependencies for the
# given language in the given project root. Returns the install command's
# real exit code; 0 (no-op) when there's nothing to install.
install_project_deps() {
  local language="${1:?install_project_deps requires a language}"
  local root="${2:?install_project_deps requires a root}"

  local override
  override="$(_dependency_install_config_value '.test.install')"

  local cmd
  if [[ -n "${override}" ]]; then
    cmd="${override}"
  else
    case "${language}" in
    python) cmd="$(cd "${root}" && _dependency_install_autodetect_python)" ;;
    javascript) cmd="$(cd "${root}" && _dependency_install_autodetect_javascript)" ;;
    *) cmd="" ;;
    esac
  fi

  if [[ -z "${cmd}" ]]; then
    return 0
  fi

  log_event info "installing project dependencies" language="${language}" root="${root}" cmd="${cmd}"
  # Capture the real exit code inside an explicit `else` — falling through
  # past a bare `if ...; then return 0; fi` looks equivalent but is NOT:
  # per POSIX, an `if` with no `else` branch taken exits 0 regardless of
  # the condition's own status, so `$?` read after `fi` is always 0, not
  # the failed command's code. Confirmed by hand during Story 15.2
  # implementation — the original bare-`fi` version silently returned 0
  # on every install failure, so `make test` ran pytest against a broken
  # install instead of failing fast (AC 8).
  if (cd "${root}" && bash -c "${cmd}"); then
    return 0
  else
    local rc=$?
    log_event error "dependency install failed" language="${language}" root="${root}" cmd="${cmd}"
    return "${rc}"
  fi
}

# run_project_setup <root> runs .devrail.yml `test.setup` (if configured)
# in the given root. No-op (0) if absent.
run_project_setup() {
  local root="${1:?run_project_setup requires a root}"

  local setup_cmd
  setup_cmd="$(_dependency_install_config_value '.test.setup')"

  if [[ -z "${setup_cmd}" ]]; then
    return 0
  fi

  log_event info "running test setup" root="${root}" cmd="${setup_cmd}"
  if (cd "${root}" && bash -c "${setup_cmd}"); then
    return 0
  else
    local rc=$?
    log_event error "test setup failed" root="${root}" cmd="${setup_cmd}"
    return "${rc}"
  fi
}
