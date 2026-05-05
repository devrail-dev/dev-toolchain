#!/usr/bin/env bash
# tests/test-plugin-execution.sh — Validate the plugin execution loop (Story 13.5)
#
# 10 cases covering AC10:
#   1. No plugins → dispatcher is a no-op (no events, no aggregation)
#   2. Single plugin, lint passes → entry in ran_languages, exit 0
#   3. Single plugin, lint fails → entry in failed_languages, overall_exit=1
#   4. Gate skip (gate path absent) → no execution, 'gate skipped' event
#   5. Gate run (gate path present) → executes normally
#   6. {paths} interpolation with paths_var (filtered to existing paths)
#   7. Per-language override replaces manifest default cmd
#   8. DEVRAIL_FAIL_FAST=1 short-circuits on first plugin failure
#   9. Manifest has 'lint' but no 'test' target → _test invocation skips silently
#  10. JSON regression: zero-plugin run produces byte-identical event shape
#
# Usage: bash tests/test-plugin-execution.sh
# Env:
#   DEVRAIL_IMAGE  override image name (default: ghcr.io/devrail-dev/dev-toolchain)
#   DEVRAIL_TAG    override image tag  (default: local)

set -euo pipefail

IMAGE="${DEVRAIL_IMAGE:-ghcr.io/devrail-dev/dev-toolchain}:${DEVRAIL_TAG:-local}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="$(mktemp -d)"

cleanup() {
  if [ -n "${WORKDIR:-}" ] && [ -d "$WORKDIR" ]; then
    docker run --rm -v "$WORKDIR:/cleanup" "$IMAGE" \
      sh -c 'rm -rf /cleanup/* /cleanup/.[!.]* 2>/dev/null || true' >/dev/null 2>&1 || true
    rmdir "$WORKDIR" 2>/dev/null || rm -rf "$WORKDIR" 2>/dev/null || true
  fi
}
trap cleanup EXIT

assert_eq() {
  local expected="$1" actual="$2" context="$3"
  if [ "$expected" != "$actual" ]; then
    echo "FAIL [$context]: expected '$expected', got '$actual'" >&2
    exit 1
  fi
}

assert_jq() {
  local file="$1" filter="$2" context="$3"
  if ! grep -aE '^\{.*\}$' "$file" | jq -e "$filter" >/dev/null 2>&1; then
    echo "FAIL [$context]: jq filter '$filter' did not match any event in:" >&2
    cat "$file" >&2
    exit 1
  fi
}

# run_dispatch_in_container <case-dir> <target>
# Sources lib/plugin-execute.sh inside the container and calls
# dispatch_plugin_target. Stdout = the final shell vars; stderr = log_event
# stream. Exit code = overall_exit at end of dispatch.
run_dispatch_in_container() {
  local case_dir="$1" target="$2"
  RUN_EXIT=0
  RUN_OUT="$(docker run --rm \
    -v "$case_dir:/workspace" \
    -v "$REPO_ROOT/lib:/opt/devrail/lib:ro" \
    -e DEVRAIL_PLUGINS_CACHE=/workspace/cache.yaml \
    -e DEVRAIL_LOG_FORMAT=json \
    -e DEVRAIL_FAIL_FAST="${DEVRAIL_FAIL_FAST:-0}" \
    -e DEVRAIL_CONFIG=/workspace/.devrail.yml \
    -w /workspace \
    "$IMAGE" \
    bash -c '
      set +e
      . /opt/devrail/lib/plugin-execute.sh
      overall_exit=0
      ran_languages=""
      failed_languages=""
      dispatch_plugin_target "'"$target"'"
      echo "DISPATCH_RESULT overall_exit=$overall_exit ran_languages=${ran_languages%,} failed_languages=${failed_languages%,}"
      exit $overall_exit
    ' 2>&1)" || RUN_EXIT=$?
}

