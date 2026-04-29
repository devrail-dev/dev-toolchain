#!/usr/bin/env bash
# tests/smoke-rails.sh — Rails 7+ smoke test for issues #25 and #28
#
# Verifies the image is consumable by Rails 7+ projects out-of-the-box:
#   1. Gemfile with `platforms: %i[mri windows]` parses (needs Bundler 2.6+).
#   2. make _lint scopes to RUBY_PATHS — vendor/bundle/ is NOT scanned.
#   3. `bundle install` succeeds against a Gemfile containing `gem 'debug'`
#      — exercises the psych->libyaml native compile path (issue #28).
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

echo "==> All Rails smoke checks passed"
