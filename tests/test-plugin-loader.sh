#!/usr/bin/env bash
# tests/test-plugin-loader.sh — Validate the plugin manifest parser + loader (Story 13.2)
#
# Verifies, against checked-in fixtures under tests/fixtures/plugins/<slug>/v1.0.0/:
#   1. The validator accepts a valid v1 manifest.
#   2. Each negative fixture (invalid-schema, incompatible-version, bad-name,
#      missing-field, bad-gates) is rejected with the expected JSON event.
#   3. The Makefile loader (`_plugins-load`) is a no-op when .devrail.yml has
#      no `plugins:` section AND when `plugins: []` (regression safety).
#   4. The Makefile loader exits 2 when any declared plugin's manifest fails.
#   5. The Makefile loader exits 2 when a plugin entry is missing `source` or `rev`.
#   6. The Makefile loader writes a parsed cache that includes the FULL manifest
#      content (targets, gates, etc.) merged with resolution metadata.
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

# write_matching_lockfile <workspace> <fixture-slug> <source> <rev>
# Generates a `.devrail.lock` that matches the given source/rev/fixture so
# `_plugins-verify` (Story 13.3 prereq) passes. Computes content_hash inside
# the container against the bind-mounted fixture tree.
write_matching_lockfile() {
  local ws="$1" slug="$2" source="$3" rev="$4"
  local content_hash
  content_hash=$(docker run --rm \
    -v "$FIXTURE_BASE/$slug/$rev:/plugin:ro" \
    "$IMAGE" \
    sh -c "cd /plugin && find . -type f -not -path './.git/*' -not -name '.devrail.sha' -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1")
  cat >"$ws/.devrail.lock" <<LOCK
schema_version: 1
plugins:
  - source: $source
    rev: $rev
    sha: 0000000000000000000000000000000000000000
    schema_version: 1
    content_hash: sha256:$content_hash
LOCK
}

