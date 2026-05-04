#!/usr/bin/env bash
# scripts/plugin-extended-image.sh — Build the project-local extended image (HOST script)
#
# Purpose: Orchestrates the extended-image build pipeline (Story 13.4b).
#          Runs on the HOST (needs `docker build` access). Steps:
#            1. Stage install scripts from the host plugin cache into a
#               build-context staging dir (.devrail-plugins-build/).
#            2. Run `make _generate-dockerfile` inside a container to emit
#               Dockerfile.devrail (which depends on _plugins-load to populate
#               the in-container loader cache at /tmp/devrail-plugins-loaded.yaml).
#            3. Compute SHA256 of Dockerfile.devrail; tag = devrail-local:<first-16-hex>.
#            4. If `docker image inspect <tag>` succeeds → cache hit, no build.
#            5. Otherwise `docker build` and write tag to .devrail/extended-image-tag.
#            6. Clean up .devrail-plugins-build/ regardless of outcome.
#
# Usage:   bash scripts/plugin-extended-image.sh [--help]
#          Exit 0 — image ready (built or cache-hit) OR no plugins (no-op)
#          Exit 2 — build failure
#
# Environment:
#   DEVRAIL_IMAGE             core image name (default: ghcr.io/devrail-dev/dev-toolchain)
#   DEVRAIL_TAG               core image tag  (default: local)
#   DEVRAIL_HOST_PLUGINS_CACHE host plugin cache (default: ${HOME}/.cache/devrail/plugins)
#   DEVRAIL_VERSION           image version override (passed to in-container resolver)
#   DEVRAIL_LOG_FORMAT        json (default) or human

set -euo pipefail
LC_ALL=C
export LC_ALL

# --- Resolve library path (host-side bash, lib lives next to this script) ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVRAIL_LIB="${DEVRAIL_LIB:-${SCRIPT_DIR}/../lib}"

# shellcheck source=../lib/log.sh
source "${DEVRAIL_LIB}/log.sh"

# --- Help ---
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  log_info "plugin-extended-image.sh — Build devrail-local:<hash> from declared plugins"
  log_info "Usage: bash scripts/plugin-extended-image.sh"
  log_info "Exit 0 — image ready or no plugins; 2 — build failure"
  exit 0
fi

# --- Args / env ---
WORKSPACE="$(pwd)"
DEVRAIL_IMAGE="${DEVRAIL_IMAGE:-ghcr.io/devrail-dev/dev-toolchain}"
DEVRAIL_TAG="${DEVRAIL_TAG:-local}"
HOST_CACHE="${DEVRAIL_HOST_PLUGINS_CACHE:-${HOME}/.cache/devrail/plugins}"
DEVRAIL_YML="${WORKSPACE}/.devrail.yml"
STAGING_DIR="${WORKSPACE}/.devrail-plugins-build"
TAG_FILE_DIR="${WORKSPACE}/.devrail"
TAG_FILE="${TAG_FILE_DIR}/extended-image-tag"
DOCKERFILE="${WORKSPACE}/Dockerfile.devrail"

# Cleanup the staging dir on every exit path (success or failure).
# shellcheck disable=SC2317  # invoked via trap, not direct call
cleanup_staging() {
  if [[ -d "${STAGING_DIR}" ]]; then
    rm -rf "${STAGING_DIR}"
  fi
}
trap cleanup_staging EXIT

require_cmd "docker" "docker is required (Docker Desktop or podman with docker shim)"
require_cmd "yq" "yq is required (v4+) on the host for plugin discovery"
require_cmd "sha256sum" "sha256sum is required (coreutils)"

# --- Probe: any plugins declared at all? ---
if [[ ! -r "${DEVRAIL_YML}" ]]; then
  log_event info "no .devrail.yml; skipping extended-image build" language=_plugins
  exit 0
fi

plugin_count="$(yq -r '.plugins // [] | length' "${DEVRAIL_YML}" 2>/dev/null || echo 0)"
if [[ "${plugin_count}" == "0" ]]; then
  # No plugins declared — clean any stale tag file but don't build.
  if [[ -f "${TAG_FILE}" ]]; then
    rm -f "${TAG_FILE}"
  fi
  log_event info "no plugins declared; using core image" language=_plugins
  exit 0
fi

