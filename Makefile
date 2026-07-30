# DevRail dev-toolchain Makefile — Two-Layer Delegation Pattern
#
# This Makefile implements the DevRail contract for the dev-toolchain container
# repo itself. Public targets run on the host and delegate to the dev-toolchain
# Docker container. Internal targets (prefixed with _) run inside the container.
#
# Usage:
#   make              Show available targets (help)
#   make build        Build the container image locally
#   make check        Run all checks (lint, format, test, security, scan, docs)
#   make lint         Run all linters
#   DEVRAIL_FAIL_FAST=1 make check   Stop on first failure
#
# Configuration is read from .devrail.yml at project root.

# ---------------------------------------------------------------------------
# Variables (overridable via environment)
# ---------------------------------------------------------------------------
# Use bash for all recipes so we can source bash-only libs (plugin-execute.sh
# uses [[, ((, and indirect parameter expansion). Existing POSIX-sh recipes
# remain valid because bash is a superset.
SHELL              := /bin/bash

DEVRAIL_IMAGE      ?= ghcr.io/devrail-dev/dev-toolchain
DEVRAIL_TAG        ?= local
DEVRAIL_FAIL_FAST  ?= 0
DEVRAIL_LOG_FORMAT ?= json
DEVRAIL_CONFIG     := .devrail.yml

# Host-side persistent plugin cache. Bind-mounted into every DOCKER_RUN so
# plugin manifests fetched by `make plugins-update` survive across container
# invocations. Story 13.4. Override via env if you keep caches elsewhere.
DEVRAIL_HOST_PLUGINS_CACHE ?= $(HOME)/.cache/devrail/plugins

# Story 13.4b: when plugins are declared, `make check` etc. build a
# project-local image (devrail-local:<hash-of-dockerfile.devrail>) and use it
# for in-container targets. The tag is written to `.devrail/extended-image-tag`
# by `_extended-image`. DEVRAIL_RESOLVED_IMAGE is recursively-expanded (=) so
# it re-evaluates each time DOCKER_RUN expands — picking up the tag file once
# `_extended-image` has run.
DEVRAIL_RESOLVED_IMAGE = $(if $(and $(wildcard .devrail/extended-image-tag),$(HAS_PLUGINS_DECLARED)),$(shell cat .devrail/extended-image-tag),$(DEVRAIL_IMAGE):$(DEVRAIL_TAG))

# Probe .devrail.yml in a single shell invocation that distinguishes missing
# file, yq parse error, and valid + plugin-count. Without this, a malformed
# `.devrail.yml` would silently fall through as "no plugins" and skip the
# extended-image build (review finding H1). The "error" value is checked
# explicitly inside `_extended-image` rather than via `$(error ...)` so other
# targets (e.g., `_plugins-update`) can still run and let their scripts
# surface the structured parse-error event for the user.
DEVRAIL_PLUGIN_PROBE := $(shell \
	if [ ! -r $(DEVRAIL_CONFIG) ]; then \
		echo "missing"; \
	elif count=$$(yq -r '.plugins // [] | length' $(DEVRAIL_CONFIG) 2>/dev/null); then \
		echo "$$count"; \
	else \
		echo "error"; \
	fi)

# HAS_PLUGINS_DECLARED — set when .devrail.yml has a non-empty `plugins:` list.
# Empty when file is missing, `plugins:` is `[]`/absent, OR yq could not parse
# the file (the "error" case is caught explicitly inside `_extended-image`).
HAS_PLUGINS_DECLARED := $(if $(filter-out missing error 0,$(DEVRAIL_PLUGIN_PROBE)),yes,)

# Read project-specific env vars from .devrail.yml `env:` section and inject
# them as `-e KEY=VALUE` into DOCKER_RUN. Empty/missing section is a no-op.
DEVRAIL_ENV_FLAGS := $(shell yq -r '.env // {} | to_entries | .[] | "-e " + .key + "=" + .value' $(DEVRAIL_CONFIG) 2>/dev/null)

# Read project-specific Docker networking + volume mounts from .devrail.yml and
# inject them into DOCKER_RUN. `docker_network` (single value) attaches the
# toolchain container to a user-defined network so it can reach a sibling
# service container (e.g. a Postgres at hostname `myapp-pg` during `make test`).
# `docker_volumes` (list) mounts extra host paths or named volumes. Both mirror
# the `env:` -> DEVRAIL_ENV_FLAGS pattern; empty/missing sections are no-ops.
# Issue #48.
DEVRAIL_DOCKER_NETWORK := $(shell yq -r '.docker_network // ""' $(DEVRAIL_CONFIG) 2>/dev/null)
DEVRAIL_NETWORK_FLAG   := $(if $(DEVRAIL_DOCKER_NETWORK),--network $(DEVRAIL_DOCKER_NETWORK),)
DEVRAIL_VOLUME_FLAGS   := $(shell yq -r '.docker_volumes // [] | .[] | "-v " + .' $(DEVRAIL_CONFIG) 2>/dev/null)

# HAS_TEST_SERVICES_DECLARED — set when .devrail.yml has a non-empty
# `test.services` list. Mirrors HAS_PLUGINS_DECLARED above: guards
# `_test-services-host-bin`'s extraction AND `_test-services-up`'s
# invocation so a consumer repo that never declares test.services (the
# common case) pays neither the docker create/cp/rm extraction cost nor
# risks invoking a script that was never extracted.
DEVRAIL_TEST_SERVICES_PROBE   := $(shell yq -r '.test.services // [] | length' $(DEVRAIL_CONFIG) 2>/dev/null)
HAS_TEST_SERVICES_DECLARED    := $(if $(filter-out 0,$(DEVRAIL_TEST_SERVICES_PROBE)),yes,)

# Story 15.4: test.services ephemeral containers. Recursively-expanded (=,
# not :=) so these re-evaluate on every DOCKER_RUN expansion — picking up
# the network/env-file that `_test-services-up` (a host-side prerequisite
# of `test:` only) writes under .devrail/test-services/, mirroring the
# DEVRAIL_RESOLVED_IMAGE / _extended-image pattern. A true no-op for every
# target except `test`: nothing else depends on _test-services-up, so
# these files never exist for lint/format/fix/security/scan/docs/etc.
DEVRAIL_TEST_SERVICES_NETWORK_FLAG = $(if $(wildcard .devrail/test-services/network),--network $(shell cat .devrail/test-services/network),)
DEVRAIL_TEST_SERVICES_ENV_FLAG     = $(if $(wildcard .devrail/test-services/env),--env-file .devrail/test-services/env,)

# Ruby lint/format scope. Defaults to the conventional Rails directory set so
# rubocop and reek do not descend into vendor/bundle/ (which can hold tens of
# thousands of files of installed gem source). Override per-project via:
#   RUBY_PATHS="lib spec" make check
# Non-existent paths are filtered out at runtime.
RUBY_PATHS         ?= app lib spec config bin

# Prefer `bundle exec <tool>` ONLY when the project pins that specific tool
# in its Gemfile.lock. Otherwise fall back to the container's bundled tool.
# This gives projects with project-pinned versions consistency with CI without
# breaking projects that just declare `languages: [ruby]` and rely on the
# container's defaults. Issue #30 Gap C.
# Usage in recipes: $(call RUBY_EXEC_FOR,rubocop)rubocop $$ruby_paths
# NOTE: for rspec, detect on `rspec-core` (the actual runner gem) rather than a
# bare `rspec`. A Rails app declares only `rspec-rails`, so its lockfile has no
# bare `rspec` line — keying on that would skip `bundle exec` and run the
# container's bundled rspec, which activates Ruby 3.4's default gems before
# bundler/setup (the `cgi 0.4.2 vs 0.5.1` LoadError). Issue #46.
RUBY_EXEC_FOR = $(if $(and $(wildcard Gemfile.lock),$(shell grep -m1 -E "^[[:space:]]+$(1)[[:space:]]" Gemfile.lock 2>/dev/null)),bundle exec ,)

# ---------------------------------------------------------------------------
# .devrail.yml language detection (runs inside container where yq is available)
# Computed before DOCKER_RUN so HAS_<LANG> can influence container env (e.g.
# BUNDLE_APP_CONFIG override for Ruby projects — issue #30).
# ---------------------------------------------------------------------------
LANGUAGES      := $(shell yq -r '.languages[]' $(DEVRAIL_CONFIG) 2>/dev/null)
HAS_PYTHON     := $(filter python,$(LANGUAGES))
HAS_BASH       := $(filter bash,$(LANGUAGES))
HAS_TERRAFORM  := $(filter terraform,$(LANGUAGES))
HAS_ANSIBLE    := $(filter ansible,$(LANGUAGES))
HAS_RUBY       := $(filter ruby,$(LANGUAGES))
HAS_GO         := $(filter go,$(LANGUAGES))
HAS_JAVASCRIPT := $(filter javascript,$(LANGUAGES))
HAS_RUST       := $(filter rust,$(LANGUAGES))
HAS_SWIFT      := $(filter swift,$(LANGUAGES))
HAS_KOTLIN     := $(filter kotlin,$(LANGUAGES))

# When HAS_RUBY, override the container's default BUNDLE_APP_CONFIG so the
# project's `.bundle/config` (e.g. `BUNDLE_PATH: vendor/bundle`) wins. Without
# this, the container's own `/usr/local/bundle` config silently overrides the
# project's, and bundler can't find project-installed gems (issue #30 Gap A).
RUBY_DOCKER_ENV := $(if $(HAS_RUBY),-e BUNDLE_APP_CONFIG=/workspace/.bundle,)

DOCKER_RUN = docker run --rm \
	-v "$$(pwd):/workspace" \
	-v "$(DEVRAIL_HOST_PLUGINS_CACHE):/opt/devrail/plugins" \
	-w /workspace \
	-e DEVRAIL_FAIL_FAST=$(DEVRAIL_FAIL_FAST) \
	-e DEVRAIL_LOG_FORMAT=$(DEVRAIL_LOG_FORMAT) \
	$(DEVRAIL_ENV_FLAGS) \
	$(RUBY_DOCKER_ENV) \
	$(DEVRAIL_NETWORK_FLAG) \
	$(DEVRAIL_VOLUME_FLAGS) \
	$(DEVRAIL_TEST_SERVICES_NETWORK_FLAG) \
	$(DEVRAIL_TEST_SERVICES_ENV_FLAG) \
	$(DEVRAIL_RESOLVED_IMAGE)

.DEFAULT_GOAL := help

# ---------------------------------------------------------------------------
# .PHONY declarations
# ---------------------------------------------------------------------------
.PHONY: help build lint format fix test security scan docs changelog check install-hooks init release plugins-update
.PHONY: _lint _format _fix _test _security _scan _docs _changelog _check _check-config _init _plugins-update _plugins-verify _ensure-host-cache _generate-dockerfile _extended-image _devrail-host-bin _test-services-up

# ===========================================================================
# Public targets (run on host, delegate to Docker container)
# ===========================================================================

# --- _ensure-host-cache: create the host-side plugin cache dir ---
# Bind-mounted into every DOCKER_RUN; `docker run -v` would create it as root
# if it doesn't exist (with surprising perms), so create it host-side first
# with the user's umask. Idempotent. Story 13.4.
.PHONY: _ensure-host-cache
_ensure-host-cache:
	@mkdir -p "$(DEVRAIL_HOST_PLUGINS_CACHE)"

# --- _devrail-host-bin: extract orchestrator script + libs from container ---
# Story 13.4b/H2: consumer template repos inherit this Makefile but NOT
# `scripts/`, so the host orchestrator must be sourced from the container.
# When the dev-toolchain repo itself runs (scripts/ present locally) we use
# the on-disk copy so changes take effect without a rebuild. Otherwise we
# extract scripts + lib from the resolved core image to .devrail/host-bin/,
# cached and invalidated by image tag (.devrail/host-bin/.image-tag).
_devrail-host-bin:
	@if [ -z "$(HAS_PLUGINS_DECLARED)" ]; then \
		exit 0; \
	fi; \
	if [ -f scripts/plugin-extended-image.sh ]; then \
		exit 0; \
	fi; \
	expected="$(DEVRAIL_IMAGE):$(DEVRAIL_TAG)"; \
	cached=$$(cat .devrail/host-bin/.image-tag 2>/dev/null || true); \
	if [ "$$cached" = "$$expected" ] && \
	   [ -f .devrail/host-bin/scripts/plugin-extended-image.sh ] && \
	   [ -f .devrail/host-bin/lib/log.sh ] && \
	   [ -f .devrail/host-bin/lib/plugin-cache.sh ]; then \
		exit 0; \
	fi; \
	mkdir -p .devrail/host-bin/scripts .devrail/host-bin/lib; \
	echo '{"level":"info","msg":"extracting host orchestrator from container","image":"'"$$expected"'","language":"_plugins"}' >&2; \
	cid=$$(docker create "$$expected" /bin/true) || { \
		echo '{"level":"error","msg":"docker create failed for host-bin extraction","image":"'"$$expected"'","language":"_plugins"}' >&2; \
		exit 2; \
	}; \
	trap 'docker rm "$$cid" >/dev/null 2>&1 || true' EXIT; \
	docker cp "$$cid":/opt/devrail/scripts/plugin-extended-image.sh .devrail/host-bin/scripts/plugin-extended-image.sh && \
	docker cp "$$cid":/opt/devrail/lib/log.sh             .devrail/host-bin/lib/log.sh && \
	docker cp "$$cid":/opt/devrail/lib/plugin-cache.sh    .devrail/host-bin/lib/plugin-cache.sh && \
	chmod +x .devrail/host-bin/scripts/plugin-extended-image.sh && \
	printf '%s\n' "$$expected" > .devrail/host-bin/.image-tag