# run_validator FIXTURE_NAME -> stderr from the validator, with exit code captured
run_validator() {
  local fixture="$1"
  docker run --rm \
    -v "$FIXTURE_BASE:/fixtures:ro" \
    -e DEVRAIL_VERSION="${DEVRAIL_VERSION_OVERRIDE:-1.10.0}" \
    "$IMAGE" \
    bash /opt/devrail/scripts/plugin-validator.sh "/fixtures/$fixture/v1.0.0/plugin.devrail.yml" \
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

echo "==> Unit: bad-gates → exit 2, gates type + unknown target violations"
out="$(run_validator bad-gates)" && exit_code=0 || exit_code=$?
assert_eq "2" "$exit_code" "bad-gates exit code"
echo "$out" >"$WORKDIR/bad-gates.events"
assert_jq "$WORKDIR/bad-gates.events" 'select(.level=="error" and .field=="gates.lint" and (.reason | contains("must be a list of paths")))' "bad-gates lint-not-a-list violation"
assert_jq "$WORKDIR/bad-gates.events" 'select(.level=="error" and .field=="gates.unknown-target")' "bad-gates unknown-target violation"

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

echo "==> Integration: empty plugins:[] array → loader exits 0 with 'no plugins' event"
mkdir -p "$WORKDIR/empty-plugins"
cat >"$WORKDIR/empty-plugins/.devrail.yml" <<'YAML'
languages: [bash]
plugins: []
YAML
out="$(docker run --rm \
  -v "$WORKDIR/empty-plugins:/workspace" \
  -v "$REPO_ROOT/Makefile:/workspace/Makefile:ro" \
  -w /workspace \
  "$IMAGE" \
  make _plugins-load 2>&1)" && exit_code=0 || exit_code=$?
assert_eq "0" "$exit_code" "empty-plugins-array exit code"
echo "$out" >"$WORKDIR/empty-plugins.events"
assert_jq "$WORKDIR/empty-plugins.events" 'select(.msg=="no plugins declared")' "empty-array no-plugins event"

echo "==> Integration: valid plugin → loader exits 0, writes cache w/ full manifest"
mkdir -p "$WORKDIR/with-valid"
cat >"$WORKDIR/with-valid/.devrail.yml" <<'YAML'
languages: [elixir]
plugins:
  - source: valid-elixir
    rev: v1.0.0
    languages: [elixir]
YAML
write_matching_lockfile "$WORKDIR/with-valid" valid-elixir valid-elixir v1.0.0
# Mount fixtures at /opt/devrail/plugins so the loader's rev-aware path
# (/opt/devrail/plugins/<slug>/<rev>/plugin.devrail.yml) resolves to the
# fixture (tests/fixtures/plugins/valid-elixir/v1.0.0/plugin.devrail.yml).
# Source URL is the bare slug because basename(slug) == slug and the loader
# only uses basename(source) to build the cache path.
out="$(docker run --rm \
  -v "$WORKDIR/with-valid:/workspace" \
  -v "$REPO_ROOT/Makefile:/workspace/Makefile:ro" \
  -v "$FIXTURE_BASE:/opt/devrail/plugins:ro" \
  -e DEVRAIL_VERSION=1.10.0 \
  -e DEVRAIL_PLUGINS_CACHE=/workspace/cache.yaml \
  -w /workspace \
  "$IMAGE" \
  make _plugins-load 2>&1)" && exit_code=0 || exit_code=$?
assert_eq "0" "$exit_code" "valid-plugin exit code"
echo "$out" >"$WORKDIR/with-valid.events"
assert_jq "$WORKDIR/with-valid.events" 'select(.msg=="plugin loader complete" and .loaded==1 and .failed==0)' "valid-plugin loader-complete event"

# Verify cache contains the FULL manifest content (Story 13.5 contract)
cache_yaml="$WORKDIR/with-valid/cache.yaml"
if [ ! -r "$cache_yaml" ]; then
  echo "FAIL [valid-plugin cache file missing]: expected $cache_yaml" >&2
  exit 1
fi
cache_loaded_count=$(yq -r '.plugins | length' "$cache_yaml")
assert_eq "1" "$cache_loaded_count" "cache plugins count"
cache_lint_cmd=$(yq -r '.plugins[0].targets.lint.cmd' "$cache_yaml")
if [ -z "$cache_lint_cmd" ] || [ "$cache_lint_cmd" = "null" ]; then
  echo "FAIL [cache full-manifest contract]: cache .plugins[0].targets.lint.cmd is missing — Story 13.5 needs the full manifest in the cache, not just metadata" >&2
  yq . "$cache_yaml" >&2 2>/dev/null || cat "$cache_yaml" >&2
  exit 1
fi
cache_source=$(yq -r '.plugins[0].source' "$cache_yaml")
cache_rev=$(yq -r '.plugins[0].rev' "$cache_yaml")
assert_eq "valid-elixir" "$cache_source" "cache resolution metadata: source"
assert_eq "v1.0.0" "$cache_rev" "cache resolution metadata: rev"
echo "    cache contains full manifest + resolution metadata: PASS"

echo "==> Integration: invalid plugin → loader exits 2 with failed counter"
mkdir -p "$WORKDIR/with-invalid"
cat >"$WORKDIR/with-invalid/.devrail.yml" <<'YAML'
languages: [bad-name]
plugins:
  - source: bad-name
    rev: v1.0.0
    languages: [bad-name]
YAML
write_matching_lockfile "$WORKDIR/with-invalid" bad-name bad-name v1.0.0
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

echo "==> Integration: plugin entry missing rev → fails fast at lockfile-verify"
# Story 13.3 made `_plugins-verify` the first prereq of `_plugins-load`. The
# verifier catches missing source/rev before the loader runs, so the failure
# event is now `plugin entry missing source or rev` rather than the loader's
# original `plugin entry missing rev field`. Either is acceptable as a
# fail-fast signal — the test asserts the new path.
mkdir -p "$WORKDIR/missing-rev"
cat >"$WORKDIR/missing-rev/.devrail.yml" <<'YAML'
languages: [elixir]
plugins:
  - source: valid-elixir
    languages: [elixir]
YAML
# No lockfile written — even with one, verifier rejects the missing rev.
out="$(docker run --rm \
  -v "$WORKDIR/missing-rev:/workspace" \
  -v "$REPO_ROOT/Makefile:/workspace/Makefile:ro" \
  -v "$FIXTURE_BASE:/opt/devrail/plugins:ro" \
  -e DEVRAIL_VERSION=1.10.0 \
  -w /workspace \
  "$IMAGE" \
  make _plugins-load 2>&1)" && exit_code=0 || exit_code=$?
assert_eq "2" "$exit_code" "missing-rev exit code"
echo "$out" >"$WORKDIR/missing-rev.events"
assert_jq "$WORKDIR/missing-rev.events" 'select(.level=="error" and (.msg=="plugin entry missing source or rev" or .msg=="lockfile missing"))' "missing-rev error event"

echo "==> All plugin-loader smoke checks passed"