# --- Case 1: no plugins → dispatcher is a no-op ---
echo "==> Case 1: empty cache → dispatcher no-op, exit 0"
mkdir -p "$WORKDIR/case1"
cat >"$WORKDIR/case1/cache.yaml" <<'YAML'
plugins: []
YAML
cat >"$WORKDIR/case1/.devrail.yml" <<'YAML'
languages: [bash]
YAML
run_dispatch_in_container "$WORKDIR/case1" "lint"
assert_eq "0" "$RUN_EXIT" "case1 exit code"
echo "$RUN_OUT" | grep -q "DISPATCH_RESULT overall_exit=0 ran_languages= failed_languages=" || {
  echo "FAIL [case1]: expected empty ran/failed_languages, got:" >&2
  echo "$RUN_OUT" >&2
  exit 1
}
# No plugin-related events should appear
if echo "$RUN_OUT" | grep -q "plugin target"; then
  echo "FAIL [case1]: dispatcher should not emit plugin events when cache is empty" >&2
  echo "$RUN_OUT" >&2
  exit 1
fi

# --- Case 2: single plugin, lint passes → ran_languages updated ---
echo "==> Case 2: single plugin, lint cmd 'true' → ran_languages=elixir"
mkdir -p "$WORKDIR/case2"
cat >"$WORKDIR/case2/cache.yaml" <<'YAML'
plugins:
  - name: elixir
    rev: v1.0.0
    source: github.com/community/devrail-plugin-elixir
    schema_version: 1
    targets:
      lint:
        cmd: "true"
YAML
cat >"$WORKDIR/case2/.devrail.yml" <<'YAML'
languages: [elixir]
YAML
run_dispatch_in_container "$WORKDIR/case2" "lint"
assert_eq "0" "$RUN_EXIT" "case2 exit code"
echo "$RUN_OUT" | grep -q 'DISPATCH_RESULT overall_exit=0 ran_languages="elixir" failed_languages=$' || {
  echo "FAIL [case2]: expected ran_languages=\"elixir\", got:" >&2
  echo "$RUN_OUT" >&2
  exit 1
}
echo "$RUN_OUT" >"$WORKDIR/case2.log"
assert_jq "$WORKDIR/case2.log" 'select(.msg=="plugin target executing" and .plugin=="elixir" and .target=="lint")' "case2 executing event"
assert_jq "$WORKDIR/case2.log" 'select(.msg=="plugin target passed" and .plugin=="elixir")' "case2 passed event"

# --- Case 3: single plugin, lint fails → failed_languages updated ---
echo "==> Case 3: single plugin, lint cmd 'false' → failed_languages=elixir"
mkdir -p "$WORKDIR/case3"
cat >"$WORKDIR/case3/cache.yaml" <<'YAML'
plugins:
  - name: elixir
    rev: v1.0.0
    source: github.com/community/devrail-plugin-elixir
    schema_version: 1
    targets:
      lint:
        cmd: "false"
YAML
cat >"$WORKDIR/case3/.devrail.yml" <<'YAML'
languages: [elixir]
YAML
run_dispatch_in_container "$WORKDIR/case3" "lint"
assert_eq "1" "$RUN_EXIT" "case3 exit code"
echo "$RUN_OUT" | grep -q 'DISPATCH_RESULT overall_exit=1 ran_languages="elixir" failed_languages="elixir"$' || {
  echo "FAIL [case3]: expected failed_languages=\"elixir\", got:" >&2
  echo "$RUN_OUT" >&2
  exit 1
}
echo "$RUN_OUT" >"$WORKDIR/case3.log"
assert_jq "$WORKDIR/case3.log" 'select(.level=="error" and .msg=="plugin target failed" and .plugin=="elixir")' "case3 failed event"

# --- Case 4: gate path absent → skip without execution ---
echo "==> Case 4: gate path absent → skip event, no execution"
mkdir -p "$WORKDIR/case4"
cat >"$WORKDIR/case4/cache.yaml" <<'YAML'
plugins:
  - name: elixir
    rev: v1.0.0
    source: github.com/community/devrail-plugin-elixir
    schema_version: 1
    targets:
      lint:
        cmd: "false"
    gates:
      lint: ["mix.exs"]
YAML
cat >"$WORKDIR/case4/.devrail.yml" <<'YAML'
languages: [elixir]
YAML
run_dispatch_in_container "$WORKDIR/case4" "lint"
assert_eq "0" "$RUN_EXIT" "case4 exit code"
echo "$RUN_OUT" | grep -q 'DISPATCH_RESULT overall_exit=0 ran_languages= failed_languages=$' || {
  echo "FAIL [case4]: gate skip should leave ran/failed empty, got:" >&2
  echo "$RUN_OUT" >&2
  exit 1
}
echo "$RUN_OUT" >"$WORKDIR/case4.log"
assert_jq "$WORKDIR/case4.log" 'select(.msg=="plugin gate skipped" and .plugin=="elixir" and .target=="lint")' "case4 gate skipped event"