# --- _extended-image: build the project-local image when plugins declared ---
# Story 13.4b: HOST-side target. When .devrail.yml declares no plugins, this
# is a no-op (DOCKER_RUN keeps using the core image). When plugins ARE
# declared, the orchestrator script generates Dockerfile.devrail, builds
# devrail-local:<hash>, and writes the tag to .devrail/extended-image-tag
# so the recursive DOCKER_RUN picks it up. Cache hits are free.
_extended-image: _ensure-host-cache _devrail-host-bin
	@if [ "$(DEVRAIL_PLUGIN_PROBE)" = "error" ]; then \
		echo '{"level":"error","msg":"config could not be parsed by yq","path":"$(DEVRAIL_CONFIG)","language":"_plugins","script":"_extended-image"}' >&2; \
		exit 2; \
	fi; \
	if [ -n "$(HAS_PLUGINS_DECLARED)" ]; then \
		if [ -f scripts/plugin-extended-image.sh ]; then \
			bash scripts/plugin-extended-image.sh; \
		else \
			DEVRAIL_LIB="$$(pwd)/.devrail/host-bin/lib" \
				bash .devrail/host-bin/scripts/plugin-extended-image.sh; \
		fi; \
	elif [ -f .devrail/extended-image-tag ]; then \
		echo '{"level":"info","msg":"plugins removed; clearing stale extended-image tag","language":"_plugins","script":"_extended-image"}' >&2; \
		rm -f .devrail/extended-image-tag; \
	fi

# --- _test-services-host-bin: extract test-services.sh + lib/log.sh from container ---
# Story 15.4: consumer template repos inherit this Makefile but not
# scripts/, mirroring _devrail-host-bin's pattern exactly (same cache
# file, same docker create/cp/rm shape, same HAS_*_DECLARED upfront guard
# so a repo that never declares test.services — the common case — pays
# no docker create/cp/rm cost at all, not even once per image tag).
# When the dev-toolchain repo itself runs (scripts/ present locally) we
# use the on-disk copy so changes take effect without a rebuild.
# Otherwise extract from the resolved core image to .devrail/host-bin/.
_test-services-host-bin:
	@if [ -z "$(HAS_TEST_SERVICES_DECLARED)" ]; then \
		exit 0; \
	fi; \
	if [ -f scripts/test-services.sh ]; then \
		exit 0; \
	fi; \
	expected="$(DEVRAIL_IMAGE):$(DEVRAIL_TAG)"; \
	cached=$$(cat .devrail/host-bin/.image-tag 2>/dev/null || true); \
	if [ "$$cached" = "$$expected" ] && \
	   [ -f .devrail/host-bin/scripts/test-services.sh ] && \
	   [ -f .devrail/host-bin/lib/log.sh ]; then \
		exit 0; \
	fi; \
	mkdir -p .devrail/host-bin/scripts .devrail/host-bin/lib; \
	echo '{"level":"info","msg":"extracting test-services orchestrator from container","image":"'"$$expected"'","language":"_test-services"}' >&2; \
	cid=$$(docker create "$$expected" /bin/true) || { \
		echo '{"level":"error","msg":"docker create failed for host-bin extraction","image":"'"$$expected"'","language":"_test-services"}' >&2; \
		exit 2; \
	}; \
	trap 'docker rm "$$cid" >/dev/null 2>&1 || true' EXIT; \
	docker cp "$$cid":/opt/devrail/scripts/test-services.sh .devrail/host-bin/scripts/test-services.sh && \
	docker cp "$$cid":/opt/devrail/lib/log.sh                .devrail/host-bin/lib/log.sh && \
	chmod +x .devrail/host-bin/scripts/test-services.sh && \
	printf '%s\n' "$$expected" > .devrail/host-bin/.image-tag

# --- _test-services-up: start declared test.services before `make test` ---
# Story 15.4: HOST-side target, `test:`-only prerequisite. No-op (fast —
# a single yq read) when .devrail.yml has no `test.services`. When
# services ARE declared, starts them and writes network/env state under
# .devrail/test-services/ for DEVRAIL_TEST_SERVICES_NETWORK_FLAG/
# DEVRAIL_TEST_SERVICES_ENV_FLAG to pick up.
_test-services-up: _ensure-host-cache _test-services-host-bin
	@if [ -f scripts/test-services.sh ]; then \
		bash scripts/test-services.sh up; \
	elif [ -z "$(HAS_TEST_SERVICES_DECLARED)" ]; then \
		exit 0; \
	else \
		DEVRAIL_LIB="$$(pwd)/.devrail/host-bin/lib" \
			bash .devrail/host-bin/scripts/test-services.sh up; \
	fi

help: ## Show this help
	@echo "DevRail dev-toolchain — container image build and validation"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

build: ## Build the container image locally
	docker build -t $(DEVRAIL_IMAGE):$(DEVRAIL_TAG) .

changelog: _ensure-host-cache ## Generate CHANGELOG.md from conventional commits
	$(DOCKER_RUN) make _changelog

check: _ensure-host-cache _extended-image ## Run all checks (lint, format, test, security, scan, docs)
	$(DOCKER_RUN) make _check

docs: _ensure-host-cache ## Generate documentation
	$(DOCKER_RUN) make _docs

fix: _ensure-host-cache _extended-image ## Auto-fix formatting issues in-place
	$(DOCKER_RUN) make _fix

format: _ensure-host-cache _extended-image ## Run all formatters
	$(DOCKER_RUN) make _format

install-hooks: ## Install pre-commit hooks
	@if ! command -v python3 >/dev/null 2>&1; then \
		echo "Error: Python 3 is required to install pre-commit. Install Python 3 and try again."; \
		exit 2; \
	fi
	@if ! git rev-parse --git-dir >/dev/null 2>&1; then \
		echo "Error: Not in a git repository. Run 'git init' first."; \
		exit 2; \
	fi
	@if ! command -v pre-commit >/dev/null 2>&1; then \
		echo "Installing pre-commit..."; \
		if command -v pipx >/dev/null 2>&1; then \
			pipx install pre-commit; \
		else \
			pip install --user pre-commit; \
		fi; \
	fi
	@pre-commit install
	@pre-commit install --hook-type commit-msg
	@pre-commit install --hook-type pre-push
	@echo "Pre-commit hooks installed successfully. Hooks will run on commit and push."

init: _ensure-host-cache ## Scaffold config files for declared languages
	$(DOCKER_RUN) make _init

lint: _ensure-host-cache _extended-image ## Run all linters
	$(DOCKER_RUN) make _lint

plugins-update: _ensure-host-cache ## Resolve plugin refs and write .devrail.lock
	$(DOCKER_RUN) make _plugins-update

release: ## Cut a versioned release (usage: make release VERSION=1.6.0)
	@if [ -z "$(VERSION)" ]; then \
		echo "Error: VERSION is required. Usage: make release VERSION=1.6.0"; \
		exit 2; \
	fi
	@bash scripts/release.sh $(VERSION)

scan: _ensure-host-cache _extended-image ## Run universal scanners (trivy, gitleaks)
	$(DOCKER_RUN) make _scan

security: _ensure-host-cache _extended-image ## Run language-specific security scanners
	$(DOCKER_RUN) make _security

test: _ensure-host-cache _extended-image _test-services-up ## Run validation tests
	@run_id="$$(cat .devrail/test-services/run_id 2>/dev/null || true)"; \
	trap '\
		if [ -f scripts/test-services.sh ]; then \
			bash scripts/test-services.sh down "$$run_id"; \
		elif [ -f .devrail/host-bin/scripts/test-services.sh ]; then \
			DEVRAIL_LIB="$$(pwd)/.devrail/host-bin/lib" bash .devrail/host-bin/scripts/test-services.sh down "$$run_id"; \
		fi \
	' EXIT; \
	$(DOCKER_RUN) make _test

# ===========================================================================
# Internal targets (run inside container — do NOT invoke directly)
#
# These targets are invoked by the public targets above via Docker.
# They read .devrail.yml to determine which language-specific tools to run.
# All internal targets follow the run-all-report-all pattern by default,
# switching to fail-fast when DEVRAIL_FAIL_FAST=1 is set.
#
# Exit codes:
#   0 — pass (all tools succeeded or skipped)
#   1 — failure (one or more tools reported issues)
#   2 — misconfiguration (missing .devrail.yml, missing tools, etc.)
#
# Each internal target emits a JSON summary line to stdout:
#   {"target":"<name>","status":"pass|fail|skip","duration_ms":<N>}
# ===========================================================================

_check-config:
	@if [ ! -f "$(DEVRAIL_CONFIG)" ]; then \
		echo '{"target":"config","status":"error","error":"missing .devrail.yml","exit_code":2}'; \
		exit 2; \
	fi

# --- _generate-dockerfile: emit Dockerfile.devrail ---
# Story 13.4b: in-container target. Depends on _plugins-load (which populates
# the loader cache at /tmp/devrail-plugins-loaded.yaml in this container) and
# then runs the generator from Story 13.4a. Writes Dockerfile.devrail to the
# workspace root. No-op when no plugins declared.
.PHONY: _generate-dockerfile
_generate-dockerfile: _plugins-load
	@bash /opt/devrail/scripts/plugin-build-extended-image.sh ./Dockerfile.devrail

# --- _plugins-update: resolve plugin refs and write .devrail.lock ---
# Story 13.3: invoked by `make plugins-update`. Reads `.devrail.yml`,
# resolves each `rev:` to an immutable SHA via `git ls-remote`, fetches the
# plugin tree to the rev-aware cache path, computes content_hash, and writes
# `.devrail.lock` atomically. No-op when no plugins are declared.
_plugins-update: _check-config
	@bash /opt/devrail/scripts/plugin-resolver.sh $(DEVRAIL_CONFIG)

# --- _plugins-verify: lockfile-vs-config consistency check ---
# Story 13.3: prerequisite of _plugins-load on every `make check`. Confirms
# every `.devrail.yml` plugin entry has a matching `.devrail.lock` entry with
# the same rev, and re-computes content_hash on the cached tree to detect
# tag-rebase tampering. No-op when no plugins are declared (regression-safe
# for v1.9.x consumers without `plugins:` in `.devrail.yml`).
_plugins-verify: _check-config
	@bash /opt/devrail/scripts/plugin-lockfile-verify.sh $(DEVRAIL_CONFIG)

# --- _plugins-load: validate every plugin manifest declared in .devrail.yml ---
# Story 13.2: runs as a prerequisite of every language-touching target. Exits 2
# (misconfig) if any manifest is invalid, so no tool runs against a broken
# plugin set. The fetcher (Story 13.3) populates manifest files at the
# rev-versioned cache path:
#   $${DEVRAIL_PLUGINS_DIR:-/opt/devrail/plugins}/<source-slug>/<rev>/plugin.devrail.yml
# Tests override DEVRAIL_PLUGINS_DIR to point at checked-in fixtures.
#
# Cache contract: $${DEVRAIL_PLUGINS_CACHE:-/tmp/devrail-plugins-loaded.yaml}
# is a YAML document with a `plugins:` list. Each entry contains the FULL
# manifest content merged with resolution metadata (source, rev, manifest_path)
# so Story 13.5's execution loop can consume `.targets[]`, `.gates[]`, etc.
# without re-reading the manifest from disk.
.PHONY: _plugins-load
_plugins-load: _plugins-verify
	@plugins_dir="$${DEVRAIL_PLUGINS_DIR:-/opt/devrail/plugins}"; \
	cache_file="$${DEVRAIL_PLUGINS_CACHE:-/tmp/devrail-plugins-loaded.yaml}"; \
	plugin_count=$$(yq -r '.plugins // [] | length' $(DEVRAIL_CONFIG) 2>/dev/null || echo 0); \
	if [ "$$plugin_count" = "0" ]; then \
		echo '{"level":"info","msg":"no plugins declared","language":"_plugins","script":"_plugins-load"}' >&2; \
		printf 'plugins: []\n' >"$$cache_file"; \
		exit 0; \
	fi; \
	echo "{\"level\":\"info\",\"msg\":\"plugin loader started\",\"plugin_count\":$$plugin_count,\"language\":\"_plugins\",\"script\":\"_plugins-load\"}" >&2; \
	loaded=0; failed=0; loaded_names=""; \
	printf 'plugins: []\n' >"$$cache_file"; \
	for i in $$(seq 0 $$((plugin_count - 1))); do \
		source_url=$$(yq -r ".plugins[$$i].source // \"\"" $(DEVRAIL_CONFIG)); \
		rev=$$(yq -r ".plugins[$$i].rev // \"\"" $(DEVRAIL_CONFIG)); \
		if [ -z "$$source_url" ]; then \
			echo "{\"level\":\"error\",\"msg\":\"plugin entry missing source field\",\"index\":$$i,\"language\":\"_plugins\",\"script\":\"_plugins-load\"}" >&2; \
			failed=$$((failed + 1)); \
			continue; \
		fi; \
		if [ -z "$$rev" ]; then \
			echo "{\"level\":\"error\",\"msg\":\"plugin entry missing rev field\",\"index\":$$i,\"source\":\"$$source_url\",\"language\":\"_plugins\",\"script\":\"_plugins-load\"}" >&2; \
			failed=$$((failed + 1)); \
			continue; \
		fi; \
		slug=$$(basename "$$source_url"); \
		manifest="$$plugins_dir/$$slug/$$rev/plugin.devrail.yml"; \
		if [ ! -r "$$manifest" ]; then \
			echo "{\"level\":\"error\",\"msg\":\"plugin manifest not found\",\"plugin\":\"$$slug\",\"rev\":\"$$rev\",\"path\":\"$$manifest\",\"language\":\"_plugins\",\"script\":\"_plugins-load\"}" >&2; \
			failed=$$((failed + 1)); \
			continue; \
		fi; \
		if bash /opt/devrail/scripts/plugin-validator.sh "$$manifest"; then \
			loaded=$$((loaded + 1)); \
			plugin_name=$$(yq -r '.name' "$$manifest"); \
			loaded_names="$${loaded_names}\"$$plugin_name\","; \
			yq -i ".plugins += [load(\"$$manifest\") + {\"source\":\"$$source_url\",\"rev\":\"$$rev\",\"manifest_path\":\"$$manifest\"}]" "$$cache_file"; \
		else \
			failed=$$((failed + 1)); \
		fi; \
	done; \
	echo "{\"level\":\"info\",\"msg\":\"plugin loader complete\",\"loaded\":$$loaded,\"failed\":$$failed,\"plugins\":[$${loaded_names%,}],\"language\":\"_plugins\",\"script\":\"_plugins-load\"}" >&2; \
	if [ "$$failed" -gt 0 ]; then exit 2; fi

