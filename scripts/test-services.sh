#!/usr/bin/env bash
# scripts/test-services.sh — Ephemeral Postgres/Redis containers for `make test` (Story 15.4, HOST script)
#
# Purpose: Orchestrates throwaway service containers for integration tests
#          declared via `.devrail.yml` `test.services`. Runs on the HOST
#          (needs `docker network`/`docker run` access) — the toolchain
#          container itself has no Docker CLI or `/var/run/docker.sock`
#          mount, deliberately, so this story does not grant it one (that
#          would be a real privilege-escalation surface the feature does
#          not need).
#
# Usage:   bash scripts/test-services.sh up      # called by _test-services-up
#          bash scripts/test-services.sh down    # called by test:'s cleanup trap
#
# Contract:
#   - `up` reads `.devrail.yml` `test.services` (list of `postgres:<tag>` /
#     `redis:<tag>` strings). Empty/absent -> no-op, exit 0.
#   - Validates the FULL list before starting anything — any unsupported
#     entry exits 2 with nothing started (fail fast, not partial-then-fail).
#   - Refuses to run if `docker_network` is ALSO set in `.devrail.yml`
#     (exit 2) — only one `--network` flag reaches `docker run`, so the two
#     are mutually exclusive for the `test` target.
#   - Cleans up any stale state left by an incomplete prior run (a
#     SIGKILL'd `make test` can't be caught by a shell trap) before
#     starting fresh.
#   - Writes state under `.devrail/test-services/`: `network` (name),
#     `containers` (one name per line), `env` (KEY=VALUE lines, consumed
#     via `docker run --env-file`).
#   - `down` tears down every tracked container and the tracked network,
#     then removes the state dir. No-op if the state dir doesn't exist.
#
# Supported services: `postgres:<tag>` (injects DATABASE_URL), `redis:<tag>`
# (injects REDIS_URL). Anything else is a hard error — no silent partial
# support for a service this script doesn't know how to configure or
# generate a connection string for. `docker-compose.test.yml`
# autodetection is explicitly out of scope (Story 15.4 AC 9).
#
# Environment:
#   DEVRAIL_CONFIG      path to .devrail.yml (default: .devrail.yml)
#   DEVRAIL_LOG_FORMAT  json (default) or human
#
# Dependencies: lib/log.sh, yq (v4+), docker, bash 5+

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVRAIL_LIB="${DEVRAIL_LIB:-${SCRIPT_DIR}/../lib}"
# shellcheck source=../lib/log.sh
source "${DEVRAIL_LIB}/log.sh"

DEVRAIL_CONFIG="${DEVRAIL_CONFIG:-.devrail.yml}"
readonly STATE_DIR=".devrail/test-services"
readonly READY_TIMEOUT_SECONDS=30

# --- Help ---
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  log_info "test-services.sh — Ephemeral Postgres/Redis containers for make test"
  log_info "Usage: bash scripts/test-services.sh <up|down>"
  exit 0
fi

subcommand="${1:?Usage: bash scripts/test-services.sh <up|down>}"

# _service_kind <image-ref> emits "postgres"/"redis"/"" (empty = unsupported).
_service_kind() {
  case "$1" in
  postgres:*) echo "postgres" ;;
  redis:*) echo "redis" ;;
  *) echo "" ;;
  esac
}

# _wait_ready <kind> <container> polls the service's own readiness check
# (not just "the TCP port is open") up to READY_TIMEOUT_SECONDS.
_wait_ready() {
  local kind="$1" container="$2"
  local elapsed=0
  while ((elapsed < READY_TIMEOUT_SECONDS)); do
    case "${kind}" in
    postgres)
      if docker exec "${container}" pg_isready -U postgres >/dev/null 2>&1; then
        return 0
      fi
      ;;
    redis)
      if [[ "$(docker exec "${container}" redis-cli ping 2>/dev/null)" == "PONG" ]]; then
        return 0
      fi
      ;;
    esac
    sleep 1
    elapsed=$((elapsed + 1))
  done
  return 1
}

