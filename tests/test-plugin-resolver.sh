#!/usr/bin/env bash
# tests/test-plugin-resolver.sh — Validate the plugin resolver + lockfile (Story 13.3)
#
# Harness builds a local-filesystem git repo from a fixture tree (no network),
# then drives `make plugins-update` and `_plugins-verify` against `file://` URLs.
#
# Cases covered:
#   1. SHA passthrough — declare a 40-char SHA; lock entry's sha == declared rev
#   2. Tag-to-SHA resolution — declare `v1.0.0`; lock entry's sha matches `git rev-parse v1.0.0`
#   3. Branch rejection — declare `main`; resolver exits 2
#   4. Lockfile determinism — running plugins-update twice produces byte-identical lockfile
#   5. Idempotent fetch — second update doesn't re-clone
#   6. Lockfile-mismatch — flip a rev in .devrail.lock; _plugins-verify exits 2
#   7. Tampering detection — replace cached tree contents; _plugins-verify exits 2
#   8. Missing-lockfile — declare a plugin, delete .devrail.lock; _plugins-verify exits 2
#   9. No-regression — `.devrail.yml` without `plugins:` → _plugins-verify exits 0
#  10. Unreachable source — file:///nonexistent path; resolver exits 2
#  11. Atomic lockfile — failure after one successful resolution leaves prior lockfile intact
#  12. Malformed YAML — yq parse error surfaces as exit 2, not silent success (review fix H1)
#  13. Slug collision — two distinct sources, same basename → fail fast (review fix M2)
#  14. .git-suffixed source URL — basename strips .git; cache path is clean (review fix L2/L6)
#  15. plugins-update no-op when no plugins declared (review fix L4)
#  16. Idempotent fetch verified by cache sentinel mtime stability (review fix L5)
#
# Usage: bash tests/test-plugin-resolver.sh
# Env:
#   DEVRAIL_IMAGE  override image name (default: ghcr.io/devrail-dev/dev-toolchain)
#   DEVRAIL_TAG    override image tag  (default: local)

set -euo pipefail

IMAGE="${DEVRAIL_IMAGE:-ghcr.io/devrail-dev/dev-toolchain}:${DEVRAIL_TAG:-local}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_BASE="${REPO_ROOT}/tests/fixtures/plugin-repos"
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
  local events="$1" filter="$2" context="$3"
  if ! grep -E '^\{' "$events" | jq -e "$filter" >/dev/null 2>&1; then
    echo "FAIL [$context]: jq filter '$filter' did not match any event in:" >&2
    grep -E '^\{' "$events" | jq -c . >&2 2>/dev/null || cat "$events" >&2
    exit 1
  fi
}

# build_local_git_repo <fixture-name> <git-repo-output-dir>
# Initialises a bare-bones git repo from a fixture tree, with one commit
# tagged v1.0.0. Returns the path on stdout. Done inside docker so git config
# stays consistent and host git noise is irrelevant.
build_local_git_repo() {
  local fixture="$1" out="$2"
  mkdir -p "$out"
  docker run --rm \
    -v "$FIXTURE_BASE/$fixture:/src:ro" \
    -v "$out:/repo" \
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
      git checkout --quiet -b main
      git checkout --quiet v1.0.0
    '
}

# resolved_sha <git-repo-path> <ref>
# Returns the SHA the ref resolves to, via docker (avoids host git config).
resolved_sha() {
  docker run --rm -v "$1:/repo:ro" "$IMAGE" \
    sh -c 'cd /repo && git rev-parse '"$2"
}

# run_make <workspace-path> <args...>
# Invokes make in a workspace, mounting the host Makefile read-only and
# wiring DEVRAIL_PLUGINS_DIR + DEVRAIL_VERSION. Also mounts the entire
# $WORKDIR at the same path inside the container so that `file://` URLs
# embedded in fixture .devrail.yml files resolve identically inside and
# outside the container. Echoes combined stderr+stdout. Sets RUN_EXIT.
run_make() {
  local ws="$1"
  shift
  RUN_EXIT=0
  RUN_OUT="$(docker run --rm \
    -v "$WORKDIR:$WORKDIR" \
    -v "$ws:/workspace" \
    -v "$REPO_ROOT/Makefile:/workspace/Makefile:ro" \
    -v "$WORKDIR/plugins-cache:/opt/devrail/plugins" \
    -e DEVRAIL_VERSION=1.10.0 \
    -w /workspace \
    "$IMAGE" \
    make "$@" 2>&1)" || RUN_EXIT=$?
}

