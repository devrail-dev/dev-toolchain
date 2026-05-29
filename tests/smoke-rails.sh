#!/usr/bin/env bash
# tests/smoke-rails.sh — Rails 7+ smoke test for issues #25, #28, #30, #46, #48
#
# Verifies the image is consumable by Rails 7+ projects out-of-the-box:
#   1. Gemfile with `platforms: %i[mri windows]` parses (needs Bundler 2.6+).
#   2. make _lint scopes to RUBY_PATHS — vendor/bundle/ is NOT scanned.
#   3. `bundle install` succeeds against a Gemfile containing `gem 'debug'`
#      — exercises the psych->libyaml native compile path (issue #28).
#   4. Project .bundle/config wins over the container default (issue #30).
#   5. RUBY_EXEC_FOR detects rspec-rails projects via rspec-core (issue #46).
#   6. docker_network / docker_volumes render the right docker run flags (#48).
#
# Usage: bash tests/smoke-rails.sh
# Env:
#   DEVRAIL_IMAGE  override image name (default: ghcr.io/devrail-dev/dev-toolchain)
#   DEVRAIL_TAG    override image tag  (default: local)

set -euo pipefail

IMAGE="${DEVRAIL_IMAGE:-ghcr.io/devrail-dev/dev-toolchain}:${DEVRAIL_TAG:-local}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$(mktemp -d)"

