#!/usr/bin/env bash
# tests/test-dependency-install.sh — Validate dependency install before `make test` (Story 15.2)
#
# Verifies, against checked-in fixtures under tests/fixtures/, that `make
# _test` installs a project's own dependencies before pytest/vitest run:
#   1. uv.lock -> `uv export | uv pip install --system` (Python)
#   2. requirements*.txt -> `pip install -r <file>` (Python)
#   3. pyproject.toml only -> `pip install -e .` (Python)
#   4. package-lock.json -> `npm ci` (JS)
#   5. `.devrail.yml` test.install overrides autodetection
#   6. `.devrail.yml` test.setup runs after install, before the test suite
#   7. A failed install fails `make test` fast — the test suite never runs
#      against a broken/partial install (AC 8)
#   8. A project with no lockfile/manifest for a declared language is
#      unaffected — no install step runs (AC 7, regression safety; reuses
#      Story 15.1's declared-lang-no-manifest and monorepo-python-js
#      fixtures for the Python and JS sides respectively)
#   9. requirements.txt wins over requirements-dev.txt (or any other
#      requirements*.txt variant) rather than picking whichever sorts
#      first alphabetically — '-' sorts before '.' in ASCII, so a naive
#      sorted-glob pick would silently prefer requirements-dev.txt
#
# Every installing case here does a REAL network install against PyPI/npm
# inside the container — this is intentional, not an oversight. The whole
# point of this story is that a real install unblocks a real import; a
# mocked network call would prove nothing about the actual bug in issue
# #52. Requires network egress (present in CI; present in any normal dev
# environment).
#
# Fixtures are copied into a disposable $WORKDIR before any `make` target
# runs against them, never bind-mounted read-write directly — an install
# step creates root-owned artifacts (site-packages entries, node_modules/),
# and Story 15.1's own test script had to be rewritten once already after
# a Docker bind-mount quirk leaked a stray file into tracked fixtures from
# doing exactly that. See tests/test-project-discover.sh for the same
# pattern.
#
# Usage: bash tests/test-dependency-install.sh
# Env:
#   DEVRAIL_IMAGE  override image name (default: ghcr.io/devrail-dev/dev-toolchain)
#   DEVRAIL_TAG    override image tag  (default: local)

set -euo pipefail

IMAGE="${DEVRAIL_IMAGE:-ghcr.io/devrail-dev/dev-toolchain}:${DEVRAIL_TAG:-local}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="${REPO_ROOT}/tests/fixtures"
WORKDIR="$(mktemp -d)"

cleanup() {
  if [ -n "${WORKDIR:-}" ] && [ -d "$WORKDIR" ]; then
    docker run --rm -v "$WORKDIR:/cleanup" "$IMAGE" \
      sh -c 'rm -rf /cleanup/* /cleanup/.[!.]* 2>/dev/null || true' >/dev/null 2>&1 || true
    rmdir "$WORKDIR" 2>/dev/null || rm -rf "$WORKDIR" 2>/dev/null || true
  fi
}
trap cleanup EXIT

PASS=0
FAIL=0

# assert_eq EXPECTED ACTUAL CONTEXT
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

# run_test FIXTURE -> the JSON summary line for `make _test` against a
# disposable copy of the fixture, with the real Makefile mounted in.
run_test() {
  local fixture="$1"
  local ws="${WORKDIR}/${fixture}"
  cp -R "${FIXTURES}/${fixture}" "$ws"
  local out
  out=$(docker run --rm \
    -e DEVRAIL_LOG_FORMAT=json \
    -v "${ws}:/workspace" \
    -v "${REPO_ROOT}/Makefile:/workspace/Makefile:ro" \
    -w /workspace \
    "$IMAGE" \
    make _test 2>&1) || true
  printf '%s\n' "$out" | grep -o '{"target":"test".*}' | tail -1 || true
}

