#!/usr/bin/env bash
# tests/test-project-discover.sh — Validate project-root autodiscovery (Story 15.1)
#
# Verifies, against checked-in fixtures under tests/fixtures/:
#   1. discover_project_roots resolves to "." for a single-language repo with
#      manifests at repo root (regression safety — Story 15.1 AC 4).
#   2. discover_project_roots finds per-language roots in a two-language
#      monorepo (api/ Python + frontend/ JS) with no manifests at root.
#   3. discover_project_roots finds multiple roots for a single language
#      (services/a, services/b) and runs each independently.
#   4. .devrail.yml `projects:` overrides autodetection.
#   5. A declared language with no manifest anywhere falls back to "." rather
#      than being skipped (also a regression-safety guarantee).
#   6. The full `make _lint`/`make _format`/`make _fix`/`make _test`/
#      `make _security` recipes all run each language's tools with the
#      correct cwd — proving config/alias resolution, not just path
#      discovery (frontend/tsconfig.json + vite.config.ts `@` alias) — and
#      tag per-root failures/skips (e.g. "python:api:bandit") the same way
#      lint does.
#
# Fixtures are copied into a disposable $WORKDIR before any `make` target
# runs against them (never bind-mounted read-write directly) — running a
# target can leave root-owned artifacts (.ruff_cache/, __pycache__/) or, via
# a Docker bind-mount quirk, an empty placeholder file at any container path
# mounted from a host path that doesn't yet exist (e.g. mounting the real
# Makefile at /workspace/Makefile creates a stray host-side "Makefile" if
# /workspace is itself a live bind mount of a fixture that has none).
# Mounting a throwaway copy, cleaned up via trap, keeps tests/fixtures/
# clean regardless. Matches the tests/test-plugin-loader.sh convention.
#
# Usage: bash tests/test-project-discover.sh
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

# workspace_for FIXTURE -> path to a disposable copy of the fixture under
# $WORKDIR, created on first use and reused for subsequent calls with the
# same fixture name within this run.
workspace_for() {
  local fixture="$1"
  local dest="${WORKDIR}/${fixture}"
  if [ ! -d "$dest" ]; then
    cp -R "${FIXTURES}/${fixture}" "$dest"
  fi
  printf '%s' "$dest"
}

# discover FIXTURE LANGUAGE -> newline-separated roots (unit-level: sources
# lib/project-discover.sh directly against the fixture dir, no Makefile).
discover() {
  local fixture="$1" language="$2"
  docker run --rm \
    -v "${REPO_ROOT}/lib:/testlib:ro" \
    -v "${FIXTURES}/${fixture}:/workspace:ro" \
    -w /workspace \
    "$IMAGE" \
    bash -c "source /opt/devrail/lib/log.sh; source /testlib/project-discover.sh; discover_project_roots '${language}'"
}

# run_target FIXTURE MAKE-TARGET -> the JSON summary line for that target
# (e.g. '{"target":"format","status":"pass",...}'). Runs against a disposable
# copy of the fixture with the real Makefile mounted in, matching the
# tests/test-plugin-loader.sh convention.
run_target() {
  local fixture="$1" target="$2"
  local ws
  ws="$(workspace_for "$fixture")"
  local out
  out=$(docker run --rm \
    -e DEVRAIL_LOG_FORMAT=json \
    -v "${ws}:/workspace" \
    -v "${REPO_ROOT}/Makefile:/workspace/Makefile:ro" \
    -w /workspace \
    "$IMAGE" \
    make "_${target}" 2>&1) || true
  printf '%s\n' "$out" | grep -o "{\"target\":\"${target}\".*}" | tail -1 || true
}

echo "==> Unit: single-root-python — python resolves to '.' (regression safety)"
assert_eq "." "$(discover single-root-python python)" "single-root/python"

echo "==> Unit: monorepo-python-js — python resolves to api, javascript resolves to frontend"
assert_eq "api" "$(discover monorepo-python-js python)" "monorepo/python"
assert_eq "frontend" "$(discover monorepo-python-js javascript)" "monorepo/javascript"

echo "==> Unit: multi-root-python — two roots for one language"
assert_eq "$(printf 'services/a\nservices/b')" "$(discover multi-root-python python)" "multi-root/python"

echo "==> Unit: monorepo-with-override — projects: override wins over autodetection"
assert_eq "custom-py-dir" "$(discover monorepo-with-override python)" "override/python"

