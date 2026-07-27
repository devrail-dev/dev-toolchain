#!/usr/bin/env bash
# tests/test-test-services.sh — Validate ephemeral test.services orchestration (Story 15.4)
#
# Verifies, against checked-in fixtures under tests/fixtures/:
#   1. postgres:16 alone — real SQL query through the injected DATABASE_URL
#   2. redis:7 alone — real SET/GET through the injected REDIS_URL
#   3. both together — one shared network, both env vars injected
#   4. no test.services declared — make test is unaffected (regression)
#   5. docker_network + test.services both set — fails fast with a clear
#      mutual-exclusion error, nothing gets started
#   6. an unsupported service entry (mysql:8) — fails fast with a clear
#      error naming it, nothing gets started
#   7. teardown actually happens — checked via `docker ps`/`docker network
#      ls` after each service-starting case, not just by the trap code
#      existing
#   8. a mid-flight SIGKILL leaves orphaned resources (a shell trap cannot
#      intercept SIGKILL), and the *next* `make test` run detects and
#      cleans up that stale state before starting fresh
#
# Unlike tests/test-project-discover.sh / tests/test-dependency-install.sh,
# which run `make _test` (an INTERNAL target) inside a bind-mounted
# container, this script runs the PUBLIC `make test` target directly on
# the HOST shell — `_test-services-up` is host-side orchestration (it
# calls `docker network create`/`docker run` itself), so it must be
# invoked the way a real consumer would invoke it: `cd <project> && make
# test`, not wrapped in another docker run.
#
# Requires Docker-in-Docker capability and network egress to pull
# postgres:16/redis:7 if not already cached — the same requirement
# tests/test-dependency-install.sh already documents for PyPI/npm.
#
# Usage: bash tests/test-test-services.sh
# Env:
#   DEVRAIL_IMAGE  override image name (default: ghcr.io/devrail-dev/dev-toolchain)
#   DEVRAIL_TAG    override image tag  (default: local)

set -euo pipefail

IMAGE_NAME="${DEVRAIL_IMAGE:-ghcr.io/devrail-dev/dev-toolchain}"
IMAGE_TAG="${DEVRAIL_TAG:-local}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="${REPO_ROOT}/tests/fixtures"
WORKDIR="$(mktemp -d)"

cleanup() {
  # Belt-and-braces: remove any test-services resources this run's own
  # fixtures might have left behind (should already be none if teardown
  # worked, but don't leave orphans behind from a script-level failure).
  docker ps -a --filter "name=devrail-test-" --format '{{.Names}}' 2>/dev/null | xargs -r docker rm -f >/dev/null 2>&1 || true
  docker network ls --filter "name=devrail-test-" --format '{{.Name}}' 2>/dev/null | xargs -r -n1 docker network rm >/dev/null 2>&1 || true
  if [ -n "${WORKDIR:-}" ] && [ -d "$WORKDIR" ]; then
    docker run --rm -v "$WORKDIR:/cleanup" "${IMAGE_NAME}:${IMAGE_TAG}" \
      sh -c 'rm -rf /cleanup/* /cleanup/.[!.]* 2>/dev/null || true' >/dev/null 2>&1 || true
    rmdir "$WORKDIR" 2>/dev/null || rm -rf "$WORKDIR" 2>/dev/null || true
  fi
}
trap cleanup EXIT

PASS=0
FAIL=0

assert_eq() {
  local expected="$1" actual="$2" context="$3"
  if [ "$expected" = "$actual" ]; then
    echo "PASS [$context]"
    PASS=$((PASS + 1))
  else
    echo "FAIL [$context]: expected '$expected', got '$actual'" >&2
    FAIL=$((FAIL + 1))
  fi
}

assert_true() {
  local condition="$1" context="$2"
  if [ "$condition" = "true" ]; then
    echo "PASS [$context]"
    PASS=$((PASS + 1))
  else
    echo "FAIL [$context]" >&2
    FAIL=$((FAIL + 1))
  fi
}

# workspace_for FIXTURE [LABEL] -> a fresh disposable copy of the fixture
# + the real Makefile, at a path unique to this call — via `mktemp -d`,
# not a hand-rolled counter. An incrementing global counter was tried
# first and silently didn't work: every call here is invoked as
# `X="$(workspace_for ...)"`, and command substitution always forks a
# subshell in bash, so the counter's increment never escaped back to the
# caller — every call saw the counter at its initial value and collided
# on the same destination name. `cp -R src dest` then nests src *inside*
# dest instead of overlaying it once dest already exists from a prior
# call, corrupting every call after the first (caught by hand: the
# second/third calls' `.devrail.yml` overwrites landed on the right path,
# but leftover root-owned `.pytest_cache`/`__pycache__` from the *first*
# call's `make test` run made the later calls' `rm -rf` of the reused
# path fail with permission errors).
workspace_for() {
  local fixture="$1"
  local label="${2:-${fixture}}"
  local dest
  dest="$(mktemp -d "${WORKDIR}/${label}-XXXXXX")"
  rmdir "$dest" # mktemp -d creates it; cp -R needs it absent to copy INTO it, not nest under it
  cp -R "${FIXTURES}/${fixture}" "$dest"
  cp "${REPO_ROOT}/Makefile" "${dest}/Makefile"
  printf '%s' "$dest"
}

