#!/usr/bin/env bash
# tests/test-kotlin-plugin-extraction.sh — Validate the Kotlin reference plugin
#
# Story 13.7 ships `devrail-plugin-kotlin` as the first reference plugin
# extracted from dev-toolchain core. This test validates structural
# parity: the plugin's manifest is accepted by the validator, the
# resolver fetches it cleanly (against a vendored fixture clone), and
# the loader records the expected per-target/gate shape.
#
# Out of scope here: the full docker-build of `devrail-local:<hash>`
# with real ktlint/detekt/gradle downloads. That's a several-minute
# build that's exercised manually by maintainers via `make check` on a
# real Kotlin workspace — NOT a smoke test. See the docs at
# tests/fixtures/kotlin-via-plugin/README.md for the manual check.
#
# Cases:
#   1. Plugin manifest validates against schema_version 1
#   2. Resolver fetches the plugin from a file:// URL → SHA + content
#      hash recorded in .devrail.lock
#   3. Loader populates the plugin cache with the expected name, version,
#      targets, and gates (the parity check vs dev-toolchain's HAS_KOTLIN)
#   4. Loader-cache target shape: lint, format_check, format_fix, test,
#      security all present with non-empty cmd
#
# Usage: bash tests/test-kotlin-plugin-extraction.sh

set -euo pipefail

IMAGE="${DEVRAIL_IMAGE:-ghcr.io/devrail-dev/dev-toolchain}:${DEVRAIL_TAG:-local}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_ROOT="$REPO_ROOT/tests/fixtures/kotlin-via-plugin"
WORKDIR="$(mktemp -d)"