# _down tears down every tracked container and the tracked network, then
# removes the state dir. No-op if there's nothing to tear down. Individual
# removal failures are logged and skipped, not fatal — a container that's
# already gone (or a network with a lingering endpoint from a container
# docker itself hasn't reaped yet) shouldn't block cleaning up the rest.
_down() {
  if [[ ! -d "${STATE_DIR}" ]]; then
    return 0
  fi

  if [[ -f "${STATE_DIR}/containers" ]]; then
    local container
    while IFS= read -r container; do
      [[ -z "${container}" ]] && continue
      if ! docker rm -f "${container}" >/dev/null 2>&1; then
        log_warn "could not remove container '${container}' (already gone?)"
      fi
    done <"${STATE_DIR}/containers"
  fi

  if [[ -f "${STATE_DIR}/network" ]]; then
    local network
    network="$(cat "${STATE_DIR}/network")"
    if ! docker network rm "${network}" >/dev/null 2>&1; then
      log_warn "could not remove network '${network}' (already gone?)"
    fi
  fi

  rm -rf "${STATE_DIR}"
  log_event info "test services torn down"
}

# _up starts every declared test.services entry. See file header for the
# full contract (fail-fast validation, mutual exclusion with
# docker_network, stale-state cleanup).
_up() {
  local services
  services="$(yq -r '.test.services // [] | .[]' "${DEVRAIL_CONFIG}" 2>/dev/null)"

  if [[ -z "${services}" ]]; then
    return 0
  fi

  if [[ -d "${STATE_DIR}" ]]; then
    log_warn "found leftover test-services state from a prior run — cleaning up before starting fresh"
    _down
  fi

  local devrail_network
  devrail_network="$(yq -r '.docker_network // ""' "${DEVRAIL_CONFIG}" 2>/dev/null)"
  if [[ -n "${devrail_network}" ]]; then
    log_error "test.services and docker_network cannot both be set — the test target can only pass one --network flag to docker run. Remove one of them." 2
    exit 2
  fi

  # Validate the full list before starting anything: every entry must be a
  # supported kind, and no kind may repeat. A repeat would silently shadow
  # itself — DATABASE_URL/REDIS_URL is one env var per kind, so a second
  # postgres entry's connection string would overwrite the first's in the
  # env file (last line wins), leaving the first container running but
  # unreachable via the injected env var for the rest of the test run.
  local service kind seen_kinds=""
  while IFS= read -r service; do
    [[ -z "${service}" ]] && continue
    kind="$(_service_kind "${service}")"
    if [[ -z "${kind}" ]]; then
      log_error "unsupported test.services entry '${service}' — only postgres:<tag> and redis:<tag> are supported" 2
      exit 2
    fi
    if [[ " ${seen_kinds} " == *" ${kind} "* ]]; then
      log_error "duplicate test.services entry for '${kind}' — only one ${kind}:<tag> entry is supported at a time" 2
      exit 2
    fi
    seen_kinds="${seen_kinds} ${kind}"
  done <<<"${services}"

  mkdir -p "${STATE_DIR}"
  local suffix network
  suffix="$(date +%s)-$$"
  network="devrail-test-${suffix}"
  docker network create "${network}" >/dev/null
  echo "${network}" >"${STATE_DIR}/network"
  log_event info "created ephemeral test-services network" network="${network}"

  : >"${STATE_DIR}/env"
  : >"${STATE_DIR}/containers"

  local index=0 container
  while IFS= read -r service; do
    [[ -z "${service}" ]] && continue
    kind="$(_service_kind "${service}")"
    index=$((index + 1))
    container="devrail-test-${kind}-${suffix}-${index}"

    case "${kind}" in
    postgres)
      docker run -d --network "${network}" --name "${container}" \
        -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=devrail -e POSTGRES_DB=devrail_test \
        "${service}" >/dev/null
      ;;
    redis)
      docker run -d --network "${network}" --name "${container}" "${service}" >/dev/null
      ;;
    esac
    echo "${container}" >>"${STATE_DIR}/containers"
    log_event info "starting test service" service="${service}" container="${container}"

    if ! _wait_ready "${kind}" "${container}"; then
      log_error "test service '${service}' (${container}) did not become ready within ${READY_TIMEOUT_SECONDS}s" 2
      _down
      exit 2
    fi
    log_event info "test service ready" service="${service}" container="${container}"

    case "${kind}" in
    postgres)
      echo "DATABASE_URL=postgresql://postgres:devrail@${container}:5432/devrail_test" >>"${STATE_DIR}/env"
      ;;
    redis)
      echo "REDIS_URL=redis://${container}:6379" >>"${STATE_DIR}/env"
      ;;
    esac
  done <<<"${services}"
}

case "${subcommand}" in
up) _up ;;
down) _down ;;
*)
  log_error "unknown subcommand '${subcommand}' — expected 'up' or 'down'" 2
  exit 2
  ;;
esac