# --- Stage install scripts from host cache into the build context ---
# The generator emits `COPY .devrail-plugins-build/<slug>/<rev>/<install_script> ...`.
# Copy each plugin's install script (and only that — not the whole tree) into
# the staging dir so the docker build context stays tiny.
mkdir -p "${STAGING_DIR}"
for i in $(seq 0 $((plugin_count - 1))); do
  source_url="$(yq -r ".plugins[${i}].source // \"\"" "${DEVRAIL_YML}")"
  rev="$(yq -r ".plugins[${i}].rev // \"\"" "${DEVRAIL_YML}")"
  if [[ -z "${source_url}" || -z "${rev}" ]]; then
    continue
  fi
  slug="$(basename "${source_url}")"
  slug="${slug%.git}"
  manifest="${HOST_CACHE}/${slug}/${rev}/plugin.devrail.yml"
  if [[ ! -r "${manifest}" ]]; then
    log_event error "plugin manifest not found in host cache" \
      slug="${slug}" rev="${rev}" path="${manifest}" \
      reason="run \`make plugins-update\` first" \
      language=_plugins
    exit 2
  fi
  install_script_rel="$(yq -r '.container.install_script // ""' "${manifest}")"
  if [[ -n "${install_script_rel}" && "${install_script_rel}" != "null" ]]; then
    src="${HOST_CACHE}/${slug}/${rev}/${install_script_rel}"
    if [[ ! -r "${src}" ]]; then
      log_event error "plugin install_script not found in host cache" \
        slug="${slug}" rev="${rev}" path="${src}" \
        language=_plugins
      exit 2
    fi
    dst="${STAGING_DIR}/${slug}/${rev}/${install_script_rel}"
    mkdir -p "$(dirname "${dst}")"
    cp -p "${src}" "${dst}"
  fi
done

# --- Run the in-container generator (which depends on _plugins-load) ---
docker_args=(
  --rm
  -v "${WORKSPACE}:/workspace"
  -v "${HOST_CACHE}:/opt/devrail/plugins"
  -w /workspace
)
if [[ -n "${DEVRAIL_VERSION:-}" ]]; then
  docker_args+=(-e "DEVRAIL_VERSION=${DEVRAIL_VERSION}")
fi
if [[ -n "${DEVRAIL_LOG_FORMAT:-}" ]]; then
  docker_args+=(-e "DEVRAIL_LOG_FORMAT=${DEVRAIL_LOG_FORMAT}")
fi

if ! docker run "${docker_args[@]}" "${DEVRAIL_IMAGE}:${DEVRAIL_TAG}" \
  make _generate-dockerfile >&2; then
  log_event error "Dockerfile.devrail generation failed" language=_plugins
  exit 2
fi

if [[ ! -r "${DOCKERFILE}" ]]; then
  log_event error "generator returned 0 but Dockerfile.devrail not present" \
    path="${DOCKERFILE}" language=_plugins
  exit 2
fi

# --- Compute tag from Dockerfile.devrail content ---
content_hash="$(sha256sum "${DOCKERFILE}" | cut -d' ' -f1 | head -c 16)"
extended_tag="devrail-local:${content_hash}"

# --- Cache hit? ---
build_start="$(date +%s%3N)"
if docker image inspect "${extended_tag}" >/dev/null 2>&1; then
  build_end="$(date +%s%3N)"
  duration=$((build_end - build_start))
  log_event info "extended image cache hit" \
    tag="${extended_tag}" \
    duration_ms:="${duration}" \
    language=_plugins
else
  # Cache miss — build.
  log_event info "building extended image" tag="${extended_tag}" language=_plugins
  build_log="$(mktemp)"
  if ! DOCKER_BUILDKIT=1 docker build \
    -t "${extended_tag}" \
    -f "${DOCKERFILE}" \
    "${WORKSPACE}" >"${build_log}" 2>&1; then
    build_end="$(date +%s%3N)"
    duration=$((build_end - build_start))
    stderr_tail="$(tail -20 "${build_log}" | tr -d '\r' | sed 's/\\/\\\\/g; s/"/\\"/g; s/$/\\n/' | tr -d '\n')"
    log_event error "extended image build failed" \
      tag="${extended_tag}" \
      duration_ms:="${duration}" \
      stderr_tail="${stderr_tail}" \
      language=_plugins
    rm -f "${build_log}"
    exit 2
  fi
  rm -f "${build_log}"
  build_end="$(date +%s%3N)"
  duration=$((build_end - build_start))
  log_event info "extended image built" \
    tag="${extended_tag}" \
    duration_ms:="${duration}" \
    language=_plugins
fi

# --- Persist tag for DOCKER_RUN swap-in ---
mkdir -p "${TAG_FILE_DIR}"
printf '%s\n' "${extended_tag}" >"${TAG_FILE}"

exit 0