# --- Build the local-filesystem git source repos --------------------------
echo "==> Building local-filesystem git repos from fixtures"
build_local_git_repo elixir-v1 "$WORKDIR/elixir-repo"
build_local_git_repo elixir-v1-tampered "$WORKDIR/elixir-tampered-repo"
mkdir -p "$WORKDIR/plugins-cache"

GIT_URL_VALID="file://$WORKDIR/elixir-repo"
SHA_VALID="$(resolved_sha "$WORKDIR/elixir-repo" v1.0.0)"
echo "    valid repo SHA at v1.0.0: $SHA_VALID"

# --- Case 1: tag → SHA resolution -----------------------------------------
echo "==> Case 1: tag → SHA resolution"
mkdir -p "$WORKDIR/case1"
cat >"$WORKDIR/case1/.devrail.yml" <<YAML
languages: [elixir]
plugins:
  - source: $GIT_URL_VALID
    rev: v1.0.0
    languages: [elixir]
YAML
run_make "$WORKDIR/case1" _plugins-update
echo "$RUN_OUT" >"$WORKDIR/case1.log"
assert_eq "0" "$RUN_EXIT" "case1 exit code"
[ -f "$WORKDIR/case1/.devrail.lock" ] || {
  echo "FAIL [case1]: .devrail.lock missing" >&2
  exit 1
}
LOCK_SHA="$(yq -r '.plugins[0].sha' "$WORKDIR/case1/.devrail.lock")"
assert_eq "$SHA_VALID" "$LOCK_SHA" "case1 lockfile SHA"
LOCK_HASH="$(yq -r '.plugins[0].content_hash' "$WORKDIR/case1/.devrail.lock")"
[[ "$LOCK_HASH" =~ ^sha256:[a-f0-9]{64}$ ]] || {
  echo "FAIL [case1]: content_hash malformed: $LOCK_HASH" >&2
  exit 1
}

# --- Case 2: SHA passthrough ----------------------------------------------
echo "==> Case 2: SHA passthrough"
mkdir -p "$WORKDIR/case2"
cat >"$WORKDIR/case2/.devrail.yml" <<YAML
languages: [elixir]
plugins:
  - source: $GIT_URL_VALID
    rev: $SHA_VALID
    languages: [elixir]
YAML
run_make "$WORKDIR/case2" _plugins-update
echo "$RUN_OUT" >"$WORKDIR/case2.log"
assert_eq "0" "$RUN_EXIT" "case2 exit code"
LOCK_SHA="$(yq -r '.plugins[0].sha' "$WORKDIR/case2/.devrail.lock")"
assert_eq "$SHA_VALID" "$LOCK_SHA" "case2 SHA passthrough"

# --- Case 3: branch rejection ---------------------------------------------
echo "==> Case 3: branch rejection"
mkdir -p "$WORKDIR/case3"
cat >"$WORKDIR/case3/.devrail.yml" <<YAML
languages: [elixir]
plugins:
  - source: $GIT_URL_VALID
    rev: main
    languages: [elixir]
YAML
run_make "$WORKDIR/case3" _plugins-update
echo "$RUN_OUT" >"$WORKDIR/case3.log"
assert_eq "2" "$RUN_EXIT" "case3 exit code"
assert_jq "$WORKDIR/case3.log" 'select(.level=="error" and .msg=="branch refs are not allowed")' "case3 branch-rejection event"
[ ! -f "$WORKDIR/case3/.devrail.lock" ] || {
  echo "FAIL [case3]: .devrail.lock should NOT exist after failure" >&2
  exit 1
}

# --- Case 4: lockfile determinism -----------------------------------------
echo "==> Case 4: lockfile determinism"
mkdir -p "$WORKDIR/case4"
cat >"$WORKDIR/case4/.devrail.yml" <<YAML
languages: [elixir]
plugins:
  - source: $GIT_URL_VALID
    rev: v1.0.0
    languages: [elixir]
YAML
run_make "$WORKDIR/case4" _plugins-update
LOCK_FIRST="$(sha256sum "$WORKDIR/case4/.devrail.lock" | cut -d' ' -f1)"
run_make "$WORKDIR/case4" _plugins-update
LOCK_SECOND="$(sha256sum "$WORKDIR/case4/.devrail.lock" | cut -d' ' -f1)"
assert_eq "$LOCK_FIRST" "$LOCK_SECOND" "case4 lockfile determinism"