# bundle install creates root-owned files inside the bind mount. Host-side `rm`
# can't delete them; do the cleanup inside a container instead.
cleanup() {
  if [ -n "${FIXTURE:-}" ] && [ -d "$FIXTURE" ]; then
    docker run --rm -v "$FIXTURE:/cleanup" "$IMAGE" \
      sh -c 'rm -rf /cleanup/* /cleanup/.[!.]* 2>/dev/null || true' >/dev/null 2>&1 || true
    rmdir "$FIXTURE" 2>/dev/null || rm -rf "$FIXTURE" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# --- Build a minimal Rails-shaped fixture ----------------------------------
mkdir -p "$FIXTURE"/{app,lib,vendor/bundle/ruby/3.4.0/gems/noisy/lib}

cat >"$FIXTURE/.devrail.yml" <<'YAML'
languages: [ruby]
YAML

# Gemfile uses the modern `windows` platform alias that bookworm's Ruby 3.1
# Bundler did not understand. Bundler 2.6 (shipped with Ruby 3.4) handles it.
cat >"$FIXTURE/Gemfile" <<'GEMFILE'
source 'https://rubygems.org'
group :development, :test do
  gem 'debug', platforms: %i[mri windows]
end
GEMFILE

# Permissive rubocop config so the fixture's own source isn't graded on style.
cat >"$FIXTURE/.rubocop.yml" <<'RUBOCOP'
AllCops:
  TargetRubyVersion: 3.4
  NewCops: disable
  SuggestExtensions: false
  DisabledByDefault: true
RUBOCOP

cat >"$FIXTURE/app/foo.rb" <<'APP'
# Minimal Ruby module for the Rails smoke test fixture.
module Foo
  def self.bar
    'baz'
  end
end
APP

cat >"$FIXTURE/lib/util.rb" <<'LIB'
# Minimal utility module for the Rails smoke test fixture.
module Util
  def self.greet(name)
    "Hello, #{name}"
  end
end
LIB

# vendor/bundle/ file with intentional reek smells. MUST NOT be scanned —
# its presence in output indicates RUBY_PATHS scoping has regressed.
cat >"$FIXTURE/vendor/bundle/ruby/3.4.0/gems/noisy/lib/noisy.rb" <<'NOISY'
class A
  def x(a, b, c, d, e)
    [1, 2, 3].each { |i| [4, 5].each { |j| puts i + j + a + b + c + d + e } }
  end
end
NOISY

# --- 1) Gemfile must parse with the container's Bundler --------------------
echo "==> Verifying modern Gemfile parses (Bundler 2.6+ understands :windows)"
docker run --rm \
  -v "$FIXTURE:/workspace" -w /workspace "$IMAGE" \
  ruby -e "require 'bundler'; Bundler::Definition.build('Gemfile', nil, nil); puts 'Gemfile parsed OK'"

# --- 2) make _lint must succeed and not touch vendor/bundle/ ---------------
echo "==> Running make _lint against Rails-shaped fixture"
start=$(date +%s)
output=$(docker run --rm \
  -v "$FIXTURE:/workspace" \
  -v "$REPO_ROOT/Makefile:/workspace/Makefile:ro" \
  -w /workspace \
  -e DEVRAIL_FAIL_FAST=0 \
  "$IMAGE" \
  make _lint 2>&1) && exit_code=0 || exit_code=$?
elapsed=$(($(date +%s) - start))

printf '%s\n' "$output"

if [ "$exit_code" -ne 0 ]; then
  echo "FAIL: make _lint exited $exit_code (Rails fixture should pass cleanly)" >&2
  exit 1
fi

if printf '%s' "$output" | grep -q "vendor/bundle/.*noisy"; then
  echo "FAIL: rubocop or reek scanned vendor/bundle/ — RUBY_PATHS scoping regressed" >&2
  exit 1
fi

# Issue #25 reported 245s for the 73K-warning run. With scoping, this should
# be a few seconds. 60s is a generous ceiling that still flags regressions.
if [ "$elapsed" -gt 60 ]; then
  echo "FAIL: make _lint took ${elapsed}s — expected <60s with RUBY_PATHS scope" >&2
  exit 1
fi

echo "==> Rails lint scoping: PASS (completed in ${elapsed}s)"

# --- 3) bundle install must succeed against the Rails-shaped Gemfile -------
# Issue #28: psych 5.x native build needs libyaml-dev headers in the runtime.
# Without them, `debug -> irb -> rdoc -> psych` resolution fails when bundler
# tries to compile psych. This step does a real network install — needs
# rubygems.org reachable from the runner.
echo "==> Running bundle install (needs libyaml-dev for psych native compile)"
bundle_start=$(date +%s)
bundle_output=$(docker run --rm \
  -v "$FIXTURE:/workspace" \
  -w /workspace \
  -e BUNDLE_PATH=/workspace/vendor/bundle \
  "$IMAGE" \
  bundle install --jobs 4 --quiet 2>&1) && bundle_exit=0 || bundle_exit=$?
bundle_elapsed=$(($(date +%s) - bundle_start))

if [ "$bundle_exit" -ne 0 ]; then
  printf '%s\n' "$bundle_output"
  echo "FAIL: bundle install exited $bundle_exit — likely missing libyaml-dev or network issue" >&2
  exit 1
fi

if ! docker run --rm \
  -v "$FIXTURE:/workspace" \
  -w /workspace \
  -e BUNDLE_PATH=/workspace/vendor/bundle \
  "$IMAGE" \
  bundle exec ruby -e "require 'psych'; puts 'psych ' + Psych::VERSION + ' loads OK'" >/dev/null 2>&1; then
  echo "FAIL: psych installed but cannot be required — libyaml runtime/header mismatch" >&2
  exit 1
fi

echo "==> bundle install + psych load: PASS (completed in ${bundle_elapsed}s)"

# --- 4) Project .bundle/config wins when DOCKER_RUN sets the override ------
# Issue #30 Gap A: container's default BUNDLE_APP_CONFIG=/usr/local/bundle
# silently overrides project-local .bundle/config. The Makefile's DOCKER_RUN
# now passes -e BUNDLE_APP_CONFIG=/workspace/.bundle for Ruby projects so the
# project's own config wins.
echo "==> Verifying .bundle/config override (issue #30 Gap A)"
mkdir -p "$FIXTURE/.bundle"
cat >"$FIXTURE/.bundle/config" <<'BUNDLE_CFG'
---
BUNDLE_PATH: "vendor/bundle"
BUNDLE_CFG

bundle_path_seen=$(docker run --rm \
  -v "$FIXTURE:/workspace" \
  -w /workspace \
  -e BUNDLE_APP_CONFIG=/workspace/.bundle \
  "$IMAGE" \
  bundle config get path 2>/dev/null | grep -oE '"[^"]+"' | head -1 | tr -d '"' || echo "")

if [ "$bundle_path_seen" != "vendor/bundle" ]; then
  echo "FAIL: project .bundle/config ignored — bundle path resolved to '$bundle_path_seen', expected 'vendor/bundle'" >&2
  exit 1
fi
echo "==> .bundle/config override: PASS (BUNDLE_PATH = $bundle_path_seen)"

# --- 5) RUBY_EXEC_FOR detects rspec-rails projects (issue #46) -------------
# A Rails app declares only `rspec-rails`; its Gemfile.lock has no bare `rspec`
# line. Keying detection on `rspec` skipped `bundle exec` and ran the
# container's bundled rspec, which activates Ruby 3.4's default gems before
# bundler/setup (the cgi 0.4.2 vs 0.5.1 LoadError). The Makefile now keys on
# `rspec-core` (the runner gem, always present). Probe the real macro from the
# mounted Makefile via `make --eval` — no bundle install / DB needed.
echo "==> Verifying RUBY_EXEC_FOR detects rspec-rails projects (issue #46)"
PROBE46="$FIXTURE/probe46"
mkdir -p "$PROBE46"
cat >"$PROBE46/.devrail.yml" <<'YAML'
languages: [ruby]
YAML
cat >"$PROBE46/Gemfile.lock" <<'LOCK'
GEM
  remote: https://rubygems.org/
  specs:
    rspec-core (3.13.0)
      rspec-support (~> 3.13.0)
    rspec-expectations (3.13.0)
    rspec-rails (6.1.0)
      rspec-core (~> 3.13)
    rspec-support (3.13.0)
LOCK
rspec_exec=$(docker run --rm \
  -v "$PROBE46:/workspace" \
  -v "$REPO_ROOT/Makefile:/workspace/Makefile:ro" \
  -w /workspace "$IMAGE" \
  make --eval='_probe: ; @printf "%s" "$(call RUBY_EXEC_FOR,rspec-core)"' \
  -f /workspace/Makefile _probe 2>/dev/null)
if [ "$rspec_exec" != "bundle exec " ]; then
  echo "FAIL: rspec-rails project resolved exec prefix to '$rspec_exec', expected 'bundle exec '" >&2
  exit 1
fi
# Negative control: a lock with no rspec must NOT force bundle exec — preserves
# the "only bundle exec when the project actually pins the tool" intent.
cat >"$PROBE46/Gemfile.lock" <<'LOCK'
GEM
  remote: https://rubygems.org/
  specs:
    rake (13.2.1)
LOCK
no_rspec_exec=$(docker run --rm \
  -v "$PROBE46:/workspace" \
  -v "$REPO_ROOT/Makefile:/workspace/Makefile:ro" \
  -w /workspace "$IMAGE" \
  make --eval='_probe: ; @printf "%s" "$(call RUBY_EXEC_FOR,rspec-core)"' \
  -f /workspace/Makefile _probe 2>/dev/null)
if [ -n "$no_rspec_exec" ]; then
  echo "FAIL: lockfile without rspec forced exec prefix '$no_rspec_exec', expected empty" >&2
  exit 1
fi
echo "==> rspec-rails detection: PASS"

# --- 6) docker_network + docker_volumes passthrough (issue #48) -----------
# Projects can attach the toolchain container to a sibling-service network and
# mount extra volumes via .devrail.yml. Verify the Makefile renders the flags
# (and that absent keys are a no-op).
echo "==> Verifying docker_network / docker_volumes passthrough (issue #48)"
PROBE48="$FIXTURE/probe48"
mkdir -p "$PROBE48"
cat >"$PROBE48/.devrail.yml" <<'YAML'
languages: [ruby]
docker_network: devrail-smoke-net
docker_volumes:
  - /tmp/fixtures:/workspace/fixtures
  - shared-cache:/cache
YAML
net_flag=$(docker run --rm \
  -v "$PROBE48:/workspace" \
  -v "$REPO_ROOT/Makefile:/workspace/Makefile:ro" \
  -w /workspace "$IMAGE" \
  make --eval='_probe: ; @printf "%s" "$(DEVRAIL_NETWORK_FLAG)"' \
  -f /workspace/Makefile _probe 2>/dev/null)
if [ "$net_flag" != "--network devrail-smoke-net" ]; then
  echo "FAIL: docker_network rendered '$net_flag', expected '--network devrail-smoke-net'" >&2
  exit 1
fi
vol_flags=$(docker run --rm \
  -v "$PROBE48:/workspace" \
  -v "$REPO_ROOT/Makefile:/workspace/Makefile:ro" \
  -w /workspace "$IMAGE" \
  make --eval='_probe: ; @printf "%s" "$(DEVRAIL_VOLUME_FLAGS)"' \
  -f /workspace/Makefile _probe 2>/dev/null)
if [ "$vol_flags" != "-v /tmp/fixtures:/workspace/fixtures -v shared-cache:/cache" ]; then
  echo "FAIL: docker_volumes rendered '$vol_flags', expected '-v /tmp/fixtures:/workspace/fixtures -v shared-cache:/cache'" >&2
  exit 1
fi
# Absent keys must be a no-op (no stray flags leak into DOCKER_RUN).
cat >"$PROBE48/.devrail.yml" <<'YAML'
languages: [ruby]
YAML
empty_flags=$(docker run --rm \
  -v "$PROBE48:/workspace" \
  -v "$REPO_ROOT/Makefile:/workspace/Makefile:ro" \
  -w /workspace "$IMAGE" \
  make --eval='_probe: ; @printf "[%s]" "$(DEVRAIL_NETWORK_FLAG)$(DEVRAIL_VOLUME_FLAGS)"' \
  -f /workspace/Makefile _probe 2>/dev/null)
if [ "$empty_flags" != "[]" ]; then
  echo "FAIL: absent docker_network/docker_volumes rendered '$empty_flags', expected '[]'" >&2
  exit 1
fi
echo "==> docker_network / docker_volumes passthrough: PASS"

echo "==> All Rails smoke checks passed"