cleanup() {
  if [ -n "${WORKDIR:-}" ] && [ -d "$WORKDIR" ]; then
    docker run --rm -v "$WORKDIR:/cleanup" "$IMAGE" \
      sh -c 'rm -rf /cleanup/* /cleanup/.[!.]* 2>/dev/null || true' >/dev/null 2>&1 || true
    rm -rf "$WORKDIR" 2>/dev/null || true
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

# --- Setup: stage a checked-in copy of the kotlin plugin manifest ---
# We bundle the canonical manifest under tests/fixtures/kotlin-via-plugin/
# so the test is hermetic (no network fetch from
# github.com/devrail-dev/devrail-plugin-kotlin). Maintainers refresh the
# fixture when bumping the upstream plugin.
if [ ! -r "$FIXTURE_ROOT/plugin.devrail.yml" ]; then
  echo "FAIL [setup]: fixture missing at $FIXTURE_ROOT/plugin.devrail.yml" >&2
  echo "       refresh it from github.com/devrail-dev/devrail-plugin-kotlin" >&2
  exit 1
fi

# --- Case 1: validator accepts the manifest ---
echo "==> Case 1: plugin-validator accepts kotlin manifest"
docker run --rm \
  -v "$FIXTURE_ROOT/plugin.devrail.yml:/plugin/plugin.devrail.yml:ro" \
  "$IMAGE" \
  bash /opt/devrail/scripts/plugin-validator.sh /plugin/plugin.devrail.yml ||
  {
    echo "FAIL [case1]: validator rejected kotlin manifest" >&2
    exit 1
  }

# --- Case 2: resolver fetches via file:// URL ---
# Build a local-fs git repo from the fixture and have the resolver
# pin it to v1.0.0.
echo "==> Case 2: resolver fetches kotlin plugin via file:// URL"
mkdir -p "$WORKDIR/case2-fixture" "$WORKDIR/case2-ws" "$WORKDIR/case2-host-cache"
docker run --rm \
  -v "$FIXTURE_ROOT:/src:ro" \
  -v "$WORKDIR/case2-fixture:/repo" \
  "$IMAGE" \
  sh -c '
    set -e
    cp -a /src/. /repo/
    cd /repo
    git init --quiet
    git config user.email "test@example.com"
    git config user.name "Test"
    git config commit.gpgsign false
    git add -A
    git commit --quiet -m "v1.0.0"
    git tag v1.0.0
  '
cat >"$WORKDIR/case2-ws/.devrail.yml" <<YAML
plugins:
  - source: file://$WORKDIR/case2-fixture
    rev: v1.0.0
    languages: [kotlin]
YAML

resolver_out="$(docker run --rm \
  -v "$WORKDIR:$WORKDIR" \
  -v "$WORKDIR/case2-ws:/workspace" \
  -v "$REPO_ROOT/Makefile:/workspace/Makefile:ro" \
  -v "$WORKDIR/case2-host-cache:/opt/devrail/plugins" \
  -e DEVRAIL_VERSION=1.11.0 \
  -w /workspace \
  "$IMAGE" \
  make _plugins-update 2>&1)" || {
  echo "FAIL [case2]: _plugins-update failed" >&2
  echo "$resolver_out" >&2
  exit 1
}
[ -r "$WORKDIR/case2-ws/.devrail.lock" ] || {
  echo "FAIL [case2]: .devrail.lock not written" >&2
  exit 1
}

# Confirm the lockfile has the kotlin plugin with content_hash set.
docker run --rm \
  -v "$WORKDIR/case2-ws:/ws:ro" "$IMAGE" \
  sh -c 'yq -e ".plugins[0].source" /ws/.devrail.lock | grep -q "case2-fixture$"' || {
  echo "FAIL [case2]: lockfile source mismatch" >&2
  cat "$WORKDIR/case2-ws/.devrail.lock" >&2
  exit 1
}
docker run --rm \
  -v "$WORKDIR/case2-ws:/ws:ro" "$IMAGE" \
  sh -c 'yq -e ".plugins[0].content_hash" /ws/.devrail.lock | grep -q "^sha256:"' || {
  echo "FAIL [case2]: content_hash missing or wrong format" >&2
  cat "$WORKDIR/case2-ws/.devrail.lock" >&2
  exit 1
}

# --- Case 3: loader cache contains expected name + version + devrail_min ---
# YAML parsing runs INSIDE the container (mikefarah/yq v4 with strenv);
# the host's `yq` is the kislyuk Python wrapper (jq-based) that lacks
# strenv. Saving the cache to disk and bind-mounting back lets us parse
# from a single docker run.
echo "==> Case 3: loader populates cache with kotlin plugin metadata"
docker run --rm \
  -v "$WORKDIR:$WORKDIR" \
  -v "$WORKDIR/case2-ws:/workspace" \
  -v "$REPO_ROOT/Makefile:/workspace/Makefile:ro" \
  -v "$WORKDIR/case2-host-cache:/opt/devrail/plugins" \
  -e DEVRAIL_VERSION=1.11.0 \
  -w /workspace \
  "$IMAGE" \
  bash -c '
    set -e
    make _plugins-load >&2
    cp /tmp/devrail-plugins-loaded.yaml /workspace/.devrail-loader-cache.yaml
  ' >/dev/null 2>&1

LOADER_CACHE="$WORKDIR/case2-ws/.devrail-loader-cache.yaml"
[ -r "$LOADER_CACHE" ] || {
  echo "FAIL [case3]: loader cache not produced" >&2
  exit 1
}

# Helper that runs yq inside the container against the cache.
yqc() {
  docker run --rm \
    -v "$LOADER_CACHE:/cache:ro" \
    "$IMAGE" \
    yq "$@" /cache
}

loader_name="$(yqc -r '.plugins[0].name')"
loader_version="$(yqc -r '.plugins[0].version')"
loader_min="$(yqc -r '.plugins[0].devrail_min_version')"
assert_eq "kotlin" "$loader_name" "case3 plugin name"
assert_eq "1.0.0" "$loader_version" "case3 plugin version"
assert_eq "1.10.0" "$loader_min" "case3 devrail_min_version"

# --- Case 4: target/gate shape parity with dev-toolchain HAS_KOTLIN blocks ---
echo "==> Case 4: target/gate shape mirrors HAS_KOTLIN behaviour"
for tgt in lint format_check format_fix test security; do
  cmd="$(docker run --rm \
    -v "$LOADER_CACHE:/cache:ro" "$IMAGE" \
    bash -c "TGT='$tgt' yq -r '.plugins[0].targets[strenv(TGT)].cmd // \"\"' /cache")"
  if [ -z "$cmd" ] || [ "$cmd" = "null" ]; then
    echo "FAIL [case4]: target '$tgt' has no cmd in loader cache" >&2
    exit 1
  fi
  gate0="$(docker run --rm \
    -v "$LOADER_CACHE:/cache:ro" "$IMAGE" \
    bash -c "TGT='$tgt' yq -r '.plugins[0].gates[strenv(TGT)][0] // \"\"' /cache")"
  if [ -z "$gate0" ] || [ "$gate0" = "null" ]; then
    echo "FAIL [case4]: target '$tgt' has no gate path in loader cache" >&2
    exit 1
  fi
done

# Specific assertions on the cmd shape — guards regressions where someone
# changes the manifest but doesn't update behaviour parity.
lint_cmd="$(yqc -r '.plugins[0].targets.lint.cmd')"
echo "$lint_cmd" | grep -q "ktlint" || {
  echo "FAIL [case4]: lint cmd missing ktlint, got: $lint_cmd" >&2
  exit 1
}
echo "$lint_cmd" | grep -q "detekt-cli" || {
  echo "FAIL [case4]: lint cmd missing detekt-cli (ktlint AND detekt parity), got: $lint_cmd" >&2
  exit 1
}

echo "==> All kotlin-plugin-extraction smoke checks passed (4/4)"