# --- Case 5: idempotent fetch ---------------------------------------------
# After the first update, the cached tree should already exist. Second update
# should log "plugin already cached" instead of "fetching plugin".
echo "==> Case 5: idempotent fetch"
mkdir -p "$WORKDIR/case5"
cat >"$WORKDIR/case5/.devrail.yml" <<YAML
languages: [elixir]
plugins:
  - source: $GIT_URL_VALID
    rev: v1.0.0
    languages: [elixir]
YAML
run_make "$WORKDIR/case5" _plugins-update >/dev/null
run_make "$WORKDIR/case5" _plugins-update
echo "$RUN_OUT" >"$WORKDIR/case5.log"
assert_jq "$WORKDIR/case5.log" 'select(.level=="info" and .msg=="plugin already cached")' "case5 idempotency event"

# --- Case 6: lockfile mismatch -------------------------------------------
echo "==> Case 6: lockfile mismatch"
mkdir -p "$WORKDIR/case6"
cat >"$WORKDIR/case6/.devrail.yml" <<YAML
languages: [elixir]
plugins:
  - source: $GIT_URL_VALID
    rev: v1.0.0
    languages: [elixir]
YAML
run_make "$WORKDIR/case6" _plugins-update >/dev/null
# Tamper with the lockfile by flipping the rev. Lockfile entries use
# double-quoted YAML scalars (review fix L3), so match the quoted form.
sed -i 's/rev: "v1\.0\.0"/rev: "v9.9.9"/' "$WORKDIR/case6/.devrail.lock"
run_make "$WORKDIR/case6" _plugins-verify
echo "$RUN_OUT" >"$WORKDIR/case6.log"
assert_eq "2" "$RUN_EXIT" "case6 verify exit code"
assert_jq "$WORKDIR/case6.log" 'select(.level=="error" and .msg=="lockfile mismatch")' "case6 mismatch event"

# --- Case 7: tampering detection (cached tree changed) -------------------
echo "==> Case 7: tampering detection"
mkdir -p "$WORKDIR/case7"
cat >"$WORKDIR/case7/.devrail.yml" <<YAML
languages: [elixir]
plugins:
  - source: $GIT_URL_VALID
    rev: v1.0.0
    languages: [elixir]
YAML
run_make "$WORKDIR/case7" _plugins-update >/dev/null
# Replace cached tree contents with the "tampered" fixture (without re-running
# plugins-update, so the lockfile's content_hash records the original tree).
docker run --rm \
  -v "$FIXTURE_BASE/elixir-v1-tampered:/src:ro" \
  -v "$WORKDIR/plugins-cache:/cache" \
  "$IMAGE" \
  sh -c 'rm -rf /cache/elixir-repo/v1.0.0/* /cache/elixir-repo/v1.0.0/.devrail.sha 2>/dev/null; cp -a /src/. /cache/elixir-repo/v1.0.0/'
run_make "$WORKDIR/case7" _plugins-verify
echo "$RUN_OUT" >"$WORKDIR/case7.log"
assert_eq "2" "$RUN_EXIT" "case7 verify exit code"
assert_jq "$WORKDIR/case7.log" 'select(.level=="error" and (.msg | contains("content_hash mismatch")))' "case7 tampering event"

# Re-fetch clean tree for downstream cases (Case 7 left the cache tampered).
run_make "$WORKDIR/case7" _plugins-update >/dev/null

# --- Case 8: missing lockfile --------------------------------------------
echo "==> Case 8: missing lockfile"
mkdir -p "$WORKDIR/case8"
cat >"$WORKDIR/case8/.devrail.yml" <<YAML
languages: [elixir]
plugins:
  - source: $GIT_URL_VALID
    rev: v1.0.0
    languages: [elixir]
YAML
# Note: no .devrail.lock written
run_make "$WORKDIR/case8" _plugins-verify
echo "$RUN_OUT" >"$WORKDIR/case8.log"
assert_eq "2" "$RUN_EXIT" "case8 exit code"
assert_jq "$WORKDIR/case8.log" 'select(.level=="error" and .msg=="lockfile missing")' "case8 missing-lockfile event"

# --- Case 9: no plugins regression ---------------------------------------
echo "==> Case 9: no-plugins regression"
mkdir -p "$WORKDIR/case9"
cat >"$WORKDIR/case9/.devrail.yml" <<'YAML'
languages: [bash]
YAML
run_make "$WORKDIR/case9" _plugins-verify
assert_eq "0" "$RUN_EXIT" "case9 no-plugins exit code"
[ ! -f "$WORKDIR/case9/.devrail.lock" ] || {
  echo "FAIL [case9]: should not require .devrail.lock" >&2
  exit 1
}