# no_test_services_resources -> "true" if no devrail-test-* container or
# network exists on the host right now.
no_test_services_resources() {
  local containers networks
  containers="$(docker ps -a --filter "name=devrail-test-" --format '{{.Names}}')"
  networks="$(docker network ls --filter "name=devrail-test-" --format '{{.Name}}')"
  if [ -z "$containers" ] && [ -z "$networks" ]; then
    echo "true"
  else
    echo "false"
  fi
}

# run_make_test WORKSPACE LOGFILE -> prints the real exit code of `make
# test` run from WORKSPACE, output captured to LOGFILE. Uses an explicit
# if/else to capture the exit code — under `set -e`, a bare command
# followed by `rc=$?` aborts the script on failure before `rc=$?` ever
# runs (confirmed the hard way while writing this script: the first
# version used exactly that pattern and silently died mid-suite on the
# first non-zero exit, the same class of bug Story 15.2's review caught
# in lib/dependency-install.sh's `local rc=$?` after a bare `if...fi`).
run_make_test() {
  local ws="$1" logfile="$2"
  if (cd "$ws" && DEVRAIL_IMAGE="$IMAGE_NAME" DEVRAIL_TAG="$IMAGE_TAG" make test >"$logfile" 2>&1); then
    echo 0
  else
    echo $?
  fi
}

echo "==> postgres:16 alone — real query through the injected DATABASE_URL"
PG_WS="$(workspace_for test-services-pg-redis)"
cat >"${PG_WS}/.devrail.yml" <<'EOF'
languages:
  - python
test:
  services:
    - postgres:16
EOF
cat >"${PG_WS}/requirements.txt" <<'EOF'
psycopg2-binary==2.9.10
EOF
cat >"${PG_WS}/tests/test_services.py" <<'EOF'
import os
import psycopg2


def test_postgres_is_reachable_and_queryable():
    conn = psycopg2.connect(os.environ["DATABASE_URL"])
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT 1;")
            assert cur.fetchone() == (1,)
    finally:
        conn.close()
EOF
PG_EXIT="$(run_make_test "$PG_WS" "${WORKDIR}/pg.log")"
assert_eq "0" "$PG_EXIT" "postgres-alone/exit-code"
assert_true "$(no_test_services_resources)" "postgres-alone/teardown-clean"

echo "==> redis:7 alone — real SET/GET through the injected REDIS_URL"
REDIS_WS="$(workspace_for test-services-pg-redis)"
cat >"${REDIS_WS}/.devrail.yml" <<'EOF'
languages:
  - python
test:
  services:
    - redis:7
EOF
cat >"${REDIS_WS}/requirements.txt" <<'EOF'
redis==5.2.1
EOF
cat >"${REDIS_WS}/tests/test_services.py" <<'EOF'
import os
import redis


def test_redis_is_reachable_and_usable():
    client = redis.from_url(os.environ["REDIS_URL"])
    client.set("story-15-4", "works")
    assert client.get("story-15-4") == b"works"
EOF
REDIS_EXIT="$(run_make_test "$REDIS_WS" "${WORKDIR}/redis.log")"
assert_eq "0" "$REDIS_EXIT" "redis-alone/exit-code"
assert_true "$(no_test_services_resources)" "redis-alone/teardown-clean"

echo "==> postgres + redis together — one network, both env vars injected"
BOTH_WS="$(workspace_for test-services-pg-redis)"
BOTH_EXIT="$(run_make_test "$BOTH_WS" "${WORKDIR}/both.log")"
assert_eq "0" "$BOTH_EXIT" "both/exit-code"
assert_true "$(no_test_services_resources)" "both/teardown-clean"

