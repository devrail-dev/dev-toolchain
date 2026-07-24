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
#   6. The full `make _lint`/`make _test` recipes run each language's tools
#      with the correct cwd — proving config/alias resolution, not just path
#      discovery (frontend/tsconfig.json + vite.config.ts `@` alias).
#
# Usage: bash tests/test-project-discover.sh
# Env:
#   DEVRAIL_IMAGE  override image name (default: ghcr.io/devrail-dev/dev-toolchain)
#   DEVRAIL_TAG    override image tag  (default: local)

set -euo pipefail

IMAGE="${DEVRAIL_IMAGE:-ghcr.io/devrail-dev/dev-toolchain}:${DEVRAIL_TAG:-local}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="${REPO_ROOT}/tests/fixtures"

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
LINT_OUT=$(docker run --rm \
  -e DEVRAIL_LOG_FORMAT=json \
  -v "${FIXTURES}/monorepo-python-js:/workspace" \
  -v "${REPO_ROOT}/Makefile:/workspace/Makefile:ro" \
  -w /workspace \
  "$IMAGE" \
  make _lint 2>&1) || true
LINT_SUMMARY=$(printf '%s\n' "$LINT_OUT" | grep -o '{"target":"lint".*}' | tail -1) || true
assert_eq "pass" "$(printf '%s' "$LINT_SUMMARY" | jq -r '.status')" "lint/status"
assert_eq '["python:api","javascript:frontend"]' "$(printf '%s' "$LINT_SUMMARY" | jq -c '.languages')" "lint/languages-tagged-by-root"

echo "==> Integration: make _test on monorepo-python-js — pytest cwd + vitest @ alias resolution"
TEST_OUT=$(docker run --rm \
  -e DEVRAIL_LOG_FORMAT=json \
  -v "${FIXTURES}/monorepo-python-js:/workspace" \
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

echo "==> Integration: make _lint on single-root-python — byte-identical unqualified tag (AC 4)"
SINGLE_LINT_OUT=$(docker run --rm \
  -e DEVRAIL_LOG_FORMAT=json \
  -v "${FIXTURES}/single-root-python:/workspace" \
  -v "${REPO_ROOT}/Makefile:/workspace/Makefile:ro" \
  -w /workspace \
  "$IMAGE" \
  make _lint 2>&1) || true
SINGLE_LINT_SUMMARY=$(printf '%s\n' "$SINGLE_LINT_OUT" | grep -o '{"target":"lint".*}' | tail -1) || true
assert_eq '["python"]' "$(printf '%s' "$SINGLE_LINT_SUMMARY" | jq -c '.languages')" "single-root/lint-languages-unqualified"

echo ""
echo "==================================="
echo "Results: ${PASS} passed, ${FAIL} failed"
echo "==================================="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