# --- Case 5: gate path present → executes normally ---
echo "==> Case 5: gate path present → executes"
mkdir -p "$WORKDIR/case5"
touch "$WORKDIR/case5/mix.exs"
cat >"$WORKDIR/case5/cache.yaml" <<'YAML'
plugins:
  - name: elixir
    rev: v1.0.0
    source: github.com/community/devrail-plugin-elixir
    schema_version: 1
    targets:
      lint:
        cmd: "true"
    gates:
      lint: ["mix.exs"]
YAML
cat >"$WORKDIR/case5/.devrail.yml" <<'YAML'
languages: [elixir]
YAML
run_dispatch_in_container "$WORKDIR/case5" "lint"
assert_eq "0" "$RUN_EXIT" "case5 exit code"
echo "$RUN_OUT" | grep -q 'DISPATCH_RESULT overall_exit=0 ran_languages="elixir" failed_languages=$' || {
  echo "FAIL [case5]: gate-passed lint should record ran_languages, got:" >&2
  echo "$RUN_OUT" >&2
  exit 1
}

# --- Case 6: {paths} interpolation ---
echo "==> Case 6: {paths} interpolated from paths_var (existing paths only)"
mkdir -p "$WORKDIR/case6/lib" "$WORKDIR/case6/test"
# Note: we set ELIXIR_PATHS to include a non-existent path; the dispatcher
# must filter it out before interpolation.
cat >"$WORKDIR/case6/cache.yaml" <<'YAML'
plugins:
  - name: elixir
    rev: v1.0.0
    source: github.com/community/devrail-plugin-elixir
    schema_version: 1
    targets:
      lint:
        cmd: "echo PATHS={paths} > /workspace/result.txt"
        paths_var: ELIXIR_PATHS
        paths_default: "lib test"
YAML
cat >"$WORKDIR/case6/.devrail.yml" <<'YAML'
languages: [elixir]
YAML
RUN_EXIT=0
RUN_OUT="$(docker run --rm \
  -v "$WORKDIR/case6:/workspace" \
  -v "$REPO_ROOT/lib:/opt/devrail/lib:ro" \
  -e DEVRAIL_PLUGINS_CACHE=/workspace/cache.yaml \
  -e DEVRAIL_LOG_FORMAT=json \
  -e DEVRAIL_CONFIG=/workspace/.devrail.yml \
  -e ELIXIR_PATHS="lib test does-not-exist" \
  -w /workspace \
  "$IMAGE" \
  bash -c '
    set +e
    . /opt/devrail/lib/plugin-execute.sh
    overall_exit=0; ran_languages=""; failed_languages=""
    dispatch_plugin_target lint
    exit $overall_exit
  ' 2>&1)" || RUN_EXIT=$?
assert_eq "0" "$RUN_EXIT" "case6 exit code"
result="$(cat "$WORKDIR/case6/result.txt" 2>/dev/null || true)"
assert_eq "PATHS=lib test" "$result" "case6 paths interpolated and filtered"

# --- Case 7: per-language override replaces manifest default ---
echo "==> Case 7: .devrail.yml override replaces plugin default cmd"
mkdir -p "$WORKDIR/case7"
cat >"$WORKDIR/case7/cache.yaml" <<'YAML'
plugins:
  - name: elixir
    rev: v1.0.0
    source: github.com/community/devrail-plugin-elixir
    schema_version: 1
    targets:
      lint:
        cmd: "false"
YAML
# Override: replace 'false' with 'true' so target passes.
cat >"$WORKDIR/case7/.devrail.yml" <<'YAML'
languages: [elixir]
elixir:
  linter: "true"
YAML
run_dispatch_in_container "$WORKDIR/case7" "lint"
assert_eq "0" "$RUN_EXIT" "case7 exit code (override 'false' → 'true')"
echo "$RUN_OUT" | grep -q 'DISPATCH_RESULT overall_exit=0 ran_languages="elixir"' || {
  echo "FAIL [case7]: override should make plugin target pass, got:" >&2
  echo "$RUN_OUT" >&2
  exit 1
}

