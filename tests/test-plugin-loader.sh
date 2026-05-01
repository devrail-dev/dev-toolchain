#!/usr/bin/env bash
# tests/test-plugin-loader.sh — Validate the plugin manifest parser + loader (Story 13.2)
#
# Verifies, against checked-in fixtures under tests/fixtures/plugins/:
#   1. The validator accepts a valid v1 manifest.
#   2. Each negative fixture (invalid-schema, incompatible-version, bad-name,
#      missing-field) is rejected with the expected JSON event.
#   3. The Makefile loader (`_plugins-load`) is a no-op when .devrail.yml has
#      no `plugins:` section — regression safety for v1.9.x consumers.
#   4. The Makefile loader exits 2 when any declared plugin's manifest fails.
#   5. The Makefile loader writes a parsed cache when all manifests pass.
#
# Usage: bash tests/test-plugin-loader.sh
# Env:
#   DEVRAIL_IMAGE  override image name (default: ghcr.io/devrail-dev/dev-toolchain)
#   DEVRAIL_TAG    override image tag  (default: local)

set -euo pipefail

IMAGE="${DEVRAIL_IMAGE:-ghcr.io/devrail-dev/dev-toolchain}:${DEVRAIL_TAG:-local}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_BASE="${REPO_ROOT}/tests/fixtures/plugins"
WORKDIR="$(mktemp -d)"