# --- Case 10: unreachable source -----------------------------------------
echo "==> Case 10: unreachable source"
mkdir -p "$WORKDIR/case10"
cat >"$WORKDIR/case10/.devrail.yml" <<'YAML'
languages: [elixir]
plugins:
  - source: file:///nonexistent/path/devrail-plugin-elixir
    rev: v1.0.0
    languages: [elixir]
YAML
run_make "$WORKDIR/case10" _plugins-update
echo "$RUN_OUT" >"$WORKDIR/case10.log"
assert_eq "2" "$RUN_EXIT" "case10 exit code"
assert_jq "$WORKDIR/case10.log" 'select(.level=="error" and (.msg=="ref not found at source" or .msg=="git fetch failed"))' "case10 unreachable event"

# --- Case 11: atomic lockfile (partial-failure preserves prior lockfile) -
echo "==> Case 11: atomic lockfile on partial failure"
mkdir -p "$WORKDIR/case11"
cat >"$WORKDIR/case11/.devrail.yml" <<YAML
languages: [elixir]
plugins:
  - source: $GIT_URL_VALID
    rev: v1.0.0
    languages: [elixir]
YAML
run_make "$WORKDIR/case11" _plugins-update >/dev/null
LOCK_GOOD_HASH="$(sha256sum "$WORKDIR/case11/.devrail.lock" | cut -d' ' -f1)"
# Now add a second plugin pointing at an unreachable source. Resolver should
# fail on the second entry without overwriting the existing lockfile.
cat >"$WORKDIR/case11/.devrail.yml" <<YAML
languages: [elixir, bogus]
plugins:
  - source: $GIT_URL_VALID
    rev: v1.0.0
    languages: [elixir]
  - source: file:///nonexistent/devrail-plugin-bogus
    rev: v1.0.0
    languages: [bogus]
YAML
run_make "$WORKDIR/case11" _plugins-update
assert_eq "2" "$RUN_EXIT" "case11 exit code (failure expected)"
LOCK_AFTER_HASH="$(sha256sum "$WORKDIR/case11/.devrail.lock" | cut -d' ' -f1)"
assert_eq "$LOCK_GOOD_HASH" "$LOCK_AFTER_HASH" "case11 atomic lockfile preserved"