# --- _lint: language-specific linting ---
# After the core HAS_<LANG> blocks, plugin targets (Story 13.5) are dispatched
# via lib/plugin-execute.sh. The dispatcher updates overall_exit /
# ran_languages / failed_languages in this recipe's shell scope, so plugin
# results aggregate into the same JSON envelope as core results. The
# DEVRAIL_FAIL_FAST short-circuit pattern is mirrored after the dispatch
# call to keep behaviour symmetric with the per-language blocks.
_lint: _plugins-load
	@. /opt/devrail/lib/plugin-execute.sh; \
	. "$${DEVRAIL_LIB:-/opt/devrail/lib}/project-discover.sh"; \
	start_time=$$(date +%s%3N); \
	overall_exit=0; \
	ran_languages=""; \
	failed_languages=""; \
	if [ -n "$(HAS_PYTHON)" ]; then \
		while IFS= read -r py_root; do \
			if [ "$$py_root" = "." ]; then py_tag="python"; else py_tag="python:$$py_root"; fi; \
			ran_languages="$${ran_languages}\"$$py_tag\","; \
			(cd "$$py_root" && ruff check .) || { overall_exit=1; failed_languages="$${failed_languages}\"$$py_tag\","; }; \
			if [ "$(DEVRAIL_FAIL_FAST)" = "1" ] && [ $$overall_exit -ne 0 ]; then \
				end_time=$$(date +%s%3N); \
				duration=$$((end_time - start_time)); \
				echo "{\"target\":\"lint\",\"status\":\"fail\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"failed\":[$${failed_languages%,}]}"; \
				exit $$overall_exit; \
			fi; \
		done < <(discover_project_roots python); \
	fi; \
	if [ -n "$(HAS_BASH)" ]; then \
		ran_languages="$${ran_languages}\"bash\","; \
		sh_files=$$(find . -name '*.sh' -not -path './.git/*' -not -path './vendor/*' -not -path './node_modules/*' 2>/dev/null); \
		if [ -n "$$sh_files" ]; then \
			echo "$$sh_files" | xargs shellcheck || { overall_exit=1; failed_languages="$${failed_languages}\"bash\","; }; \
		else \
			echo '{"level":"info","msg":"skipping bash lint: no .sh files found","language":"bash"}' >&2; \
		fi; \
		if [ "$(DEVRAIL_FAIL_FAST)" = "1" ] && [ $$overall_exit -ne 0 ]; then \
			end_time=$$(date +%s%3N); \
			duration=$$((end_time - start_time)); \
			echo "{\"target\":\"lint\",\"status\":\"fail\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"failed\":[$${failed_languages%,}]}"; \
			exit $$overall_exit; \
		fi; \
	fi; \
	if [ -n "$(HAS_TERRAFORM)" ]; then \
		ran_languages="$${ran_languages}\"terraform\","; \
		tf_dirs=$$(find . -name '*.tf' -not -path './.git/*' -not -path './.terraform/*' 2>/dev/null | xargs -I{} dirname {} | sort -u); \
		if [ -n "$$tf_dirs" ]; then \
			for dir in $$tf_dirs; do \
				(cd "$$dir" && tflint) || { overall_exit=1; failed_languages="$${failed_languages}\"terraform\","; }; \
			done; \
		else \
			echo '{"level":"info","msg":"skipping terraform lint: no .tf files found","language":"terraform"}' >&2; \
		fi; \
		if [ "$(DEVRAIL_FAIL_FAST)" = "1" ] && [ $$overall_exit -ne 0 ]; then \
			end_time=$$(date +%s%3N); \
			duration=$$((end_time - start_time)); \
			echo "{\"target\":\"lint\",\"status\":\"fail\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"failed\":[$${failed_languages%,}]}"; \
			exit $$overall_exit; \
		fi; \
	fi; \
	if [ -n "$(HAS_ANSIBLE)" ]; then \
		ran_languages="$${ran_languages}\"ansible\","; \
		run_per_project ansible "ansible-lint" || { overall_exit=1; failed_languages="$${failed_languages}\"ansible\","; }; \
		if [ "$(DEVRAIL_FAIL_FAST)" = "1" ] && [ $$overall_exit -ne 0 ]; then \
			end_time=$$(date +%s%3N); \
			duration=$$((end_time - start_time)); \
			echo "{\"target\":\"lint\",\"status\":\"fail\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"failed\":[$${failed_languages%,}]}"; \
			exit $$overall_exit; \
		fi; \
	fi; \
	if [ -n "$(HAS_RUBY)" ]; then \
		ran_languages="$${ran_languages}\"ruby\","; \
		ruby_paths=""; \
		for p in $(RUBY_PATHS); do [ -d "$$p" ] && ruby_paths="$$ruby_paths $$p"; done; \
		ruby_paths=$${ruby_paths# }; \
		if [ -n "$$ruby_paths" ]; then \
			$(call RUBY_EXEC_FOR,rubocop)rubocop $$ruby_paths || { overall_exit=1; failed_languages="$${failed_languages}\"ruby:rubocop\","; }; \
		else \
			echo '{"level":"info","msg":"skipping ruby rubocop lint: none of RUBY_PATHS exist (override with RUBY_PATHS=...)","language":"ruby"}' >&2; \
		fi; \
		if [ "$(DEVRAIL_FAIL_FAST)" = "1" ] && [ $$overall_exit -ne 0 ]; then \
			end_time=$$(date +%s%3N); \
			duration=$$((end_time - start_time)); \
			echo "{\"target\":\"lint\",\"status\":\"fail\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"failed\":[$${failed_languages%,}]}"; \
			exit $$overall_exit; \
		fi; \
		if [ -n "$$ruby_paths" ]; then \
			$(call RUBY_EXEC_FOR,reek)reek $$ruby_paths || { overall_exit=1; failed_languages="$${failed_languages}\"ruby:reek\","; }; \
		fi; \
		if [ "$(DEVRAIL_FAIL_FAST)" = "1" ] && [ $$overall_exit -ne 0 ]; then \
			end_time=$$(date +%s%3N); \
			duration=$$((end_time - start_time)); \
			echo "{\"target\":\"lint\",\"status\":\"fail\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"failed\":[$${failed_languages%,}]}"; \
			exit $$overall_exit; \
		fi; \
	fi; \
	if [ -n "$(HAS_GO)" ]; then \
		while IFS= read -r go_root; do \
			if [ "$$go_root" = "." ]; then go_tag="go"; else go_tag="go:$$go_root"; fi; \
			go_files=$$(find "$$go_root" -name '*.go' -not -path '*/.git/*' -not -path '*/vendor/*' -not -path '*/node_modules/*' 2>/dev/null); \
			if [ -n "$$go_files" ]; then \
				ran_languages="$${ran_languages}\"$$go_tag\","; \
				(cd "$$go_root" && golangci-lint run ./...) || { overall_exit=1; failed_languages="$${failed_languages}\"$$go_tag\","; }; \
			else \
				echo "{\"level\":\"info\",\"msg\":\"skipping go lint: no .go files found\",\"language\":\"go\",\"root\":\"$$go_root\"}" >&2; \
			fi; \
			if [ "$(DEVRAIL_FAIL_FAST)" = "1" ] && [ $$overall_exit -ne 0 ]; then \
				end_time=$$(date +%s%3N); \
				duration=$$((end_time - start_time)); \
				echo "{\"target\":\"lint\",\"status\":\"fail\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"failed\":[$${failed_languages%,}]}"; \
				exit $$overall_exit; \
			fi; \
		done < <(discover_project_roots go); \
	fi; \
	if [ -n "$(HAS_JAVASCRIPT)" ]; then \
		while IFS= read -r js_root; do \
			if [ "$$js_root" = "." ]; then js_tag="javascript"; else js_tag="javascript:$$js_root"; fi; \
			ran_languages="$${ran_languages}\"$$js_tag\","; \
			js_files=$$(find "$$js_root" \( -name '*.js' -o -name '*.jsx' -o -name '*.ts' -o -name '*.tsx' -o -name '*.mjs' -o -name '*.cjs' \) -not -path '*/.git/*' -not -path '*/vendor/*' -not -path '*/node_modules/*' -not -path '*/dist/*' -not -path '*/build/*' 2>/dev/null); \
			if [ -n "$$js_files" ]; then \
				(cd "$$js_root" && eslint .) || { overall_exit=1; failed_languages="$${failed_languages}\"$$js_tag:eslint\","; }; \
			else \
				echo "{\"level\":\"info\",\"msg\":\"skipping javascript eslint lint: no JS/TS files found\",\"language\":\"javascript\",\"root\":\"$$js_root\"}" >&2; \
			fi; \
			if [ "$(DEVRAIL_FAIL_FAST)" = "1" ] && [ $$overall_exit -ne 0 ]; then \
				end_time=$$(date +%s%3N); \
				duration=$$((end_time - start_time)); \
				echo "{\"target\":\"lint\",\"status\":\"fail\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"failed\":[$${failed_languages%,}]}"; \
				exit $$overall_exit; \
			fi; \
			if [ -f "$$js_root/tsconfig.json" ]; then \
				(cd "$$js_root" && tsc --noEmit) || { overall_exit=1; failed_languages="$${failed_languages}\"$$js_tag:tsc\","; }; \
			else \
				echo "{\"level\":\"info\",\"msg\":\"skipping tsc type check: no tsconfig.json found\",\"language\":\"javascript\",\"root\":\"$$js_root\"}" >&2; \
			fi; \
			if [ "$(DEVRAIL_FAIL_FAST)" = "1" ] && [ $$overall_exit -ne 0 ]; then \
				end_time=$$(date +%s%3N); \
				duration=$$((end_time - start_time)); \
				echo "{\"target\":\"lint\",\"status\":\"fail\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"failed\":[$${failed_languages%,}]}"; \
				exit $$overall_exit; \
			fi; \
		done < <(discover_project_roots javascript); \
	fi; \
	if [ -n "$(HAS_RUST)" ]; then \
		while IFS= read -r rust_root; do \
			if [ "$$rust_root" = "." ]; then rust_tag="rust"; else rust_tag="rust:$$rust_root"; fi; \
			rs_files=$$(find "$$rust_root" -name '*.rs' -not -path '*/.git/*' -not -path '*/vendor/*' -not -path '*/target/*' 2>/dev/null); \
			if [ -n "$$rs_files" ]; then \
				ran_languages="$${ran_languages}\"$$rust_tag\","; \
				(cd "$$rust_root" && cargo clippy --all-targets --all-features -- -D warnings) || { overall_exit=1; failed_languages="$${failed_languages}\"$$rust_tag\","; }; \
			else \
				echo "{\"level\":\"info\",\"msg\":\"skipping rust lint: no .rs files found\",\"language\":\"rust\",\"root\":\"$$rust_root\"}" >&2; \
			fi; \
			if [ "$(DEVRAIL_FAIL_FAST)" = "1" ] && [ $$overall_exit -ne 0 ]; then \
				end_time=$$(date +%s%3N); \
				duration=$$((end_time - start_time)); \
				echo "{\"target\":\"lint\",\"status\":\"fail\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"failed\":[$${failed_languages%,}]}"; \
				exit $$overall_exit; \
			fi; \
		done < <(discover_project_roots rust); \
	fi; \
	if [ -n "$(HAS_SWIFT)" ]; then \
		ran_languages="$${ran_languages}\"swift\","; \
		swift_files=$$(find . -name '*.swift' -not -path './.git/*' -not -path './.build/*' -not -path './DerivedData/*' 2>/dev/null); \
		if [ -n "$$swift_files" ]; then \
			swiftlint lint --strict || { overall_exit=1; failed_languages="$${failed_languages}\"swift\","; }; \
		else \
			echo '{"level":"info","msg":"skipping swift lint: no .swift files found","language":"swift"}' >&2; \
		fi; \
		if [ "$(DEVRAIL_FAIL_FAST)" = "1" ] && [ $$overall_exit -ne 0 ]; then \
			end_time=$$(date +%s%3N); \
			duration=$$((end_time - start_time)); \
			echo "{\"target\":\"lint\",\"status\":\"fail\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"failed\":[$${failed_languages%,}]}"; \
			exit $$overall_exit; \
		fi; \
	fi; \
	if [ -n "$(HAS_KOTLIN)" ]; then \
		ran_languages="$${ran_languages}\"kotlin\","; \
		kt_files=$$(find . \( -name '*.kt' -o -name '*.kts' \) -not -path './.git/*' -not -path './build/*' -not -path './.gradle/*' 2>/dev/null); \
		if [ -n "$$kt_files" ]; then \
			ktlint || { overall_exit=1; failed_languages="$${failed_languages}\"kotlin:ktlint\","; }; \
		else \
			echo '{"level":"info","msg":"skipping kotlin lint: no .kt/.kts files found","language":"kotlin"}' >&2; \
		fi; \
		if [ -f "detekt.yml" ] && [ -n "$$kt_files" ]; then \
			detekt-cli --build-upon-default-config --config detekt.yml || { overall_exit=1; failed_languages="$${failed_languages}\"kotlin:detekt\","; }; \
		fi; \
		if [ "$(DEVRAIL_FAIL_FAST)" = "1" ] && [ $$overall_exit -ne 0 ]; then \
			end_time=$$(date +%s%3N); \
			duration=$$((end_time - start_time)); \
			echo "{\"target\":\"lint\",\"status\":\"fail\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"failed\":[$${failed_languages%,}]}"; \
			exit $$overall_exit; \
		fi; \
	fi; \
	kustomize_files=$$(find . -name 'kustomization.yaml' -not -path './.git/*' 2>/dev/null); \
	if [ -n "$$kustomize_files" ]; then \
		ran_languages="$${ran_languages}\"kubernetes:kustomize\","; \
		kustomize_exit=0; \
		for kdir in $$(dirname $$kustomize_files); do \
			kustomize build "$$kdir" 2>/dev/null | kubeconform -strict -summary -output json > /dev/null 2>&1 || { kustomize_exit=1; }; \
		done; \
		if [ $$kustomize_exit -ne 0 ]; then \
			overall_exit=1; \
			failed_languages="$${failed_languages}\"kubernetes:kustomize\","; \
		fi; \
		if [ "$(DEVRAIL_FAIL_FAST)" = "1" ] && [ $$overall_exit -ne 0 ]; then \
			end_time=$$(date +%s%3N); \
			duration=$$((end_time - start_time)); \
			echo "{\"target\":\"lint\",\"status\":\"fail\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"failed\":[$${failed_languages%,}]}"; \
			exit $$overall_exit; \
		fi; \
	fi; \
	dispatch_plugin_target lint; \
	if [ "$(DEVRAIL_FAIL_FAST)" = "1" ] && [ $$overall_exit -ne 0 ]; then \
		end_time=$$(date +%s%3N); \
		duration=$$((end_time - start_time)); \
		echo "{\"target\":\"lint\",\"status\":\"fail\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"failed\":[$${failed_languages%,}]}"; \
		exit $$overall_exit; \
	fi; \
	end_time=$$(date +%s%3N); \
	duration=$$((end_time - start_time)); \
	if [ $$overall_exit -eq 0 ]; then \
		echo "{\"target\":\"lint\",\"status\":\"pass\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}]}"; \
	else \
		echo "{\"target\":\"lint\",\"status\":\"fail\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"failed\":[$${failed_languages%,}]}"; \
	fi; \
	exit $$overall_exit

# --- _format: language-specific format checking ---
_format: _plugins-load
	@. /opt/devrail/lib/plugin-execute.sh; \
	. "$${DEVRAIL_LIB:-/opt/devrail/lib}/project-discover.sh"; \
	start_time=$$(date +%s%3N); \
	overall_exit=0; \
	ran_languages=""; \
	failed_languages=""; \
	if [ -n "$(HAS_PYTHON)" ]; then \
		while IFS= read -r py_root; do \
			if [ "$$py_root" = "." ]; then py_tag="python"; else py_tag="python:$$py_root"; fi; \
			ran_languages="$${ran_languages}\"$$py_tag\","; \
			(cd "$$py_root" && ruff format --check .) || { overall_exit=1; failed_languages="$${failed_languages}\"$$py_tag\","; }; \
			if [ "$(DEVRAIL_FAIL_FAST)" = "1" ] && [ $$overall_exit -ne 0 ]; then \
				end_time=$$(date +%s%3N); \
				duration=$$((end_time - start_time)); \
				echo "{\"target\":\"format\",\"status\":\"fail\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"failed\":[$${failed_languages%,}]}"; \
				exit $$overall_exit; \
			fi; \
		done < <(discover_project_roots python); \
	fi; \
	if [ -n "$(HAS_BASH)" ]; then \
		ran_languages="$${ran_languages}\"bash\","; \
		sh_files=$$(find . -name '*.sh' -not -path './.git/*' -not -path './vendor/*' -not -path './node_modules/*' 2>/dev/null); \
		if [ -n "$$sh_files" ]; then \
			echo "$$sh_files" | xargs shfmt -d || { overall_exit=1; failed_languages="$${failed_languages}\"bash\","; }; \
		else \
			echo '{"level":"info","msg":"skipping bash format: no .sh files found","language":"bash"}' >&2; \
		fi; \
		if [ "$(DEVRAIL_FAIL_FAST)" = "1" ] && [ $$overall_exit -ne 0 ]; then \
			end_time=$$(date +%s%3N); \
			duration=$$((end_time - start_time)); \
			echo "{\"target\":\"format\",\"status\":\"fail\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"failed\":[$${failed_languages%,}]}"; \
			exit $$overall_exit; \
		fi; \
	fi; \
	if [ -n "$(HAS_TERRAFORM)" ]; then \
		ran_languages="$${ran_languages}\"terraform\","; \
		terraform fmt -check -recursive || { overall_exit=1; failed_languages="$${failed_languages}\"terraform\","; }; \
		tg_files=$$(find . -name 'terragrunt.hcl' -not -path './.git/*' -not -path './.terraform/*' 2>/dev/null); \
		if [ -n "$$tg_files" ]; then \
			terragrunt hclfmt --terragrunt-check || { overall_exit=1; failed_languages="$${failed_languages}\"terraform:terragrunt\","; }; \
		fi; \
		if [ "$(DEVRAIL_FAIL_FAST)" = "1" ] && [ $$overall_exit -ne 0 ]; then \
			end_time=$$(date +%s%3N); \
			duration=$$((end_time - start_time)); \
			echo "{\"target\":\"format\",\"status\":\"fail\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"failed\":[$${failed_languages%,}]}"; \
			exit $$overall_exit; \
		fi; \
	fi; \
	if [ -n "$(HAS_ANSIBLE)" ]; then \
		ran_languages="$${ran_languages}\"ansible\","; \
		echo '{"target":"format","language":"ansible","status":"skip","reason":"no formatter configured"}' >&2; \
	fi; \
	if [ -n "$(HAS_RUBY)" ]; then \
		ran_languages="$${ran_languages}\"ruby\","; \
		ruby_paths=""; \
		for p in $(RUBY_PATHS); do [ -d "$$p" ] && ruby_paths="$$ruby_paths $$p"; done; \
		ruby_paths=$${ruby_paths# }; \
		if [ -n "$$ruby_paths" ]; then \
			$(call RUBY_EXEC_FOR,rubocop)rubocop --fail-level error $$ruby_paths || { overall_exit=1; failed_languages="$${failed_languages}\"ruby\","; }; \
		else \
			echo '{"level":"info","msg":"skipping ruby format: none of RUBY_PATHS exist (override with RUBY_PATHS=...)","language":"ruby"}' >&2; \
		fi; \
		if [ "$(DEVRAIL_FAIL_FAST)" = "1" ] && [ $$overall_exit -ne 0 ]; then \
			end_time=$$(date +%s%3N); \
			duration=$$((end_time - start_time)); \
			echo "{\"target\":\"format\",\"status\":\"fail\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"failed\":[$${failed_languages%,}]}"; \
			exit $$overall_exit; \
		fi; \
	fi; \
	if [ -n "$(HAS_GO)" ]; then \
		while IFS= read -r go_root; do \
			if [ "$$go_root" = "." ]; then go_tag="go"; else go_tag="go:$$go_root"; fi; \
			go_files=$$(find "$$go_root" -name '*.go' -not -path '*/.git/*' -not -path '*/vendor/*' -not -path '*/node_modules/*' 2>/dev/null); \
			if [ -n "$$go_files" ]; then \
				ran_languages="$${ran_languages}\"$$go_tag\","; \
				(cd "$$go_root" && gofumpt -d .) || { overall_exit=1; failed_languages="$${failed_languages}\"$$go_tag\","; }; \
			else \
				echo "{\"level\":\"info\",\"msg\":\"skipping go format: no .go files found\",\"language\":\"go\",\"root\":\"$$go_root\"}" >&2; \
			fi; \
			if [ "$(DEVRAIL_FAIL_FAST)" = "1" ] && [ $$overall_exit -ne 0 ]; then \
				end_time=$$(date +%s%3N); \
				duration=$$((end_time - start_time)); \
				echo "{\"target\":\"format\",\"status\":\"fail\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"failed\":[$${failed_languages%,}]}"; \
				exit $$overall_exit; \
			fi; \
		done < <(discover_project_roots go); \
	fi; \
	if [ -n "$(HAS_JAVASCRIPT)" ]; then \
		while IFS= read -r js_root; do \
			if [ "$$js_root" = "." ]; then js_tag="javascript"; else js_tag="javascript:$$js_root"; fi; \
			ran_languages="$${ran_languages}\"$$js_tag\","; \
			js_files=$$(find "$$js_root" \( -name '*.js' -o -name '*.jsx' -o -name '*.ts' -o -name '*.tsx' -o -name '*.mjs' -o -name '*.cjs' \) -not -path '*/.git/*' -not -path '*/vendor/*' -not -path '*/node_modules/*' -not -path '*/dist/*' -not -path '*/build/*' 2>/dev/null); \
			if [ -n "$$js_files" ]; then \
				(cd "$$js_root" && prettier --check .) || { overall_exit=1; failed_languages="$${failed_languages}\"$$js_tag\","; }; \
			else \
				echo "{\"level\":\"info\",\"msg\":\"skipping javascript format: no JS/TS files found\",\"language\":\"javascript\",\"root\":\"$$js_root\"}" >&2; \
			fi; \
			if [ "$(DEVRAIL_FAIL_FAST)" = "1" ] && [ $$overall_exit -ne 0 ]; then \
				end_time=$$(date +%s%3N); \
				duration=$$((end_time - start_time)); \
				echo "{\"target\":\"format\",\"status\":\"fail\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"failed\":[$${failed_languages%,}]}"; \
				exit $$overall_exit; \
			fi; \
		done < <(discover_project_roots javascript); \
	fi; \
	if [ -n "$(HAS_RUST)" ]; then \
		while IFS= read -r rust_root; do \
			if [ "$$rust_root" = "." ]; then rust_tag="rust"; else rust_tag="rust:$$rust_root"; fi; \
			rs_files=$$(find "$$rust_root" -name '*.rs' -not -path '*/.git/*' -not -path '*/vendor/*' -not -path '*/target/*' 2>/dev/null); \
			if [ -n "$$rs_files" ]; then \
				ran_languages="$${ran_languages}\"$$rust_tag\","; \
				(cd "$$rust_root" && cargo fmt --all -- --check) || { overall_exit=1; failed_languages="$${failed_languages}\"$$rust_tag\","; }; \
			else \
				echo "{\"level\":\"info\",\"msg\":\"skipping rust format: no .rs files found\",\"language\":\"rust\",\"root\":\"$$rust_root\"}" >&2; \
			fi; \
			if [ "$(DEVRAIL_FAIL_FAST)" = "1" ] && [ $$overall_exit -ne 0 ]; then \
				end_time=$$(date +%s%3N); \
				duration=$$((end_time - start_time)); \
				echo "{\"target\":\"format\",\"status\":\"fail\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"failed\":[$${failed_languages%,}]}"; \
				exit $$overall_exit; \
			fi; \
		done < <(discover_project_roots rust); \
	fi; \
	if [ -n "$(HAS_SWIFT)" ]; then \
		ran_languages="$${ran_languages}\"swift\","; \
		swift_files=$$(find . -name '*.swift' -not -path './.git/*' -not -path './.build/*' -not -path './DerivedData/*' 2>/dev/null); \
		if [ -n "$$swift_files" ]; then \
			swift-format lint --strict -r . || { overall_exit=1; failed_languages="$${failed_languages}\"swift\","; }; \
		else \
			echo '{"level":"info","msg":"skipping swift format: no .swift files found","language":"swift"}' >&2; \
		fi; \
		if [ "$(DEVRAIL_FAIL_FAST)" = "1" ] && [ $$overall_exit -ne 0 ]; then \
			end_time=$$(date +%s%3N); \
			duration=$$((end_time - start_time)); \
			echo "{\"target\":\"format\",\"status\":\"fail\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"failed\":[$${failed_languages%,}]}"; \
			exit $$overall_exit; \
		fi; \
	fi; \
	if [ -n "$(HAS_KOTLIN)" ]; then \
		ran_languages="$${ran_languages}\"kotlin\","; \
		kt_files=$$(find . \( -name '*.kt' -o -name '*.kts' \) -not -path './.git/*' -not -path './build/*' -not -path './.gradle/*' 2>/dev/null); \
		if [ -n "$$kt_files" ]; then \
			ktlint --format --dry-run || { overall_exit=1; failed_languages="$${failed_languages}\"kotlin\","; }; \
		else \
			echo '{"level":"info","msg":"skipping kotlin format: no .kt/.kts files found","language":"kotlin"}' >&2; \
		fi; \
		if [ "$(DEVRAIL_FAIL_FAST)" = "1" ] && [ $$overall_exit -ne 0 ]; then \
			end_time=$$(date +%s%3N); \
			duration=$$((end_time - start_time)); \
			echo "{\"target\":\"format\",\"status\":\"fail\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"failed\":[$${failed_languages%,}]}"; \
			exit $$overall_exit; \
		fi; \
	fi; \
	dispatch_plugin_target format_check; \
	if [ "$(DEVRAIL_FAIL_FAST)" = "1" ] && [ $$overall_exit -ne 0 ]; then \
		end_time=$$(date +%s%3N); \
		duration=$$((end_time - start_time)); \
		echo "{\"target\":\"format\",\"status\":\"fail\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"failed\":[$${failed_languages%,}]}"; \
		exit $$overall_exit; \
	fi; \
	end_time=$$(date +%s%3N); \
	duration=$$((end_time - start_time)); \
	if [ $$overall_exit -eq 0 ]; then \
		echo "{\"target\":\"format\",\"status\":\"pass\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}]}"; \
	else \
		echo "{\"target\":\"format\",\"status\":\"fail\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"failed\":[$${failed_languages%,}]}"; \
	fi; \
	exit $$overall_exit

# --- _fix: language-specific format fixing (in-place) ---
_fix: _plugins-load
	@. /opt/devrail/lib/plugin-execute.sh; \
	. "$${DEVRAIL_LIB:-/opt/devrail/lib}/project-discover.sh"; \
	start_time=$$(date +%s%3N); \
	overall_exit=0; \
	ran_languages=""; \
	failed_languages=""; \
	if [ -n "$(HAS_PYTHON)" ]; then \
		while IFS= read -r py_root; do \
			if [ "$$py_root" = "." ]; then py_tag="python"; else py_tag="python:$$py_root"; fi; \
			ran_languages="$${ran_languages}\"$$py_tag\","; \
			(cd "$$py_root" && ruff format .) || { overall_exit=1; failed_languages="$${failed_languages}\"$$py_tag\","; }; \
			if [ "$(DEVRAIL_FAIL_FAST)" = "1" ] && [ $$overall_exit -ne 0 ]; then \
				end_time=$$(date +%s%3N); \
				duration=$$((end_time - start_time)); \
				echo "{\"target\":\"fix\",\"status\":\"fail\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"failed\":[$${failed_languages%,}]}"; \
				exit $$overall_exit; \
			fi; \
		done < <(discover_project_roots python); \
	fi; \
	if [ -n "$(HAS_BASH)" ]; then \
		ran_languages="$${ran_languages}\"bash\","; \
		sh_files=$$(find . -name '*.sh' -not -path './.git/*' -not -path './vendor/*' -not -path './node_modules/*' 2>/dev/null); \
		if [ -n "$$sh_files" ]; then \
			echo "$$sh_files" | xargs shfmt -w || { overall_exit=1; failed_languages="$${failed_languages}\"bash\","; }; \
		else \
			echo '{"level":"info","msg":"skipping bash fix: no .sh files found","language":"bash"}' >&2; \
		fi; \
		if [ "$(DEVRAIL_FAIL_FAST)" = "1" ] && [ $$overall_exit -ne 0 ]; then \
			end_time=$$(date +%s%3N); \
			duration=$$((end_time - start_time)); \
			echo "{\"target\":\"fix\",\"status\":\"fail\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"failed\":[$${failed_languages%,}]}"; \
			exit $$overall_exit; \
		fi; \
	fi; \
	if [ -n "$(HAS_TERRAFORM)" ]; then \
		ran_languages="$${ran_languages}\"terraform\","; \
		terraform fmt -recursive || { overall_exit=1; failed_languages="$${failed_languages}\"terraform\","; }; \
		tg_files=$$(find . -name 'terragrunt.hcl' -not -path './.git/*' -not -path './.terraform/*' 2>/dev/null); \
		if [ -n "$$tg_files" ]; then \
			terragrunt hclfmt || { overall_exit=1; failed_languages="$${failed_languages}\"terraform:terragrunt\","; }; \
		fi; \
		if [ "$(DEVRAIL_FAIL_FAST)" = "1" ] && [ $$overall_exit -ne 0 ]; then \
			end_time=$$(date +%s%3N); \
			duration=$$((end_time - start_time)); \
			echo "{\"target\":\"fix\",\"status\":\"fail\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"failed\":[$${failed_languages%,}]}"; \
			exit $$overall_exit; \
		fi; \
	fi; \
	if [ -n "$(HAS_ANSIBLE)" ]; then \
		ran_languages="$${ran_languages}\"ansible\","; \
		echo '{"target":"fix","language":"ansible","status":"skip","reason":"no formatter configured"}' >&2; \
	fi; \
	if [ -n "$(HAS_RUBY)" ]; then \
		ran_languages="$${ran_languages}\"ruby\","; \
		ruby_paths=""; \
		for p in $(RUBY_PATHS); do [ -d "$$p" ] && ruby_paths="$$ruby_paths $$p"; done; \
		ruby_paths=$${ruby_paths# }; \
		if [ -n "$$ruby_paths" ]; then \
			$(call RUBY_EXEC_FOR,rubocop)rubocop -a $$ruby_paths || { overall_exit=1; failed_languages="$${failed_languages}\"ruby\","; }; \
		else \
			echo '{"level":"info","msg":"skipping ruby fix: none of RUBY_PATHS exist (override with RUBY_PATHS=...)","language":"ruby"}' >&2; \
		fi; \
		if [ "$(DEVRAIL_FAIL_FAST)" = "1" ] && [ $$overall_exit -ne 0 ]; then \
			end_time=$$(date +%s%3N); \
			duration=$$((end_time - start_time)); \
			echo "{\"target\":\"fix\",\"status\":\"fail\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"failed\":[$${failed_languages%,}]}"; \
			exit $$overall_exit; \
		fi; \
	fi; \
	if [ -n "$(HAS_GO)" ]; then \
		while IFS= read -r go_root; do \
			if [ "$$go_root" = "." ]; then go_tag="go"; else go_tag="go:$$go_root"; fi; \
			go_files=$$(find "$$go_root" -name '*.go' -not -path '*/.git/*' -not -path '*/vendor/*' -not -path '*/node_modules/*' 2>/dev/null); \
			if [ -n "$$go_files" ]; then \
				ran_languages="$${ran_languages}\"$$go_tag\","; \
				(cd "$$go_root" && gofumpt -w .) || { overall_exit=1; failed_languages="$${failed_languages}\"$$go_tag\","; }; \
			else \
				echo "{\"level\":\"info\",\"msg\":\"skipping go fix: no .go files found\",\"language\":\"go\",\"root\":\"$$go_root\"}" >&2; \
			fi; \
			if [ "$(DEVRAIL_FAIL_FAST)" = "1" ] && [ $$overall_exit -ne 0 ]; then \
				end_time=$$(date +%s%3N); \
				duration=$$((end_time - start_time)); \
				echo "{\"target\":\"fix\",\"status\":\"fail\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"failed\":[$${failed_languages%,}]}"; \
				exit $$overall_exit; \
			fi; \
		done < <(discover_project_roots go); \
	fi; \
	if [ -n "$(HAS_JAVASCRIPT)" ]; then \
		while IFS= read -r js_root; do \
			if [ "$$js_root" = "." ]; then js_tag="javascript"; else js_tag="javascript:$$js_root"; fi; \
			ran_languages="$${ran_languages}\"$$js_tag\","; \
			js_files=$$(find "$$js_root" \( -name '*.js' -o -name '*.jsx' -o -name '*.ts' -o -name '*.tsx' -o -name '*.mjs' -o -name '*.cjs' \) -not -path '*/.git/*' -not -path '*/vendor/*' -not -path '*/node_modules/*' -not -path '*/dist/*' -not -path '*/build/*' 2>/dev/null); \
			if [ -n "$$js_files" ]; then \
				(cd "$$js_root" && prettier --write .) || { overall_exit=1; failed_languages="$${failed_languages}\"$$js_tag\","; }; \
			else \
				echo "{\"level\":\"info\",\"msg\":\"skipping javascript fix: no JS/TS files found\",\"language\":\"javascript\",\"root\":\"$$js_root\"}" >&2; \
			fi; \
			if [ "$(DEVRAIL_FAIL_FAST)" = "1" ] && [ $$overall_exit -ne 0 ]; then \
				end_time=$$(date +%s%3N); \
				duration=$$((end_time - start_time)); \
				echo "{\"target\":\"fix\",\"status\":\"fail\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"failed\":[$${failed_languages%,}]}"; \
				exit $$overall_exit; \
			fi; \
		done < <(discover_project_roots javascript); \
	fi; \
	if [ -n "$(HAS_RUST)" ]; then \
		while IFS= read -r rust_root; do \
			if [ "$$rust_root" = "." ]; then rust_tag="rust"; else rust_tag="rust:$$rust_root"; fi; \
			rs_files=$$(find "$$rust_root" -name '*.rs' -not -path '*/.git/*' -not -path '*/vendor/*' -not -path '*/target/*' 2>/dev/null); \
			if [ -n "$$rs_files" ]; then \
				ran_languages="$${ran_languages}\"$$rust_tag\","; \
				(cd "$$rust_root" && cargo fmt --all) || { overall_exit=1; failed_languages="$${failed_languages}\"$$rust_tag\","; }; \
			else \
				echo "{\"level\":\"info\",\"msg\":\"skipping rust fix: no .rs files found\",\"language\":\"rust\",\"root\":\"$$rust_root\"}" >&2; \
			fi; \
			if [ "$(DEVRAIL_FAIL_FAST)" = "1" ] && [ $$overall_exit -ne 0 ]; then \
				end_time=$$(date +%s%3N); \
				duration=$$((end_time - start_time)); \
				echo "{\"target\":\"fix\",\"status\":\"fail\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"failed\":[$${failed_languages%,}]}"; \
				exit $$overall_exit; \
			fi; \
		done < <(discover_project_roots rust); \
	fi; \
	if [ -n "$(HAS_SWIFT)" ]; then \
		ran_languages="$${ran_languages}\"swift\","; \
		swift_files=$$(find . -name '*.swift' -not -path './.git/*' -not -path './.build/*' -not -path './DerivedData/*' 2>/dev/null); \
		if [ -n "$$swift_files" ]; then \
			swift-format format -i -r . || { overall_exit=1; failed_languages="$${failed_languages}\"swift\","; }; \
		else \
			echo '{"level":"info","msg":"skipping swift fix: no .swift files found","language":"swift"}' >&2; \
		fi; \
		if [ "$(DEVRAIL_FAIL_FAST)" = "1" ] && [ $$overall_exit -ne 0 ]; then \
			end_time=$$(date +%s%3N); \
			duration=$$((end_time - start_time)); \
			echo "{\"target\":\"fix\",\"status\":\"fail\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"failed\":[$${failed_languages%,}]}"; \
			exit $$overall_exit; \
		fi; \
	fi; \
	if [ -n "$(HAS_KOTLIN)" ]; then \
		ran_languages="$${ran_languages}\"kotlin\","; \
		kt_files=$$(find . \( -name '*.kt' -o -name '*.kts' \) -not -path './.git/*' -not -path './build/*' -not -path './.gradle/*' 2>/dev/null); \
		if [ -n "$$kt_files" ]; then \
			ktlint --format || { overall_exit=1; failed_languages="$${failed_languages}\"kotlin\","; }; \
		else \
			echo '{"level":"info","msg":"skipping kotlin fix: no .kt/.kts files found","language":"kotlin"}' >&2; \
		fi; \
		if [ "$(DEVRAIL_FAIL_FAST)" = "1" ] && [ $$overall_exit -ne 0 ]; then \
			end_time=$$(date +%s%3N); \
			duration=$$((end_time - start_time)); \
			echo "{\"target\":\"fix\",\"status\":\"fail\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"failed\":[$${failed_languages%,}]}"; \
			exit $$overall_exit; \
		fi; \
	fi; \
	dispatch_plugin_target format_fix; \
	if [ "$(DEVRAIL_FAIL_FAST)" = "1" ] && [ $$overall_exit -ne 0 ]; then \
		end_time=$$(date +%s%3N); \
		duration=$$((end_time - start_time)); \
		echo "{\"target\":\"fix\",\"status\":\"fail\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"failed\":[$${failed_languages%,}]}"; \
		exit $$overall_exit; \
	fi; \
	dispatch_plugin_target fix; \
	if [ "$(DEVRAIL_FAIL_FAST)" = "1" ] && [ $$overall_exit -ne 0 ]; then \
		end_time=$$(date +%s%3N); \
		duration=$$((end_time - start_time)); \
		echo "{\"target\":\"fix\",\"status\":\"fail\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"failed\":[$${failed_languages%,}]}"; \
		exit $$overall_exit; \
	fi; \
	end_time=$$(date +%s%3N); \
	duration=$$((end_time - start_time)); \
	if [ $$overall_exit -eq 0 ]; then \
		echo "{\"target\":\"fix\",\"status\":\"pass\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}]}"; \
	else \
		echo "{\"target\":\"fix\",\"status\":\"fail\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"failed\":[$${failed_languages%,}]}"; \
	fi; \
	exit $$overall_exit

# --- _test: language-specific test runners ---
_test: _plugins-load
	@. /opt/devrail/lib/plugin-execute.sh; \
	. "$${DEVRAIL_LIB:-/opt/devrail/lib}/project-discover.sh"; \
	. "$${DEVRAIL_LIB:-/opt/devrail/lib}/dependency-install.sh"; \
	start_time=$$(date +%s%3N); \
	overall_exit=0; \
	ran_languages=""; \
	failed_languages=""; \
	skipped_languages=""; \
	if [ -n "$(HAS_PYTHON)" ]; then \
		while IFS= read -r py_root; do \
			if [ "$$py_root" = "." ]; then py_tag="python"; else py_tag="python:$$py_root"; fi; \
			if ! install_project_deps python "$$py_root"; then \
				overall_exit=1; failed_languages="$${failed_languages}\"$$py_tag:install\","; \
			elif ! run_project_setup "$$py_root"; then \
				overall_exit=1; failed_languages="$${failed_languages}\"$$py_tag:setup\","; \
			elif [ -d "$$py_root/tests" ] || find "$$py_root" -name '*_test.py' -o -name 'test_*.py' 2>/dev/null | grep -q .; then \
				ran_languages="$${ran_languages}\"$$py_tag\","; \
				(cd "$$py_root" && pytest) || { overall_exit=1; failed_languages="$${failed_languages}\"$$py_tag\","; }; \
			else \
				skipped_languages="$${skipped_languages}\"$$py_tag\","; \
				echo "{\"level\":\"info\",\"msg\":\"skipping python tests: no test files found\",\"language\":\"python\",\"root\":\"$$py_root\"}" >&2; \
			fi; \
			if [ "$(DEVRAIL_FAIL_FAST)" = "1" ] && [ $$overall_exit -ne 0 ]; then \
				end_time=$$(date +%s%3N); \
				duration=$$((end_time - start_time)); \
				echo "{\"target\":\"test\",\"status\":\"fail\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"failed\":[$${failed_languages%,}],\"skipped\":[$${skipped_languages%,}]}"; \
				exit $$overall_exit; \
			fi; \
		done < <(discover_project_roots python); \
	fi; \
	if [ -n "$(HAS_BASH)" ]; then \
		if find . -name '*.bats' -not -path './.git/*' 2>/dev/null | grep -q .; then \
			ran_languages="$${ran_languages}\"bash\","; \
			bats $$(find . -name '*.bats' -not -path './.git/*') || { overall_exit=1; failed_languages="$${failed_languages}\"bash\","; }; \
		else \
			skipped_languages="$${skipped_languages}\"bash\","; \
			echo '{"level":"info","msg":"skipping bash tests: no .bats files found","language":"bash"}' >&2; \
		fi; \
		if [ "$(DEVRAIL_FAIL_FAST)" = "1" ] && [ $$overall_exit -ne 0 ]; then \
			end_time=$$(date +%s%3N); \
			duration=$$((end_time - start_time)); \
			echo "{\"target\":\"test\",\"status\":\"fail\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"failed\":[$${failed_languages%,}],\"skipped\":[$${skipped_languages%,}]}"; \
			exit $$overall_exit; \
		fi; \
	fi; \
	if [ -n "$(HAS_TERRAFORM)" ]; then \
		if find . -name '*_test.go' -not -path './.git/*' 2>/dev/null | grep -q .; then \
			ran_languages="$${ran_languages}\"terraform\","; \
			(cd tests && go test ./...) || { overall_exit=1; failed_languages="$${failed_languages}\"terraform\","; }; \
		else \
			skipped_languages="$${skipped_languages}\"terraform\","; \
			echo '{"level":"info","msg":"skipping terraform tests: no *_test.go files found","language":"terraform"}' >&2; \
		fi; \
		if [ "$(DEVRAIL_FAIL_FAST)" = "1" ] && [ $$overall_exit -ne 0 ]; then \
			end_time=$$(date +%s%3N); \
			duration=$$((end_time - start_time)); \
			echo "{\"target\":\"test\",\"status\":\"fail\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"failed\":[$${failed_languages%,}],\"skipped\":[$${skipped_languages%,}]}"; \
			exit $$overall_exit; \
		fi; \
	fi; \
	if [ -n "$(HAS_ANSIBLE)" ]; then \
		if [ -d "molecule" ]; then \
			ran_languages="$${ran_languages}\"ansible\","; \
			molecule test || { overall_exit=1; failed_languages="$${failed_languages}\"ansible\","; }; \
		else \
			skipped_languages="$${skipped_languages}\"ansible\","; \
			echo '{"level":"info","msg":"skipping ansible tests: no molecule directory found","language":"ansible"}' >&2; \
		fi; \
		if [ "$(DEVRAIL_FAIL_FAST)" = "1" ] && [ $$overall_exit -ne 0 ]; then \
			end_time=$$(date +%s%3N); \
			duration=$$((end_time - start_time)); \
			echo "{\"target\":\"test\",\"status\":\"fail\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"failed\":[$${failed_languages%,}],\"skipped\":[$${skipped_languages%,}]}"; \
			exit $$overall_exit; \
		fi; \
	fi; \
	if [ -n "$(HAS_RUBY)" ]; then \
		if [ -d "spec" ]; then \
			ran_languages="$${ran_languages}\"ruby\","; \
			if [ -f "config/application.rb" ] && [ -f "Gemfile" ]; then \
				echo '{"level":"info","msg":"detected Rails app — running db:test:prepare before rspec","language":"ruby"}' >&2; \
				if ! bundle exec rails db:test:prepare 2>/tmp/_devrail_rails_db_err; then \
					cat /tmp/_devrail_rails_db_err >&2; \
					echo '{"level":"error","msg":"db:test:prepare failed — ensure your test database is reachable (e.g. start postgres before make test)","language":"ruby"}' >&2; \
					overall_exit=1; failed_languages="$${failed_languages}\"ruby:db-prepare\","; \
				else \
					$(call RUBY_EXEC_FOR,rspec-core)rspec || { overall_exit=1; failed_languages="$${failed_languages}\"ruby\","; }; \
				fi; \
			else \
				$(call RUBY_EXEC_FOR,rspec-core)rspec || { overall_exit=1; failed_languages="$${failed_languages}\"ruby\","; }; \
			fi; \
		else \
			skipped_languages="$${skipped_languages}\"ruby\","; \
			echo '{"level":"info","msg":"skipping ruby tests: no spec/ directory found","language":"ruby"}' >&2; \
		fi; \
		if [ "$(DEVRAIL_FAIL_FAST)" = "1" ] && [ $$overall_exit -ne 0 ]; then \
			end_time=$$(date +%s%3N); \
			duration=$$((end_time - start_time)); \
			echo "{\"target\":\"test\",\"status\":\"fail\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"failed\":[$${failed_languages%,}],\"skipped\":[$${skipped_languages%,}]}"; \
			exit $$overall_exit; \
		fi; \
	fi; \
	if [ -n "$(HAS_GO)" ]; then \
		while IFS= read -r go_root; do \
			if [ "$$go_root" = "." ]; then go_tag="go"; else go_tag="go:$$go_root"; fi; \
			if find "$$go_root" -name '*_test.go' -not -path '*/.git/*' -not -path '*/vendor/*' 2>/dev/null | grep -q .; then \
				ran_languages="$${ran_languages}\"$$go_tag\","; \
				(cd "$$go_root" && go test ./...) || { overall_exit=1; failed_languages="$${failed_languages}\"$$go_tag\","; }; \
			else \
				skipped_languages="$${skipped_languages}\"$$go_tag\","; \
				echo "{\"level\":\"info\",\"msg\":\"skipping go tests: no *_test.go files found\",\"language\":\"go\",\"root\":\"$$go_root\"}" >&2; \
			fi; \
			if [ "$(DEVRAIL_FAIL_FAST)" = "1" ] && [ $$overall_exit -ne 0 ]; then \
				end_time=$$(date +%s%3N); \
				duration=$$((end_time - start_time)); \
				echo "{\"target\":\"test\",\"status\":\"fail\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"failed\":[$${failed_languages%,}],\"skipped\":[$${skipped_languages%,}]}"; \
				exit $$overall_exit; \
			fi; \
		done < <(discover_project_roots go); \
	fi; \
	if [ -n "$(HAS_JAVASCRIPT)" ]; then \
		while IFS= read -r js_root; do \
			if [ "$$js_root" = "." ]; then js_tag="javascript"; else js_tag="javascript:$$js_root"; fi; \
			if ! install_project_deps javascript "$$js_root"; then \
				overall_exit=1; failed_languages="$${failed_languages}\"$$js_tag:install\","; \
			elif ! run_project_setup "$$js_root"; then \
				overall_exit=1; failed_languages="$${failed_languages}\"$$js_tag:setup\","; \
			elif find "$$js_root" \( -name '*.test.*' -o -name '*.spec.*' \) -not -path '*/.git/*' -not -path '*/vendor/*' -not -path '*/node_modules/*' -not -path '*/dist/*' -not -path '*/build/*' 2>/dev/null | grep -q .; then \
				ran_languages="$${ran_languages}\"$$js_tag\","; \
				(cd "$$js_root" && vitest run) || { overall_exit=1; failed_languages="$${failed_languages}\"$$js_tag\","; }; \
			else \
				skipped_languages="$${skipped_languages}\"$$js_tag\","; \
				echo "{\"level\":\"info\",\"msg\":\"skipping javascript tests: no *.test.* or *.spec.* files found\",\"language\":\"javascript\",\"root\":\"$$js_root\"}" >&2; \
			fi; \
			if [ "$(DEVRAIL_FAIL_FAST)" = "1" ] && [ $$overall_exit -ne 0 ]; then \
				end_time=$$(date +%s%3N); \
				duration=$$((end_time - start_time)); \
				echo "{\"target\":\"test\",\"status\":\"fail\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"failed\":[$${failed_languages%,}],\"skipped\":[$${skipped_languages%,}]}"; \
				exit $$overall_exit; \
			fi; \
		done < <(discover_project_roots javascript); \
	fi; \
	if [ -n "$(HAS_RUST)" ]; then \
		while IFS= read -r rust_root; do \
			if [ "$$rust_root" = "." ]; then rust_tag="rust"; else rust_tag="rust:$$rust_root"; fi; \
			rs_files=$$(find "$$rust_root" -name '*.rs' -not -path '*/.git/*' -not -path '*/vendor/*' -not -path '*/target/*' 2>/dev/null); \
			if [ -n "$$rs_files" ] && [ -f "$$rust_root/Cargo.toml" ]; then \
				ran_languages="$${ran_languages}\"$$rust_tag\","; \
				(cd "$$rust_root" && cargo test --all-targets) || { overall_exit=1; failed_languages="$${failed_languages}\"$$rust_tag\","; }; \
			else \
				skipped_languages="$${skipped_languages}\"$$rust_tag\","; \
				echo "{\"level\":\"info\",\"msg\":\"skipping rust tests: no .rs files or Cargo.toml found\",\"language\":\"rust\",\"root\":\"$$rust_root\"}" >&2; \
			fi; \
			if [ "$(DEVRAIL_FAIL_FAST)" = "1" ] && [ $$overall_exit -ne 0 ]; then \
				end_time=$$(date +%s%3N); \
				duration=$$((end_time - start_time)); \
				echo "{\"target\":\"test\",\"status\":\"fail\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"failed\":[$${failed_languages%,}],\"skipped\":[$${skipped_languages%,}]}"; \
				exit $$overall_exit; \
			fi; \
		done < <(discover_project_roots rust); \
	fi; \
	if [ -n "$(HAS_SWIFT)" ]; then \
		swift_files=$$(find . -name '*.swift' -not -path './.git/*' -not -path './.build/*' -not -path './DerivedData/*' 2>/dev/null); \
		if [ -n "$$swift_files" ] && [ -f "Package.swift" ]; then \
			ran_languages="$${ran_languages}\"swift\","; \
			swift test || { overall_exit=1; failed_languages="$${failed_languages}\"swift\","; }; \
		else \
			skipped_languages="$${skipped_languages}\"swift\","; \
			echo '{"level":"info","msg":"skipping swift tests: no .swift files or Package.swift found","language":"swift"}' >&2; \
		fi; \
		if [ "$(DEVRAIL_FAIL_FAST)" = "1" ] && [ $$overall_exit -ne 0 ]; then \
			end_time=$$(date +%s%3N); \
			duration=$$((end_time - start_time)); \
			echo "{\"target\":\"test\",\"status\":\"fail\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"failed\":[$${failed_languages%,}],\"skipped\":[$${skipped_languages%,}]}"; \
			exit $$overall_exit; \
		fi; \
	fi; \
	if [ -n "$(HAS_KOTLIN)" ]; then \
		if [ -f "build.gradle.kts" ] || [ -f "build.gradle" ]; then \
			ran_languages="$${ran_languages}\"kotlin\","; \
			gradle test || { overall_exit=1; failed_languages="$${failed_languages}\"kotlin\","; }; \
		else \
			skipped_languages="$${skipped_languages}\"kotlin\","; \
			echo '{"level":"info","msg":"skipping kotlin tests: no build.gradle.kts or build.gradle found","language":"kotlin"}' >&2; \
		fi; \
		if [ "$(DEVRAIL_FAIL_FAST)" = "1" ] && [ $$overall_exit -ne 0 ]; then \
			end_time=$$(date +%s%3N); \
			duration=$$((end_time - start_time)); \
			echo "{\"target\":\"test\",\"status\":\"fail\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"failed\":[$${failed_languages%,}],\"skipped\":[$${skipped_languages%,}]}"; \
			exit $$overall_exit; \
		fi; \
	fi; \
	dispatch_plugin_target test; \
	if [ "$(DEVRAIL_FAIL_FAST)" = "1" ] && [ $$overall_exit -ne 0 ]; then \
		end_time=$$(date +%s%3N); \
		duration=$$((end_time - start_time)); \
		echo "{\"target\":\"test\",\"status\":\"fail\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"failed\":[$${failed_languages%,}],\"skipped\":[$${skipped_languages%,}]}"; \
		exit $$overall_exit; \
	fi; \
	end_time=$$(date +%s%3N); \
	duration=$$((end_time - start_time)); \
	if [ -z "$${ran_languages}" ] && [ -n "$${skipped_languages}" ]; then \
		echo "{\"target\":\"test\",\"status\":\"skip\",\"reason\":\"no tests found\",\"duration_ms\":$$duration,\"skipped\":[$${skipped_languages%,}]}"; \
	elif [ $$overall_exit -eq 0 ]; then \
		echo "{\"target\":\"test\",\"status\":\"pass\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"skipped\":[$${skipped_languages%,}]}"; \
	else \
		echo "{\"target\":\"test\",\"status\":\"fail\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"failed\":[$${failed_languages%,}],\"skipped\":[$${skipped_languages%,}]}"; \
	fi; \
	exit $$overall_exit

# --- _security: language-specific security scanners ---
_security: _plugins-load
	@. /opt/devrail/lib/plugin-execute.sh; \
	. "$${DEVRAIL_LIB:-/opt/devrail/lib}/project-discover.sh"; \
	start_time=$$(date +%s%3N); \
	overall_exit=0; \
	ran_languages=""; \
	failed_languages=""; \
	skipped_languages=""; \
	if [ -n "$(HAS_PYTHON)" ]; then \
		while IFS= read -r py_root; do \
			if [ "$$py_root" = "." ]; then py_tag="python"; else py_tag="python:$$py_root"; fi; \
			ran_languages="$${ran_languages}\"$$py_tag\","; \
			(cd "$$py_root" && bandit -r . -q) || { overall_exit=1; failed_languages="$${failed_languages}\"$$py_tag:bandit\","; }; \
			if [ "$(DEVRAIL_FAIL_FAST)" = "1" ] && [ $$overall_exit -ne 0 ]; then \
				end_time=$$(date +%s%3N); \
				duration=$$((end_time - start_time)); \
				echo "{\"target\":\"security\",\"status\":\"fail\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"failed\":[$${failed_languages%,}]}"; \
				exit $$overall_exit; \
			fi; \
			(cd "$$py_root" && semgrep --config auto . --quiet 2>/dev/null) || { overall_exit=1; failed_languages="$${failed_languages}\"$$py_tag:semgrep\","; }; \
			if [ "$(DEVRAIL_FAIL_FAST)" = "1" ] && [ $$overall_exit -ne 0 ]; then \
				end_time=$$(date +%s%3N); \
				duration=$$((end_time - start_time)); \
				echo "{\"target\":\"security\",\"status\":\"fail\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"failed\":[$${failed_languages%,}]}"; \
				exit $$overall_exit; \
			fi; \
		done < <(discover_project_roots python); \
	fi; \
	if [ -n "$(HAS_BASH)" ]; then \
		skipped_languages="$${skipped_languages}\"bash\","; \
		echo '{"level":"info","msg":"skipping bash security: no language-specific scanner","language":"bash"}' >&2; \
	fi; \
	if [ -n "$(HAS_TERRAFORM)" ]; then \
		ran_languages="$${ran_languages}\"terraform\","; \
		trivy config --exit-code 1 . || { overall_exit=1; failed_languages="$${failed_languages}\"terraform:trivy-config\","; }; \
		if [ "$(DEVRAIL_FAIL_FAST)" = "1" ] && [ $$overall_exit -ne 0 ]; then \
			end_time=$$(date +%s%3N); \
			duration=$$((end_time - start_time)); \
			echo "{\"target\":\"security\",\"status\":\"fail\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"failed\":[$${failed_languages%,}]}"; \
			exit $$overall_exit; \
		fi; \
		checkov -d . --quiet || { overall_exit=1; failed_languages="$${failed_languages}\"terraform:checkov\","; }; \
		if [ "$(DEVRAIL_FAIL_FAST)" = "1" ] && [ $$overall_exit -ne 0 ]; then \
			end_time=$$(date +%s%3N); \
			duration=$$((end_time - start_time)); \
			echo "{\"target\":\"security\",\"status\":\"fail\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"failed\":[$${failed_languages%,}]}"; \
			exit $$overall_exit; \
		fi; \
	fi; \
	if [ -n "$(HAS_ANSIBLE)" ]; then \
		skipped_languages="$${skipped_languages}\"ansible\","; \
		echo '{"level":"info","msg":"skipping ansible security: no language-specific scanner","language":"ansible"}' >&2; \
	fi; \
	if [ -n "$(HAS_RUBY)" ]; then \
		ran_languages="$${ran_languages}\"ruby\","; \
		if [ -f "config/application.rb" ]; then \
			$(call RUBY_EXEC_FOR,brakeman)brakeman -q || { overall_exit=1; failed_languages="$${failed_languages}\"ruby:brakeman\","; }; \
		else \
			echo '{"level":"info","msg":"skipping brakeman: not a Rails application","language":"ruby"}' >&2; \
		fi; \
		if [ "$(DEVRAIL_FAIL_FAST)" = "1" ] && [ $$overall_exit -ne 0 ]; then \
			end_time=$$(date +%s%3N); \
			duration=$$((end_time - start_time)); \
			echo "{\"target\":\"security\",\"status\":\"fail\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"failed\":[$${failed_languages%,}]}"; \
			exit $$overall_exit; \
		fi; \
		if [ -f "Gemfile.lock" ]; then \
			$(call RUBY_EXEC_FOR,bundler-audit)bundler-audit check || { overall_exit=1; failed_languages="$${failed_languages}\"ruby:bundler-audit\","; }; \
		else \
			echo '{"level":"info","msg":"skipping bundler-audit: no Gemfile.lock found","language":"ruby"}' >&2; \
		fi; \
		if [ "$(DEVRAIL_FAIL_FAST)" = "1" ] && [ $$overall_exit -ne 0 ]; then \
			end_time=$$(date +%s%3N); \
			duration=$$((end_time - start_time)); \
			echo "{\"target\":\"security\",\"status\":\"fail\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"failed\":[$${failed_languages%,}]}"; \
			exit $$overall_exit; \
		fi; \
	fi; \
	if [ -n "$(HAS_GO)" ]; then \
		while IFS= read -r go_root; do \
			if [ "$$go_root" = "." ]; then go_tag="go"; else go_tag="go:$$go_root"; fi; \
			if [ -f "$$go_root/go.sum" ]; then \
				ran_languages="$${ran_languages}\"$$go_tag\","; \
				(cd "$$go_root" && govulncheck ./...) || { overall_exit=1; failed_languages="$${failed_languages}\"$$go_tag:govulncheck\","; }; \
			else \
				skipped_languages="$${skipped_languages}\"$$go_tag\","; \
				echo "{\"level\":\"info\",\"msg\":\"skipping govulncheck: no go.sum found\",\"language\":\"go\",\"root\":\"$$go_root\"}" >&2; \
			fi; \
			if [ "$(DEVRAIL_FAIL_FAST)" = "1" ] && [ $$overall_exit -ne 0 ]; then \
				end_time=$$(date +%s%3N); \
				duration=$$((end_time - start_time)); \
				echo "{\"target\":\"security\",\"status\":\"fail\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"failed\":[$${failed_languages%,}]}"; \
				exit $$overall_exit; \
			fi; \
		done < <(discover_project_roots go); \
	fi; \
	if [ -n "$(HAS_JAVASCRIPT)" ]; then \
		while IFS= read -r js_root; do \
			if [ "$$js_root" = "." ]; then js_tag="javascript"; else js_tag="javascript:$$js_root"; fi; \
			if [ -f "$$js_root/package-lock.json" ]; then \
				ran_languages="$${ran_languages}\"$$js_tag\","; \
				(cd "$$js_root" && npm audit --audit-level=moderate) || { overall_exit=1; failed_languages="$${failed_languages}\"$$js_tag:npm-audit\","; }; \
			else \
				skipped_languages="$${skipped_languages}\"$$js_tag\","; \
				echo "{\"level\":\"info\",\"msg\":\"skipping npm audit: no package-lock.json found\",\"language\":\"javascript\",\"root\":\"$$js_root\"}" >&2; \
			fi; \
			if [ "$(DEVRAIL_FAIL_FAST)" = "1" ] && [ $$overall_exit -ne 0 ]; then \
				end_time=$$(date +%s%3N); \
				duration=$$((end_time - start_time)); \
				echo "{\"target\":\"security\",\"status\":\"fail\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"failed\":[$${failed_languages%,}]}"; \
				exit $$overall_exit; \
			fi; \
		done < <(discover_project_roots javascript); \
	fi; \
	if [ -n "$(HAS_RUST)" ]; then \
		while IFS= read -r rust_root; do \
			if [ "$$rust_root" = "." ]; then rust_tag="rust"; else rust_tag="rust:$$rust_root"; fi; \
			if [ -f "$$rust_root/Cargo.lock" ]; then \
				ran_languages="$${ran_languages}\"$$rust_tag\","; \
				(cd "$$rust_root" && cargo audit) || { overall_exit=1; failed_languages="$${failed_languages}\"$$rust_tag:cargo-audit\","; }; \
			else \
				skipped_languages="$${skipped_languages}\"$$rust_tag:cargo-audit\","; \
				echo "{\"level\":\"info\",\"msg\":\"skipping cargo audit: no Cargo.lock found\",\"language\":\"rust\",\"root\":\"$$rust_root\"}" >&2; \
			fi; \
			if [ "$(DEVRAIL_FAIL_FAST)" = "1" ] && [ $$overall_exit -ne 0 ]; then \
				end_time=$$(date +%s%3N); \
				duration=$$((end_time - start_time)); \
				echo "{\"target\":\"security\",\"status\":\"fail\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"failed\":[$${failed_languages%,}]}"; \
				exit $$overall_exit; \
			fi; \
			if [ -f "$$rust_root/deny.toml" ]; then \
				(cd "$$rust_root" && cargo deny check) || { overall_exit=1; failed_languages="$${failed_languages}\"$$rust_tag:cargo-deny\","; }; \
			else \
				echo "{\"level\":\"info\",\"msg\":\"skipping cargo deny: no deny.toml found\",\"language\":\"rust\",\"root\":\"$$rust_root\"}" >&2; \
			fi; \
			if [ "$(DEVRAIL_FAIL_FAST)" = "1" ] && [ $$overall_exit -ne 0 ]; then \
				end_time=$$(date +%s%3N); \
				duration=$$((end_time - start_time)); \
				echo "{\"target\":\"security\",\"status\":\"fail\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"failed\":[$${failed_languages%,}]}"; \
				exit $$overall_exit; \
			fi; \
		done < <(discover_project_roots rust); \
	fi; \
	if [ -n "$(HAS_SWIFT)" ]; then \
		skipped_languages="$${skipped_languages}\"swift\","; \
		echo '{"level":"info","msg":"skipping swift security: no language-specific scanner","language":"swift"}' >&2; \
	fi; \
	if [ -n "$(HAS_KOTLIN)" ]; then \
		if [ -f "build.gradle.kts" ] || [ -f "build.gradle" ]; then \
			ran_languages="$${ran_languages}\"kotlin\","; \
			gradle dependencyCheckAnalyze || { overall_exit=1; failed_languages="$${failed_languages}\"kotlin:owasp\","; }; \
		else \
			skipped_languages="$${skipped_languages}\"kotlin\","; \
			echo '{"level":"info","msg":"skipping kotlin security: no build.gradle.kts or build.gradle found","language":"kotlin"}' >&2; \
		fi; \
		if [ "$(DEVRAIL_FAIL_FAST)" = "1" ] && [ $$overall_exit -ne 0 ]; then \
			end_time=$$(date +%s%3N); \
			duration=$$((end_time - start_time)); \
			echo "{\"target\":\"security\",\"status\":\"fail\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"failed\":[$${failed_languages%,}]}"; \
			exit $$overall_exit; \
		fi; \
	fi; \
	dispatch_plugin_target security; \
	if [ "$(DEVRAIL_FAIL_FAST)" = "1" ] && [ $$overall_exit -ne 0 ]; then \
		end_time=$$(date +%s%3N); \
		duration=$$((end_time - start_time)); \
		echo "{\"target\":\"security\",\"status\":\"fail\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"failed\":[$${failed_languages%,}]}"; \
		exit $$overall_exit; \
	fi; \
	end_time=$$(date +%s%3N); \
	duration=$$((end_time - start_time)); \
	if [ -z "$${ran_languages}" ] && [ -n "$${skipped_languages}" ]; then \
		echo "{\"target\":\"security\",\"status\":\"skip\",\"reason\":\"no security scanners for declared languages\",\"duration_ms\":$$duration,\"skipped\":[$${skipped_languages%,}]}"; \
	elif [ $$overall_exit -eq 0 ]; then \
		echo "{\"target\":\"security\",\"status\":\"pass\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"skipped\":[$${skipped_languages%,}]}"; \
	else \
		echo "{\"target\":\"security\",\"status\":\"fail\",\"duration_ms\":$$duration,\"languages\":[$${ran_languages%,}],\"failed\":[$${failed_languages%,}],\"skipped\":[$${skipped_languages%,}]}"; \
	fi; \
	exit $$overall_exit

# --- _scan: universal vulnerability and secret scanning ---
_scan: _check-config
	@start_time=$$(date +%s%3N); \
	overall_exit=0; \
	failed_scanners=""; \
	trivy fs --format json --output /tmp/trivy-results.json . 2>/dev/null; \
	trivy_exit=$$?; \
	if [ $$trivy_exit -eq 1 ]; then \
		overall_exit=1; \
		failed_scanners="$${failed_scanners}\"trivy\","; \
	elif [ $$trivy_exit -gt 1 ]; then \
		echo "{\"target\":\"scan\",\"status\":\"error\",\"error\":\"trivy exited with code $$trivy_exit\",\"exit_code\":2}"; \
		exit 2; \
	fi; \
	if [ "$(DEVRAIL_FAIL_FAST)" = "1" ] && [ $$overall_exit -ne 0 ]; then \
		end_time=$$(date +%s%3N); \
		duration=$$((end_time - start_time)); \
		echo "{\"target\":\"scan\",\"status\":\"fail\",\"duration_ms\":$$duration,\"scanners\":[\"trivy\",\"gitleaks\"],\"failed\":[$${failed_scanners%,}]}"; \
		exit $$overall_exit; \
	fi; \
	gitleaks detect --source . --report-format json --report-path /tmp/gitleaks-results.json 2>/dev/null; \
	gitleaks_exit=$$?; \
	if [ $$gitleaks_exit -eq 1 ]; then \
		overall_exit=1; \
		failed_scanners="$${failed_scanners}\"gitleaks\","; \
	elif [ $$gitleaks_exit -gt 1 ]; then \
		echo "{\"target\":\"scan\",\"status\":\"error\",\"error\":\"gitleaks exited with code $$gitleaks_exit\",\"exit_code\":2}"; \
		exit 2; \
	fi; \
	end_time=$$(date +%s%3N); \
	duration=$$((end_time - start_time)); \
	if [ $$overall_exit -eq 0 ]; then \
		echo "{\"target\":\"scan\",\"status\":\"pass\",\"duration_ms\":$$duration,\"scanners\":[\"trivy\",\"gitleaks\"]}"; \
	else \
		echo "{\"target\":\"scan\",\"status\":\"fail\",\"duration_ms\":$$duration,\"scanners\":[\"trivy\",\"gitleaks\"],\"failed\":[$${failed_scanners%,}]}"; \
	fi; \
	exit $$overall_exit

# --- _docs: documentation generation ---
_docs: _check-config
	@start_time=$$(date +%s%3N); \
	overall_exit=0; \
	generators=""; \
	modules=""; \
	if [ -n "$(HAS_TERRAFORM)" ]; then \
		tf_dirs=$$(find . -name '*.tf' -not -path './.git/*' -not -path './.terraform/*' 2>/dev/null | xargs -I{} dirname {} | sort -u); \
		if [ -n "$$tf_dirs" ]; then \
			for dir in $$tf_dirs; do \
				terraform-docs markdown table --output-file README.md "$$dir" || overall_exit=1; \
				modules="$${modules}\"$$dir\","; \
			done; \
			generators="$${generators}\"terraform-docs\","; \
		else \
			echo '{"level":"info","msg":"skipping terraform-docs: no .tf files found","language":"terraform"}' >&2; \
		fi; \
	fi; \
	mkdir -p .devrail-output; \
	_sep=""; \
	_tv() { _out=$$(eval "$$2" 2>&1 | grep -oE '[0-9]+\.[0-9]+[^ ]*' | head -1); \
		[ -z "$$_out" ] && _out="unknown"; \
		printf '%s"%s":"%s"' "$$_sep" "$$1" "$$_out"; _sep=","; }; \
	{ \
		printf '{"generated_at":"%s","tools":{' "$$(date -u +%Y-%m-%dT%H:%M:%SZ)"; \
		if [ -n "$(HAS_PYTHON)" ]; then \
			_tv ruff "ruff --version"; \
			_tv bandit "bandit --version"; \
			_tv mypy "mypy --version"; \
			_tv pytest "pytest --version"; \
			_tv semgrep "semgrep --version"; \
		fi; \
		if [ -n "$(HAS_BASH)" ]; then \
			_tv shellcheck "shellcheck --version"; \
			_tv shfmt "shfmt --version"; \
			_tv bats "bats --version"; \
		fi; \
		if [ -n "$(HAS_TERRAFORM)" ]; then \
			_tv terraform "terraform version"; \
			_tv tflint "tflint --version"; \
			_tv trivy "trivy --version"; \
			_tv checkov "checkov --version"; \
			_tv terraform-docs "terraform-docs --version"; \
			_tv terragrunt "terragrunt --version"; \
		fi; \
		if [ -n "$(HAS_ANSIBLE)" ]; then \
			_tv ansible-lint "ansible-lint --version"; \
			_tv molecule "molecule --version"; \
		fi; \
		if [ -n "$(HAS_RUBY)" ]; then \
			_tv rubocop "rubocop --version"; \
			_tv reek "reek --version"; \
			_tv brakeman "brakeman --version"; \
			_tv bundler-audit "bundler-audit --version"; \
			_tv rspec "rspec --version"; \
			_tv srb "srb --version"; \
		fi; \
		if [ -n "$(HAS_GO)" ]; then \
			_tv go "go version"; \
			_tv golangci-lint "golangci-lint version"; \
			_tv gofumpt "gofumpt --version"; \
			_tv govulncheck "govulncheck -version"; \
		fi; \
		if [ -n "$(HAS_JAVASCRIPT)" ]; then \
			_tv node "node --version"; \
			_tv npm "npm --version"; \
			_tv eslint "eslint --version"; \
			_tv prettier "prettier --version"; \
			_tv tsc "tsc --version"; \
			_tv vitest "vitest --version"; \
		fi; \
		if [ -n "$(HAS_RUST)" ]; then \
			_tv rustc "rustc --version"; \
			_tv cargo "cargo --version"; \
			_tv clippy "cargo clippy --version"; \
			_tv rustfmt "rustfmt --version"; \
			_tv cargo-audit "cargo audit --version"; \
			_tv cargo-deny "cargo deny --version"; \
		fi; \
		_tv trivy "trivy --version"; \
		_tv gitleaks "gitleaks version"; \
		_tv git-cliff "git-cliff --version"; \
		printf '}}\n'; \
	} > .devrail-output/tool-versions.json; \
	generators="$${generators}\"tool-versions\","; \
	end_time=$$(date +%s%3N); \
	duration=$$((end_time - start_time)); \
	if [ $$overall_exit -eq 0 ]; then \
		echo "{\"target\":\"docs\",\"status\":\"pass\",\"duration_ms\":$$duration,\"generators\":[$${generators%,}],\"modules\":[$${modules%,}]}"; \
	else \
		echo "{\"target\":\"docs\",\"status\":\"fail\",\"duration_ms\":$$duration,\"generators\":[$${generators%,}],\"modules\":[$${modules%,}]}"; \
	fi; \
	exit $$overall_exit

# --- _changelog: generate CHANGELOG.md from conventional commits ---
_changelog: _check-config
	@start_time=$$(date +%s%3N); \
	config=""; \
	if [ -f "cliff.toml" ]; then \
		config="cliff.toml"; \
	elif [ -f "/opt/devrail/config/cliff.toml" ]; then \
		config="/opt/devrail/config/cliff.toml"; \
	fi; \
	if [ -z "$$config" ]; then \
		echo '{"target":"changelog","status":"error","error":"no cliff.toml found","exit_code":2}'; \
		exit 2; \
	fi; \
	if ! git rev-parse --git-dir >/dev/null 2>&1; then \
		echo '{"target":"changelog","status":"error","error":"not a git repository","exit_code":2}'; \
		exit 2; \
	fi; \
	git-cliff --config "$$config" --output CHANGELOG.md; \
	cl_exit=$$?; \
	end_time=$$(date +%s%3N); \
	duration=$$((end_time - start_time)); \
	if [ $$cl_exit -eq 0 ]; then \
		echo "{\"target\":\"changelog\",\"status\":\"pass\",\"duration_ms\":$$duration,\"config\":\"$$config\",\"output\":\"CHANGELOG.md\"}"; \
	else \
		echo "{\"target\":\"changelog\",\"status\":\"fail\",\"duration_ms\":$$duration,\"config\":\"$$config\",\"exit_code\":$$cl_exit}"; \
		exit $$cl_exit; \
	fi

# --- _init: scaffold config files for declared languages ---
_init: _check-config
	@created=""; \
	skipped=""; \
	scaffold() { \
	  _f="$$1"; shift; \
	  if [ ! -f "$$_f" ]; then \
	    printf '%s\n' "$$@" > "$$_f"; \
	    created="$${created}\"$$_f\","; \
	  else \
	    skipped="$${skipped}\"$$_f\","; \
	  fi; \
	}; \
	scaffold .editorconfig \
	  'root = true' \
	  '' \
	  '[*]' \
	  'charset = utf-8' \
	  'end_of_line = lf' \
	  'insert_final_newline = true' \
	  'trim_trailing_whitespace = true' \
	  'indent_style = space' \
	  'indent_size = 2' \
	  '' \
	  '[Makefile]' \
	  'indent_style = tab' \
	  '' \
	  '[*.py]' \
	  'indent_size = 4' \
	  '' \
	  '[*.sh]' \
	  'indent_size = 2'; \
	if [ -f "/opt/devrail/config/cliff.toml" ] && [ ! -f "cliff.toml" ]; then \
	  cp /opt/devrail/config/cliff.toml cliff.toml; \
	  created="$${created}\"cliff.toml\","; \
	elif [ -f "cliff.toml" ]; then \
	  skipped="$${skipped}\"cliff.toml\","; \
	fi; \
	if [ -n "$(HAS_PYTHON)" ]; then \
	  scaffold ruff.toml \
	    'line-length = 120' \
	    'target-version = "py311"' \
	    '' \
	    '[lint]' \
	    'select = ["E", "W", "F", "I", "UP", "B", "S", "C4", "SIM"]' \
	    '' \
	    '[format]' \
	    'quote-style = "double"' \
	    'indent-style = "space"'; \
	fi; \
	if [ -n "$(HAS_BASH)" ]; then \
	  scaffold .shellcheckrc \
	    'shell=bash' \
	    'enable=all'; \
	fi; \
	if [ -n "$(HAS_TERRAFORM)" ]; then \
	  scaffold .tflint.hcl \
	    'config {' \
	    '  call_module_type = "local"' \
	    '}' \
	    '' \
	    'plugin "terraform" {' \
	    '  enabled = true' \
	    '  preset  = "recommended"' \
	    '}'; \
	fi; \
	if [ -n "$(HAS_ANSIBLE)" ]; then \
	  scaffold .ansible-lint \
	    'profile: production' \
	    '' \
	    'exclude_paths:' \
	    '  - .cache/' \
	    '  - .github/' \
	    '  - .gitlab/' \
	    '' \
	    'skip_list:' \
	    '  - yaml[truthy]' \
	    '' \
	    'warn_list:' \
	    '  - experimental'; \
	fi; \
	if [ -n "$(HAS_RUBY)" ]; then \
	  scaffold .rubocop.yml \
	    'AllCops:' \
	    '  TargetRubyVersion: 3.4' \
	    '  NewCops: enable' \
	    '  Exclude:' \
	    '    - "db/schema.rb"' \
	    '    - "bin/**/*"' \
	    '    - "vendor/**/*"' \
	    '    - "node_modules/**/*"' \
	    '' \
	    'Style/Documentation:' \
	    '  Enabled: false' \
	    '' \
	    'Metrics/BlockLength:' \
	    '  Exclude:' \
	    '    - "spec/**/*"' \
	    '' \
	    'Layout/LineLength:' \
	    '  Max: 120'; \
	  scaffold .reek.yml \
	    'exclude_paths:' \
	    '  - vendor' \
	    '  - db/schema.rb' \
	    '  - bin' \
	    '' \
	    'detectors:' \
	    '  IrresponsibleModule:' \
	    '    enabled: false'; \
	  scaffold .rspec \
	    '--require spec_helper' \
	    '--format documentation' \
	    '--color'; \
	fi; \
	if [ -n "$(HAS_GO)" ]; then \
	  scaffold .golangci.yml \
	    'version: "2"' \
	    '' \
	    'linters:' \
	    '  enable:' \
	    '    - errcheck' \
	    '    - govet' \
	    '    - staticcheck' \
	    '    - gosec' \
	    '    - ineffassign' \
	    '    - unused' \
	    '    - gocritic' \
	    '    - gofumpt' \
	    '    - misspell' \
	    '    - revive' \
	    '' \
	    'issues:' \
	    '  exclude-dirs:' \
	    '    - vendor' \
	    '    - node_modules'; \
	fi; \
	if [ -n "$(HAS_JAVASCRIPT)" ]; then \
	  scaffold eslint.config.js \
	    'import eslint from "@eslint/js";' \
	    'import tseslint from "typescript-eslint";' \
	    '' \
	    'export default tseslint.config(' \
	    '  eslint.configs.recommended,' \
	    '  tseslint.configs.recommended,' \
	    '  {' \
	    '    ignores: ["node_modules/", "dist/", "build/", "coverage/"],' \
	    '  }' \
	    ');'; \
	  scaffold .prettierrc \
	    '{' \
	    '  "semi": true,' \
	    '  "singleQuote": false,' \
	    '  "trailingComma": "es5",' \
	    '  "printWidth": 80,' \
	    '  "tabWidth": 2' \
	    '}'; \
	  scaffold .prettierignore \
	    'node_modules/' \
	    'dist/' \
	    'build/' \
	    'coverage/'; \
	fi; \
	if [ -n "$(HAS_RUST)" ]; then \
	  scaffold clippy.toml \
	    '# clippy.toml -- DevRail Rust clippy configuration' \
	    '# See: https://doc.rust-lang.org/clippy/lint_configuration.html' \
	    'too-many-arguments-threshold = 7'; \
	  scaffold rustfmt.toml \
	    '# rustfmt.toml -- DevRail Rust formatter configuration' \
	    'edition = "2021"' \
	    'max_width = 100' \
	    'use_field_init_shorthand = true' \
	    'use_try_shorthand = true'; \
	  scaffold deny.toml \
	    '# deny.toml -- DevRail cargo-deny configuration' \
	    '# See: https://embarkstudios.github.io/cargo-deny/' \
	    '' \
	    '[advisories]' \
	    'vulnerability = "deny"' \
	    'unmaintained = "warn"' \
	    'yanked = "warn"' \
	    '' \
	    '[licenses]' \
	    'unlicensed = "deny"' \
	    'allow = [' \
	    '  "MIT",' \
	    '  "Apache-2.0",' \
	    '  "BSD-2-Clause",' \
	    '  "BSD-3-Clause",' \
	    '  "ISC",' \
	    '  "Unicode-3.0",' \
	    '  "Unicode-DFS-2016",' \
	    ']' \
	    '' \
	    '[bans]' \
	    'multiple-versions = "warn"' \
	    '' \
	    '[sources]' \
	    'unknown-registry = "deny"' \
	    'unknown-git = "warn"'; \
	fi; \
	echo "{\"target\":\"init\",\"created\":[$${created%,}],\"skipped\":[$${skipped%,}]}"

# --- _check: orchestrate all targets ---
_check: _plugins-load
	@overall_exit=0; \
	overall_start=$$(date +%s%3N); \
	results=""; \
	passed=""; \
	failed=""; \
	skipped=""; \
	for target in lint format test security scan docs; do \
		target_start=$$(date +%s%3N); \
		json_output=$$($(MAKE) _$${target} 2>/dev/null); \
		target_exit=$$?; \
		target_end=$$(date +%s%3N); \
		target_duration=$$((target_end - target_start)); \
		status=$$(echo "$$json_output" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4); \
		if [ -z "$$status" ]; then \
			if [ $$target_exit -eq 0 ]; then status="pass"; \
			elif [ $$target_exit -eq 2 ]; then status="error"; \
			else status="fail"; fi; \
		fi; \
		results="$${results}{\"target\":\"$$target\",\"status\":\"$$status\",\"duration_ms\":$$target_duration},"; \
		case "$$status" in \
			pass) passed="$${passed}\"$$target\","; ;; \
			fail|error) \
				failed="$${failed}\"$$target\","; \
				if [ $$target_exit -eq 2 ]; then overall_exit=2; \
				elif [ $$overall_exit -ne 2 ]; then overall_exit=1; fi; \
				;; \
			skip) skipped="$${skipped}\"$$target\","; ;; \
		esac; \
		if [ "$(DEVRAIL_LOG_FORMAT)" = "human" ]; then \
			case "$$status" in \
				pass) printf '\033[32m%-12s PASS   %s\033[0m\n' "$$target" "$${target_duration}ms" >&2; ;; \
				fail|error) printf '\033[31m%-12s FAIL   %s\033[0m\n' "$$target" "$${target_duration}ms" >&2; ;; \
				skip) printf '\033[33m%-12s SKIP   %s\033[0m\n' "$$target" "$${target_duration}ms" >&2; ;; \
			esac; \
		fi; \
		if [ "$(DEVRAIL_FAIL_FAST)" = "1" ] && [ $$target_exit -ne 0 ]; then \
			for remaining in lint format test security scan docs; do \
				found=0; \
				for done_target in lint format test security scan docs; do \
					if [ "$$done_target" = "$$target" ]; then found=1; break; fi; \
					if [ "$$done_target" = "$$remaining" ]; then break; fi; \
				done; \
			done; \
			break; \
		fi; \
	done; \
	overall_end=$$(date +%s%3N); \
	overall_duration=$$((overall_end - overall_start)); \
	if [ "$(DEVRAIL_LOG_FORMAT)" = "human" ]; then \
		echo "=========================================" >&2; \
		echo "DevRail Check Summary" >&2; \
		echo "=========================================" >&2; \
		if [ $$overall_exit -eq 0 ]; then \
			printf '\033[32mResult: PASS  Total: %sms\033[0m\n' "$$overall_duration" >&2; \
		else \
			printf '\033[31mResult: FAIL  Total: %sms\033[0m\n' "$$overall_duration" >&2; \
		fi; \
		echo "=========================================" >&2; \
	fi; \
	if [ $$overall_exit -eq 0 ]; then \
		check_status="pass"; \
	else \
		check_status="fail"; \
	fi; \
	echo "{\"target\":\"check\",\"status\":\"$$check_status\",\"duration_ms\":$$overall_duration,\"results\":[$${results%,}],\"passed\":[$${passed%,}],\"failed\":[$${failed%,}],\"skipped\":[$${skipped%,}]}"; \
	exit $$overall_exit