echo "==> no test.services declared — make test unaffected (regression)"
NOOP_WS="${WORKDIR}/single-root-python"
cp -R "${FIXTURES}/single-root-python" "$NOOP_WS"
cp "${REPO_ROOT}/Makefile" "${NOOP_WS}/Makefile"
NOOP_EXIT="$(run_make_test "$NOOP_WS" "${WORKDIR}/noop.log")"
assert_eq "0" "$NOOP_EXIT" "no-services/exit-code"
NOOP_OUT="$(cat "${WORKDIR}/noop.log")"
NOOP_SUMMARY=$(printf '%s\n' "$NOOP_OUT" | grep -o '{"target":"test".*}' | tail -1) || true
assert_eq "pass" "$(printf '%s' "$NOOP_SUMMARY" | jq -r '.status')" "no-services/status"
# Note: _test-services-host-bin's extraction step logs unconditionally
# (it fetches the script itself, before the script can even check whether
# services are declared) — that's expected and fine, extraction is cheap
# and cached. What must NOT happen is actual orchestration: no network
# created, no service container started.
if printf '%s\n' "$NOOP_OUT" | grep -qE "created ephemeral test-services network|starting test service"; then
  echo "FAIL [no-services/no-orchestration-attempted]: a service network/container was started when no services were declared" >&2
  FAIL=$((FAIL + 1))
else
  echo "PASS [no-services/no-orchestration-attempted]"
  PASS=$((PASS + 1))
fi

echo "==> docker_network + test.services both set — fails fast, nothing started"
MUTEX_WS="$(workspace_for test-services-mutex)"
MUTEX_EXIT=0
(cd "$MUTEX_WS" && DEVRAIL_IMAGE="$IMAGE_NAME" DEVRAIL_TAG="$IMAGE_TAG" make test >"${WORKDIR}/mutex.log" 2>&1) || MUTEX_EXIT=$?
assert_eq "2" "$MUTEX_EXIT" "mutex/exit-code"
if grep -q "cannot both be set" "${WORKDIR}/mutex.log"; then
  echo "PASS [mutex/clear-error-message]"
  PASS=$((PASS + 1))
else
  echo "FAIL [mutex/clear-error-message]: expected a 'cannot both be set' error" >&2
  FAIL=$((FAIL + 1))
fi
assert_true "$(no_test_services_resources)" "mutex/nothing-started"

echo "==> unsupported service entry (mysql:8) — fails fast, nothing started"
UNSUPPORTED_WS="$(workspace_for test-services-unsupported)"
UNSUPPORTED_EXIT=0
(cd "$UNSUPPORTED_WS" && DEVRAIL_IMAGE="$IMAGE_NAME" DEVRAIL_TAG="$IMAGE_TAG" make test >"${WORKDIR}/unsupported.log" 2>&1) || UNSUPPORTED_EXIT=$?
assert_eq "2" "$UNSUPPORTED_EXIT" "unsupported/exit-code"
if grep -q "unsupported test.services entry 'mysql:8'" "${WORKDIR}/unsupported.log"; then
  echo "PASS [unsupported/clear-error-message]"
  PASS=$((PASS + 1))
else
  echo "FAIL [unsupported/clear-error-message]: expected an error naming 'mysql:8'" >&2
  FAIL=$((FAIL + 1))
fi
assert_true "$(no_test_services_resources)" "unsupported/nothing-started"

echo "==> mid-flight SIGKILL leaves orphaned resources; the next run detects and cleans them up"
KILL_WS="$(workspace_for test-services-pg-redis)"
(cd "$KILL_WS" && DEVRAIL_IMAGE="$IMAGE_NAME" DEVRAIL_TAG="$IMAGE_TAG" make test >"${WORKDIR}/kill1.log" 2>&1) &
KILL_PID=$!
sleep 3
# Kill the backgrounded `make test` process itself, not its process
# group — a non-interactive script doesn't get a separate pgid per
# background job, so a group-kill here would take out this script too
# (confirmed the hard way: the whole test suite died mid-run the first
# time this used `kill -- -$PGID`). Killing just the PID is also the more
# realistic simulation: a docker container already started with `-d` is
# detached and keeps running even after its parent `make`/script process
# is gone, which is exactly the orphan scenario AC 8 needs to reproduce.
kill -9 "$KILL_PID" 2>/dev/null || true
sleep 1
assert_true "$([ "$(no_test_services_resources)" = "false" ] && echo true || echo false)" "sigkill/orphan-actually-left-behind"

KILL_RERUN_EXIT="$(run_make_test "$KILL_WS" "${WORKDIR}/kill2.log")"
assert_eq "0" "$KILL_RERUN_EXIT" "sigkill/rerun-succeeds"
if grep -q "leftover test-services state" "${WORKDIR}/kill2.log"; then
  echo "PASS [sigkill/stale-state-detected-and-cleaned]"
  PASS=$((PASS + 1))
else
  echo "FAIL [sigkill/stale-state-detected-and-cleaned]: expected the rerun to log a leftover-state cleanup" >&2
  FAIL=$((FAIL + 1))
fi
assert_true "$(no_test_services_resources)" "sigkill/final-teardown-clean"

echo ""
echo "==================================="
echo "Results: ${PASS} passed, ${FAIL} failed"
echo "==================================="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