# --- Case 12: malformed YAML produces a parse error, not silent success ---
# Review fix H1. Without this, the previous resolver would have read
# `plugins | length` as 0 and exited 0, treating broken YAML as "no plugins".
echo "==> Case 12: malformed YAML in .devrail.yml"
mkdir -p "$WORKDIR/case12"
cat >"$WORKDIR/case12/.devrail.yml" <<'YAML'
languages: [elixir]
plugins:
  - source: not-yaml: ][}{
    rev: v1.0.0
YAML
run_make "$WORKDIR/case12" _plugins-update
echo "$RUN_OUT" >"$WORKDIR/case12.log"
assert_eq "2" "$RUN_EXIT" "case12 exit code"
assert_jq "$WORKDIR/case12.log" 'select(.level=="error" and .msg=="config could not be parsed by yq")' "case12 yq-parse-error event"

# --- Case 13: slug collision between two distinct sources ----------------
# Review fix M2. Two sources with different paths but matching basenames
# would collide on `<plugins-dir>/<slug>/<rev>/`. Detect and reject.
echo "==> Case 13: slug collision detection"
build_local_git_repo elixir-v1 "$WORKDIR/elixir-collide-a"
build_local_git_repo elixir-v1 "$WORKDIR/elixir-collide-b"
mkdir -p "$WORKDIR/case13"
cat >"$WORKDIR/case13/.devrail.yml" <<YAML
languages: [elixir]
plugins:
  - source: file://$WORKDIR/elixir-collide-a/elixir
    rev: v1.0.0
    languages: [elixir]
  - source: file://$WORKDIR/elixir-collide-b/elixir
    rev: v1.0.0
    languages: [elixir-2]
YAML
# Both sources produce slug "elixir" via basename — but the URLs differ.
# Note: the actual git repos are at .../elixir-collide-{a,b}, not .../elixir,
# so resolve_ref will fail too. The slug-collision event must fire BEFORE the
# ref-resolution attempt for the second entry.
run_make "$WORKDIR/case13" _plugins-update
echo "$RUN_OUT" >"$WORKDIR/case13.log"
assert_eq "2" "$RUN_EXIT" "case13 exit code"
assert_jq "$WORKDIR/case13.log" 'select(.level=="error" and .msg=="plugin slug collision")' "case13 slug-collision event"

# --- Case 14: source URL with .git suffix produces a clean slug ----------
# Review fix L2/L6. basename strips the .git suffix so the cache path is
# `<plugins-dir>/<name>/<rev>/`, not `<plugins-dir>/<name>.git/<rev>/`.
echo "==> Case 14: source URL with .git suffix"
mkdir -p "$WORKDIR/elixir-with-git-suffix"
cp -a "$WORKDIR/elixir-repo/.git" "$WORKDIR/elixir-with-git-suffix.git" 2>/dev/null || true
# Build a fresh repo whose URL ends in .git
build_local_git_repo elixir-v1 "$WORKDIR/elixir-bar.git"
mkdir -p "$WORKDIR/case14"
cat >"$WORKDIR/case14/.devrail.yml" <<YAML
languages: [elixir]
plugins:
  - source: file://$WORKDIR/elixir-bar.git
    rev: v1.0.0
    languages: [elixir]
YAML
run_make "$WORKDIR/case14" _plugins-update
echo "$RUN_OUT" >"$WORKDIR/case14.log"
assert_eq "0" "$RUN_EXIT" "case14 exit code"
# Cache files are root-owned 0700 inside docker; check via sidecar container.
if ! docker run --rm -v "$WORKDIR/plugins-cache:/cache:ro" "$IMAGE" \
  sh -c 'test -d /cache/elixir-bar/v1.0.0' >/dev/null 2>&1; then
  echo "FAIL [case14]: expected cache at .../elixir-bar/v1.0.0 (without .git suffix)" >&2
  exit 1
fi

# --- Case 15: _plugins-update no-op when no plugins declared -------------
# Review fix L4. Companion to Case 9 (which tested _plugins-verify).
echo "==> Case 15: _plugins-update no-op with no plugins"
mkdir -p "$WORKDIR/case15"
cat >"$WORKDIR/case15/.devrail.yml" <<'YAML'
languages: [bash]
YAML
run_make "$WORKDIR/case15" _plugins-update
echo "$RUN_OUT" >"$WORKDIR/case15.log"
assert_eq "0" "$RUN_EXIT" "case15 exit code"
assert_jq "$WORKDIR/case15.log" 'select(.level=="info" and (.msg | contains("no plugins declared")))' "case15 no-plugins info event"
[ ! -f "$WORKDIR/case15/.devrail.lock" ] || {
  echo "FAIL [case15]: should not generate .devrail.lock when no plugins declared" >&2
  exit 1
}

# --- Case 16: idempotent fetch verified by cache mtime stability ---------
# Review fix L5. Case 5 only asserted the "plugin already cached" event;
# this case additionally asserts the cached .devrail.sha sentinel mtime
# is stable across re-runs (proves no re-clone happened).
echo "==> Case 16: idempotent fetch leaves cache mtime stable"
mkdir -p "$WORKDIR/case16"
cat >"$WORKDIR/case16/.devrail.yml" <<YAML
languages: [elixir]
plugins:
  - source: $GIT_URL_VALID
    rev: v1.0.0
    languages: [elixir]
YAML
# Cache files are written as root inside docker (mktemp creates 0700 dirs);
# read sentinel mtime via a sidecar docker run rather than from the host.
read_sentinel_mtime() {
  docker run --rm -v "$WORKDIR/plugins-cache:/cache:ro" "$IMAGE" \
    sh -c 'stat -c %Y /cache/elixir-repo/v1.0.0/.devrail.sha 2>/dev/null'
}
run_make "$WORKDIR/case16" _plugins-update >/dev/null
mtime_before="$(read_sentinel_mtime)"
if [ -z "$mtime_before" ]; then
  echo "FAIL [case16]: .devrail.sha sentinel missing after first update" >&2
  exit 1
fi
sleep 1
run_make "$WORKDIR/case16" _plugins-update >/dev/null
mtime_after="$(read_sentinel_mtime)"
assert_eq "$mtime_before" "$mtime_after" "case16 sentinel mtime unchanged across re-update"

echo "==> All plugin-resolver smoke checks passed (16/16)"