echo "==> Unit: declared-lang-no-manifest — falls back to '.' rather than being skipped"
assert_eq "." "$(discover declared-lang-no-manifest python)" "no-manifest/python"

echo "==> Integration: make _lint on monorepo-python-js — cwd + local config resolution"
LINT_SUMMARY=$(run_target monorepo-python-js lint)
assert_eq "pass" "$(printf '%s' "$LINT_SUMMARY" | jq -r '.status')" "lint/status"
assert_eq '["python:api","javascript:frontend"]' "$(printf '%s' "$LINT_SUMMARY" | jq -c '.languages')" "lint/languages-tagged-by-root"

echo "==> Integration: make _format on monorepo-python-js — cwd-scoped format check"
FORMAT_SUMMARY=$(run_target monorepo-python-js format)
assert_eq "pass" "$(printf '%s' "$FORMAT_SUMMARY" | jq -r '.status')" "format/status"
assert_eq '["python:api","javascript:frontend"]' "$(printf '%s' "$FORMAT_SUMMARY" | jq -c '.languages')" "format/languages-tagged-by-root"

echo "==> Integration: make _fix on monorepo-python-js — cwd-scoped autofix"
FIX_SUMMARY=$(run_target monorepo-python-js fix)
assert_eq "pass" "$(printf '%s' "$FIX_SUMMARY" | jq -r '.status')" "fix/status"
assert_eq '["python:api","javascript:frontend"]' "$(printf '%s' "$FIX_SUMMARY" | jq -c '.languages')" "fix/languages-tagged-by-root"

echo "==> Integration: make _security on monorepo-python-js — per-root failure/skip tagging"
SECURITY_SUMMARY=$(run_target monorepo-python-js security)
assert_eq "fail" "$(printf '%s' "$SECURITY_SUMMARY" | jq -r '.status')" "security/status"
assert_eq '["python:api:bandit"]' "$(printf '%s' "$SECURITY_SUMMARY" | jq -c '.failed')" "security/failed-tagged-by-root"
assert_eq '["javascript:frontend"]' "$(printf '%s' "$SECURITY_SUMMARY" | jq -c '.skipped')" "security/skipped-tagged-by-root"

echo "==> Integration: make _test on monorepo-python-js — pytest cwd + vitest @ alias resolution"
TEST_WS="$(workspace_for monorepo-python-js)"
TEST_OUT=$(docker run --rm \
  -e DEVRAIL_LOG_FORMAT=json \
  -v "${TEST_WS}:/workspace" \
  -v "${REPO_ROOT}/Makefile:/workspace/Makefile:ro" \
  -w /workspace \
  "$IMAGE" \
  make _test 2>&1) || true
TEST_SUMMARY=$(printf '%s\n' "$TEST_OUT" | grep -o '{"target":"test".*}' | tail -1) || true
assert_eq "pass" "$(printf '%s' "$TEST_SUMMARY" | jq -r '.status')" "test/status"
if printf '%s\n' "$TEST_OUT" | grep -q "src/__tests__/smoke.test.ts"; then
  echo "PASS [test/vitest-ran]"
  PASS=$((PASS + 1))
else
  echo "FAIL [test/vitest-ran]: vitest output for smoke.test.ts not found" >&2
  FAIL=$((FAIL + 1))
fi

echo "==> Integration: single-root-python — byte-identical unqualified tags across lint/format/fix/security (AC 4)"
SINGLE_LINT_SUMMARY=$(run_target single-root-python lint)
assert_eq '["python"]' "$(printf '%s' "$SINGLE_LINT_SUMMARY" | jq -c '.languages')" "single-root/lint-languages-unqualified"

SINGLE_FORMAT_SUMMARY=$(run_target single-root-python format)
assert_eq '["python"]' "$(printf '%s' "$SINGLE_FORMAT_SUMMARY" | jq -c '.languages')" "single-root/format-languages-unqualified"

SINGLE_SECURITY_SUMMARY=$(run_target single-root-python security)
assert_eq '["python:bandit"]' "$(printf '%s' "$SINGLE_SECURITY_SUMMARY" | jq -c '.failed')" "single-root/security-failed-unqualified"

echo ""
echo "==================================="
echo "Results: ${PASS} passed, ${FAIL} failed"
echo "==================================="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