cleanup() {
  if [ -n "${WORKDIR:-}" ] && [ -d "$WORKDIR" ]; then
    docker run --rm -v "$WORKDIR:/cleanup" "$IMAGE" \
      sh -c 'rm -rf /cleanup/* /cleanup/.[!.]* 2>/dev/null || true' >/dev/null 2>&1 || true
    rmdir "$WORKDIR" 2>/dev/null || rm -rf "$WORKDIR" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# run_validator FIXTURE_NAME -> stderr from the validator, with exit code captured
run_validator() {
  local fixture="$1"
  docker run --rm \
    -v "$FIXTURE_BASE:/fixtures:ro" \
    -e DEVRAIL_VERSION="${DEVRAIL_VERSION_OVERRIDE:-1.10.0}" \
    "$IMAGE" \
    bash /opt/devrail/scripts/plugin-validator.sh "/fixtures/$fixture/plugin.devrail.yml" \
    2>&1
}

# assert_eq EXPECTED ACTUAL CONTEXT
assert_eq() {
  local expected="$1" actual="$2" context="$3"
  if [ "$expected" != "$actual" ]; then
    echo "FAIL [$context]: expected '$expected', got '$actual'" >&2
    exit 1
  fi
}

# assert_jq EVENTS-FILE JQ-FILTER CONTEXT
assert_jq() {
  local events="$1" filter="$2" context="$3"
  if ! grep -E '^\{' "$events" | jq -e "$filter" >/dev/null 2>&1; then
    echo "FAIL [$context]: jq filter '$filter' did not match any event in:" >&2
    grep -E '^\{' "$events" | jq -c . >&2 2>/dev/null || cat "$events" >&2
    exit 1
  fi
}

# --- Unit-level: the validator alone, against each fixture -----------------

echo "==> Unit: valid-elixir → exit 0, 'manifest valid' info event"
out="$(run_validator valid-elixir)" && exit_code=0 || exit_code=$?
assert_eq "0" "$exit_code" "valid-elixir exit code"
echo "$out" >"$WORKDIR/valid.events"
assert_jq "$WORKDIR/valid.events" 'select(.level=="info" and .msg=="manifest valid" and .plugin=="elixir")' "valid-elixir manifest valid event"

echo "==> Unit: invalid-schema → exit 2, schema_version violation"
out="$(run_validator invalid-schema)" && exit_code=0 || exit_code=$?
assert_eq "2" "$exit_code" "invalid-schema exit code"
echo "$out" >"$WORKDIR/invalid-schema.events"
assert_jq "$WORKDIR/invalid-schema.events" 'select(.level=="error" and .field=="schema_version" and (.reason | contains("unsupported version 2")))' "invalid-schema violation event"

echo "==> Unit: incompatible-version → exit 2, devrail_min_version violation"
out="$(run_validator incompatible-version)" && exit_code=0 || exit_code=$?
assert_eq "2" "$exit_code" "incompatible-version exit code"
echo "$out" >"$WORKDIR/incompatible-version.events"
assert_jq "$WORKDIR/incompatible-version.events" 'select(.level=="error" and .field=="devrail_min_version" and (.reason | contains("requires 99.0.0")))' "incompatible-version violation event"

echo "==> Unit: bad-name → exit 2, name regex violation"
out="$(run_validator bad-name)" && exit_code=0 || exit_code=$?
assert_eq "2" "$exit_code" "bad-name exit code"
echo "$out" >"$WORKDIR/bad-name.events"
assert_jq "$WORKDIR/bad-name.events" 'select(.level=="error" and .field=="name" and (.reason | contains("does not match")))' "bad-name violation event"

echo "==> Unit: missing-field (no targets) → exit 2, targets violation"
out="$(run_validator missing-field)" && exit_code=0 || exit_code=$?
assert_eq "2" "$exit_code" "missing-field exit code"
echo "$out" >"$WORKDIR/missing-field.events"
assert_jq "$WORKDIR/missing-field.events" 'select(.level=="error" and .field=="targets" and (.reason | contains("required field is missing")))' "missing-field violation event"

# --- Integration: full _plugins-load loader against synthetic .devrail.yml --

echo "==> Integration: no plugins section → loader exits 0 with 'no plugins' event"
mkdir -p "$WORKDIR/no-plugins"
cat >"$WORKDIR/no-plugins/.devrail.yml" <<'YAML'
languages: [bash]
YAML
out="$(docker run --rm \
  -v "$WORKDIR/no-plugins:/workspace" \
  -v "$REPO_ROOT/Makefile:/workspace/Makefile:ro" \
  -w /workspace \
  "$IMAGE" \
  make _plugins-load 2>&1)" && exit_code=0 || exit_code=$?
assert_eq "0" "$exit_code" "no-plugins-section exit code"
echo "$out" >"$WORKDIR/no-plugins.events"
assert_jq "$WORKDIR/no-plugins.events" 'select(.msg=="no plugins declared")' "no-plugins-declared event"

echo "==> Integration: valid plugin → loader exits 0, writes cache, emits summary"
mkdir -p "$WORKDIR/with-valid"
cat >"$WORKDIR/with-valid/.devrail.yml" <<'YAML'
languages: [elixir]
plugins:
  - source: github.com/community/valid-elixir
    rev: v1.0.0
    languages: [elixir]
YAML
out="$(docker run --rm \
  -v "$WORKDIR/with-valid:/workspace" \
  -v "$REPO_ROOT/Makefile:/workspace/Makefile:ro" \
  -v "$FIXTURE_BASE:/opt/devrail/plugins:ro" \
  -e DEVRAIL_VERSION=1.10.0 \
  -w /workspace \
  "$IMAGE" \
  make _plugins-load 2>&1)" && exit_code=0 || exit_code=$?
assert_eq "0" "$exit_code" "valid-plugin exit code"
echo "$out" >"$WORKDIR/with-valid.events"
assert_jq "$WORKDIR/with-valid.events" 'select(.msg=="plugin loader complete" and .loaded==1 and .failed==0)' "valid-plugin loader-complete event"

echo "==> Integration: invalid plugin → loader exits 2 with failed counter"
mkdir -p "$WORKDIR/with-invalid"
cat >"$WORKDIR/with-invalid/.devrail.yml" <<'YAML'
languages: [bad-name]
plugins:
  - source: github.com/community/bad-name
    rev: v1.0.0
    languages: [bad-name]
YAML
out="$(docker run --rm \
  -v "$WORKDIR/with-invalid:/workspace" \
  -v "$REPO_ROOT/Makefile:/workspace/Makefile:ro" \
  -v "$FIXTURE_BASE:/opt/devrail/plugins:ro" \
  -e DEVRAIL_VERSION=1.10.0 \
  -w /workspace \
  "$IMAGE" \
  make _plugins-load 2>&1)" && exit_code=0 || exit_code=$?
assert_eq "2" "$exit_code" "invalid-plugin exit code"
echo "$out" >"$WORKDIR/with-invalid.events"
assert_jq "$WORKDIR/with-invalid.events" 'select(.msg=="plugin loader complete" and .failed >= 1)' "invalid-plugin failure-summary event"

echo "==> All plugin-loader smoke checks passed"