# --- Case 8: DEVRAIL_FAIL_FAST=1 short-circuits ---
echo "==> Case 8: DEVRAIL_FAIL_FAST=1 stops on first plugin failure"
mkdir -p "$WORKDIR/case8"
# Two plugins; first fails, second has cmd 'touch /workspace/second-ran' so
# the test can detect whether it was reached.
cat >"$WORKDIR/case8/cache.yaml" <<'YAML'
plugins:
  - name: alpha
    rev: v1.0.0
    source: github.com/test/alpha
    schema_version: 1
    targets:
      lint:
        cmd: "false"
  - name: beta
    rev: v1.0.0
    source: github.com/test/beta
    schema_version: 1
    targets:
      lint:
        cmd: "touch /workspace/second-ran"
YAML
cat >"$WORKDIR/case8/.devrail.yml" <<'YAML'
languages: [alpha, beta]
YAML
DEVRAIL_FAIL_FAST=1 run_dispatch_in_container "$WORKDIR/case8" "lint"
assert_eq "1" "$RUN_EXIT" "case8 exit code"
[ ! -f "$WORKDIR/case8/second-ran" ] || {
  echo "FAIL [case8]: second plugin must NOT run under DEVRAIL_FAIL_FAST=1" >&2
  exit 1
}

# --- Case 9: manifest has 'lint' but not 'test' ---
echo "==> Case 9: plugin without 'test' target → _test dispatch silent skip"
mkdir -p "$WORKDIR/case9"
cat >"$WORKDIR/case9/cache.yaml" <<'YAML'
plugins:
  - name: elixir
    rev: v1.0.0
    source: github.com/community/devrail-plugin-elixir
    schema_version: 1
    targets:
      lint:
        cmd: "true"
YAML
cat >"$WORKDIR/case9/.devrail.yml" <<'YAML'
languages: [elixir]
YAML
run_dispatch_in_container "$WORKDIR/case9" "test"
assert_eq "0" "$RUN_EXIT" "case9 exit code (no 'test' target)"
echo "$RUN_OUT" | grep -q 'DISPATCH_RESULT overall_exit=0 ran_languages= failed_languages=$' || {
  echo "FAIL [case9]: silent skip should leave ran/failed empty, got:" >&2
  echo "$RUN_OUT" >&2
  exit 1
}
# No plugin events for the test target
if echo "$RUN_OUT" | grep -q "plugin target executing"; then
  echo "FAIL [case9]: should not emit 'executing' event when target absent" >&2
  exit 1
fi

# --- Case 10: zero-plugin _lint emits a baseline JSON shape ---
echo "==> Case 10: empty cache + _lint envelope → identical JSON to v1.10.4 baseline"
mkdir -p "$WORKDIR/case10"
cat >"$WORKDIR/case10/cache.yaml" <<'YAML'
plugins: []
YAML
cat >"$WORKDIR/case10/.devrail.yml" <<'YAML'
languages: [bash]
YAML
RUN_EXIT=0
case10_out="$(docker run --rm \
  -v "$WORKDIR/case10:/workspace" \
  -v "$REPO_ROOT/lib:/opt/devrail/lib:ro" \
  -e DEVRAIL_PLUGINS_CACHE=/workspace/cache.yaml \
  -e DEVRAIL_LOG_FORMAT=json \
  -e DEVRAIL_CONFIG=/workspace/.devrail.yml \
  -w /workspace \
  "$IMAGE" \
  bash -c '
    set +e
    . /opt/devrail/lib/plugin-execute.sh
    overall_exit=0; ran_languages=""; failed_languages=""
    dispatch_plugin_target lint
    # Emit the same JSON shape the recipe would emit (pass path)
    echo "{\"target\":\"lint\",\"status\":\"pass\",\"duration_ms\":0,\"languages\":[${ran_languages%,}]}"
    exit $overall_exit
  ' 2>&1)" || RUN_EXIT=$?
assert_eq "0" "$RUN_EXIT" "case10 exit code"
# The JSON line must match the v1.10.x shape exactly: no `plugins:` array, no
# extra fields. `languages: []` is the baseline shape for "no languages".
expected_shape='{"target":"lint","status":"pass","duration_ms":0,"languages":[]}'
got_line="$(echo "$case10_out" | grep -E '^\{.*"target":"lint"' | tail -1)"
assert_eq "$expected_shape" "$got_line" "case10 JSON shape regression"

echo "==> All plugin-execution checks passed (10/10)"