echo "==> python-uv-deps: uv.lock -> uv export | uv pip install --system"
SUMMARY=$(run_test python-uv-deps)
assert_eq "pass" "$(printf '%s' "$SUMMARY" | jq -r '.status')" "uv-deps/status"

echo "==> python-requirements-deps: requirements.txt -> pip install -r"
SUMMARY=$(run_test python-requirements-deps)
assert_eq "pass" "$(printf '%s' "$SUMMARY" | jq -r '.status')" "requirements-deps/status"

echo "==> python-pyproject-only: pyproject.toml only -> pip install -e ."
SUMMARY=$(run_test python-pyproject-only)
assert_eq "pass" "$(printf '%s' "$SUMMARY" | jq -r '.status')" "pyproject-only/status"

echo "==> python-multi-requirements: requirements.txt wins over requirements-dev.txt (not alphabetical sort)"
SUMMARY=$(run_test python-multi-requirements)
assert_eq "pass" "$(printf '%s' "$SUMMARY" | jq -r '.status')" "multi-requirements/status"

echo "==> js-npm-deps: package-lock.json -> npm ci"
SUMMARY=$(run_test js-npm-deps)
assert_eq "pass" "$(printf '%s' "$SUMMARY" | jq -r '.status')" "npm-deps/status"

echo "==> test-install-override: test.install wins over a requirements.txt that would otherwise fail"
SUMMARY=$(run_test test-install-override)
assert_eq "pass" "$(printf '%s' "$SUMMARY" | jq -r '.status')" "install-override/status"

echo "==> test-setup-ordering: test.setup runs after install (no-op here), before the test suite"
SUMMARY=$(run_test test-setup-ordering)
assert_eq "pass" "$(printf '%s' "$SUMMARY" | jq -r '.status')" "setup-ordering/status"

echo "==> python-install-fails: a broken install fails fast — pytest must never run (AC 8)"
INSTALL_FAILS_OUT_WS="${WORKDIR}/python-install-fails-raw"
cp -R "${FIXTURES}/python-install-fails" "$INSTALL_FAILS_OUT_WS"
RAW_OUT=$(docker run --rm \
  -e DEVRAIL_LOG_FORMAT=json \
  -v "${INSTALL_FAILS_OUT_WS}:/workspace" \
  -v "${REPO_ROOT}/Makefile:/workspace/Makefile:ro" \
  -w /workspace \
  "$IMAGE" \
  make _test 2>&1) || true
SUMMARY=$(printf '%s\n' "$RAW_OUT" | grep -o '{"target":"test".*}' | tail -1) || true
assert_eq "fail" "$(printf '%s' "$SUMMARY" | jq -r '.status')" "install-fails/status"
assert_eq '["python:install"]' "$(printf '%s' "$SUMMARY" | jq -c '.failed')" "install-fails/failed-tag"
if printf '%s\n' "$RAW_OUT" | grep -q "pytest ran despite a failed dependency install"; then
  echo "FAIL [install-fails/pytest-did-not-run]: pytest executed the test suite despite a failed install" >&2
  FAIL=$((FAIL + 1))
else
  echo "PASS [install-fails/pytest-did-not-run]"
  PASS=$((PASS + 1))
fi

echo "==> declared-lang-no-manifest (Story 15.1 fixture): no lockfile/manifest (Python) -> no install attempted, unaffected"
SUMMARY=$(run_test declared-lang-no-manifest)
assert_eq "skip" "$(printf '%s' "$SUMMARY" | jq -r '.status')" "no-manifest/status"

echo "==> monorepo-python-js (Story 15.1 fixture): frontend/ has package.json but no package-lock.json -> JS install no-op, unaffected"
SUMMARY=$(run_test monorepo-python-js)
assert_eq "pass" "$(printf '%s' "$SUMMARY" | jq -r '.status')" "js-no-lockfile/status"

echo ""
echo "==================================="
echo "Results: ${PASS} passed, ${FAIL} failed"
echo "==================================="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
