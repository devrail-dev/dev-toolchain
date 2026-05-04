# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Plugin build pipeline foundations (Story 13.4a, Epic 13 / v1.10.x preview):
  - **Host-side persistent plugin cache.** `DEVRAIL_HOST_PLUGINS_CACHE`
    Makefile variable (defaults to `${HOME}/.cache/devrail/plugins`) is
    bind-mounted into every `DOCKER_RUN` at `/opt/devrail/plugins`. Plugin
    manifests fetched by `make plugins-update` now survive across container
    invocations. Closes a Story 13.3 gap where the cache was ephemeral.
  - **`scripts/plugin-build-extended-image.sh`** — generates a workspace-
    local `Dockerfile.devrail` from the plugin loader cache (Story 13.2)
    that extends the core dev-toolchain image with each declared plugin's
    `container:` fragment (`apt_packages`, `copy_from_builder`, `env`,
    `install_script`). Output is deterministic (env vars sorted by key,
    plugin order matches lockfile order). Pinned to the exact patch
    version of the core image so the eventual `devrail-local:<hash>` tag
    is stable across local invocations.
  - **`_ensure-host-cache`** Makefile target wired as a prereq of every
    public host target that invokes `DOCKER_RUN`. Idempotent `mkdir -p`.

### Fixed

- `fetch_to_cache` in `plugin-resolver.sh` now `chmod -R u+rwX,g+rX,o+rX`
  the cached tree after the atomic swap. `mktemp -d` defaults to 0700,
  which blocked the host user from traversing its own bind-mounted cache
  (the `mtime` smoke test in Story 13.3 hit this and worked around it
  via a sidecar docker container; this fix makes the workaround
  unnecessary). Closes a Story 13.3 review-fix gap.

### Other

- `tests/test-plugin-build-pipeline.sh` — 4-case 13.4a smoke test:
  empty cache → no-op, full container block → expected dockerfile
  shape, deterministic re-runs, host cache mount + readability.
  Story 13.4b will extend with full docker-build pipeline cases.

## [1.10.2] - 2026-05-03

### Fixed

- Plugin resolver review follow-ups (Story 13.3 senior-developer review):
  - **H1**: malformed `.devrail.yml` no longer silently treated as
    "no plugins declared". `yq` parse failures now surface as a structured
    error event and exit 2 instead of being swallowed by `|| echo 0`.
  - **M1**: lockfile verifier passes the `.devrail.yml` source URL via
    `strenv()` instead of string-interpolating it into the yq query —
    defends against malformed/malicious source values breaking the query.
  - **M2**: slug collisions (two plugin sources with the same `basename`)
    are now detected upfront and rejected with a clear "plugin slug
    collision" error event. Previously the second plugin would silently
    overwrite the first's cache.
  - **M3**: `fetch_to_cache` now performs an atomic swap (move existing
    target aside, install new, remove old) so concurrent `make check`
    invocations during a `make plugins-update` see either the old tree
    or the new one — never an absent or half-populated path.
  - **M4**: `compute_content_hash` and `derive_slug` extracted to
    `lib/plugin-cache.sh` and shared between resolver and verifier
    (was duplicated; future drift risk eliminated).
  - **M5**: resolver now invokes `plugin-validator.sh` on the fetched
    manifest before computing content_hash. Authors hit manifest
    structural issues at `make plugins-update` time, not at every
    subsequent `make check`.
  - **L1**: `fetch_to_cache` comment updated to reflect 4 args (not 3).
  - **L2**: `derive_slug` strips the `.git` suffix so
    `https://example.com/foo.git` produces cache path
    `<plugins-dir>/foo/<rev>/`, not `<plugins-dir>/foo.git/<rev>/`.
  - **L3**: lockfile entries written with double-quoted YAML scalars so
    source URLs containing colons, brackets, or other reserved chars
    don't break parsing.
  - **L4**: smoke test now covers `_plugins-update` no-op when no
    plugins declared (companion to existing `_plugins-verify` case).
  - **L5**: idempotent-fetch test now asserts cache sentinel `.devrail.sha`
    mtime is stable across re-runs (proves no re-clone happened).
  - **L6**: smoke test exercises a `.git`-suffixed source URL.

### Added

- `lib/plugin-cache.sh` — shared `derive_slug` and `compute_content_hash`
  helpers used by the resolver and verifier. Single source of truth for
  the on-disk cache layout.
- `tests/test-plugin-resolver.sh` extended from 11 to 16 cases
  (review-fix coverage: yq parse error, slug collision, `.git` suffix,
  no-plugins update no-op, mtime-based idempotency).
- Plugin resolver and lockfile (Story 13.3, Epic 13 / v1.10.x preview).
  - **`make plugins-update`** — public target that resolves every
    `.devrail.yml` plugin's `rev:` to an immutable SHA via `git ls-remote`,
    fetches the plugin tree to
    `${DEVRAIL_PLUGINS_DIR:-/opt/devrail/plugins}/<source-slug>/<rev>/`
    (the same path the Story 13.2 loader reads), computes a deterministic
    `content_hash`, and writes `.devrail.lock` atomically. Branch refs are
    rejected with a clear error; only tags and 40-char SHAs accepted.
  - **`.devrail.lock`** — checked into VCS by consumers, like `Gemfile.lock`
    or `Cargo.lock`. Records `source`, `rev`, resolved `sha`, manifest
    `schema_version`, and `content_hash` per plugin. Sorted alphabetically
    by `source` for deterministic diffs.
  - **`_plugins-verify`** — new internal Make target that runs as a
    prerequisite of `_plugins-load` on every `make check`. Confirms every
    `.devrail.yml` plugin entry has a matching lockfile entry with the
    same rev, and re-computes `content_hash` of each cached tree to detect
    tag-rebase tampering. Fails with code 2 on any disagreement; emits
    structured error events with remediation hints
    (`"run \`make plugins-update\`"`).
  - Fully no-op when `.devrail.yml` declares no `plugins:` (regression-safe
    for v1.9.x and v1.10.x consumers without plugin declarations).
- `scripts/plugin-resolver.sh` and `scripts/plugin-lockfile-verify.sh` —
  pure-bash, yq + git + sha256sum dependencies (all in image).
- `tests/fixtures/plugin-repos/elixir-v1/` and `elixir-v1-tampered/` —
  fixture trees (no `.git/`); the test harness initialises git per case.
- `tests/test-plugin-resolver.sh` — 11-case smoke covering SHA passthrough,
  tag→SHA resolution, branch rejection, lockfile determinism, idempotent
  fetch, lockfile mismatch, tampering detection, missing lockfile,
  no-plugins regression, unreachable source, and atomic-lockfile-on-failure.
  Wired into `.github/workflows/ci.yml`.

## [1.10.1] - 2026-05-03

### Fixed

- Plugin loader review follow-ups (Story 13.2 senior-developer review):
  - Manifest cache path now includes `<rev>` per design — the loader looks for
    manifests at `${DEVRAIL_PLUGINS_DIR}/<source-slug>/<rev>/plugin.devrail.yml`
    instead of `<source-slug>/plugin.devrail.yml`. Lets multiple plugin
    versions coexist on disk; aligns with what Story 13.3's resolver will
    populate. Plugin entries in `.devrail.yml` must declare `rev:`; missing
    `rev` now fails fast with a clear error.
  - Manifest cache file (`/tmp/devrail-plugins-loaded.yaml`) now contains
    the FULL manifest content (`targets`, `gates`, `container`, etc.) merged
    with resolution metadata (`source`, `rev`, `manifest_path`) per the
    design's "yq-flattened map of plugin name → manifest contents" intent.
    Story 13.5's execution loop will be able to consume the cache directly
    instead of re-reading every manifest from disk.
  - Validator now checks the optional `gates` field — must be a mapping of
    valid target names to lists of strings. Malformed gates fail at
    validation time instead of crashing Story 13.5's gate evaluator.
  - Validator routes structured events through `lib/log.sh`'s new
    `log_event` function instead of hand-crafting JSON. Honours
    `DEVRAIL_LOG_FORMAT=human` like the rest of the codebase.
  - Plugin name is now regex-validated before being embedded in early
    diagnostic events, so a malformed manifest can't taint pre-validation
    JSON output.
  - `lib/version.sh` warns when `/opt/devrail/VERSION` exists but is
    unreadable, instead of silently falling through to the lenient
    `0.0.0-dev` mode (would have masked permission misconfiguration).
  - Removed unused `lib/platform.sh` source from `plugin-validator.sh`.

### Added

- `lib/log.sh::log_event` — structured logger that accepts arbitrary extra
  fields (`key=value` for strings, `key:=value` for raw numbers/booleans).
  Suppresses info events under `DEVRAIL_QUIET=1`, debug events unless
  `DEVRAIL_DEBUG=1`, mirrors the existing logger conventions.
- `tests/fixtures/plugins/bad-gates/v1.0.0/plugin.devrail.yml` — fixture for
  the new gates-validation check.
- `tests/test-plugin-loader.sh` extended with: empty-`plugins:[]` case,
  cache full-manifest contract assertion (consumes `targets.lint.cmd` and
  resolution metadata via `yq`), missing-`rev` integration case, and the
  bad-gates unit case. Total: 11 checks (was 8).

## [1.10.0] - 2026-05-01

### Fixed

- Rails projects can now run a CI-equivalent `make check` against their actual
  Gemfile-pinned tools, test database, and `.bundle/config` (#30):
  - **Gap A — `BUNDLE_APP_CONFIG` override.** `DOCKER_RUN` now passes
    `-e BUNDLE_APP_CONFIG=/workspace/.bundle` when `HAS_RUBY` is detected, so
    the project's `.bundle/config` (e.g. `BUNDLE_PATH: vendor/bundle`) wins
    over the container's `/usr/local/bundle` default. Previously, projects
    with a sandboxed bundle silently lost their config and bundler couldn't
    find their gems.
  - **Gap B — `_test` runs `bundle exec rails db:test:prepare` before rspec.**
    Detected by `config/application.rb` + `Gemfile` presence. On DB-unreachable
    failures the loader emits a structured `error` event with a clear hint
    ("ensure your test database is reachable, e.g. start postgres before
    make test") rather than letting 200+ specs fail with cryptic errors.
    Non-Rails Ruby projects continue to call `rspec` directly.
  - **Gap C — `bundle exec` wrapping for project-pinned tools.** `_lint`,
    `_format`, `_fix`, `_test`, `_security` now use `bundle exec <tool>`
    when the tool is present in the project's `Gemfile.lock`. Falls back to
    the container's tool when the project does not pin it. Eliminates lint
    diffs caused by version drift between the container's rubocop/reek/
    brakeman/bundler-audit/rspec and the project's pinned versions.
- `STABILITY.md` documents the new "you provide a reachable Postgres for
  Rails projects with DB-touching specs" expectation.

### Added

- Plugin manifest parser and loader prelude (Story 13.2, Epic 13 / v1.10.0).
  - New `scripts/plugin-validator.sh` — validates a `plugin.devrail.yml`
    against schema_version=1 and emits structured `error`-level events for
    every violation cumulatively (does not fail-fast on the first violation).
  - New `lib/version.sh` — `version_gte` semver helper plus
    `get_devrail_version` (reads `DEVRAIL_VERSION` env, then
    `/opt/devrail/VERSION`, else `0.0.0-dev`).
  - New `_plugins-load` Makefile target — runs as a prerequisite of `_check`,
    `_lint`, `_format`, `_fix`, `_test`, `_security`. Iterates `.devrail.yml`
    `plugins:` entries, locates each manifest under
    `${DEVRAIL_PLUGINS_DIR:-/opt/devrail/plugins}/<slug>/plugin.devrail.yml`,
    validates each, writes a parsed cache to
    `${DEVRAIL_PLUGINS_CACHE:-/tmp/devrail-plugins-loaded.yaml}`, and exits 2
    (misconfig) on any violation before any tool runs.
  - Dockerfile records image version at build time via `ARG DEVRAIL_VERSION`
    (default `0.0.0-dev`) → `/opt/devrail/VERSION` and the
    `org.opencontainers.image.version` label.
  - Behaviour without a `plugins:` section is unchanged — the loader emits a
    single info event and exits 0.
- `tests/test-plugin-loader.sh` — five validator unit cases against checked-in
  fixtures plus three loader integration cases (no plugins / valid plugin /
  invalid plugin). Wired into `.github/workflows/ci.yml`.
- `tests/smoke-rails.sh` — fourth assertion: with a project-local
  `.bundle/config` declaring `BUNDLE_PATH: vendor/bundle`, the container
  honours it (validates Gap A's fix end-to-end).

## [1.9.1] - 2026-04-29

### Fixed

- `bundle install` now succeeds out-of-the-box for Rails 7+ projects that use
  the standard `debug` gem (#28). v1.9.0 shipped `libyaml-0-2` (runtime lib only)
  but not the development headers required to compile `psych` 5.x as a native
  gem; the resolution chain `debug → irb → rdoc → psych` failed at the psych
  build step. Replaced `libyaml-0-2` with `libyaml-dev` (which transitively
  pulls in the runtime lib).
- `tests/smoke-rails.sh` extended with a `bundle install` step against the
  Rails-shaped fixture's Gemfile — exercises the psych native-compile path
  end-to-end and asserts `require 'psych'` succeeds inside the container.

## [1.9.0] - 2026-04-27

### Fixed

- Ruby support is now consumable by Rails 7+ projects out-of-the-box (#25):
  - Image now ships **Ruby 3.4.9** (Bundler 2.6) via a dedicated `ruby-builder` stage,
    replacing the bookworm APT Ruby 3.1.2 that could not parse Gemfiles using the
    `windows` platform alias (`platforms: %i[mri windows]`).
  - `_lint`, `_format`, and `_fix` Ruby branches now scope `rubocop` and `reek` to
    a configurable `RUBY_PATHS` (default: `app lib spec config bin`) instead of
    the workspace root, eliminating tens of thousands of warnings from `vendor/bundle/`
    gem source. Override per-project via `RUBY_PATHS="lib spec" make check`.
- `reek` is no longer pinned to `~> 6.3.0` — Ruby 3.4 satisfies its `dry-schema 1.14`
  requirement.

### Added

- `tests/smoke-rails.sh` — CI smoke test that builds a minimal Rails-shaped fixture
  (modern Gemfile + `vendor/bundle/` noise) and asserts `make _lint` passes cleanly
  and does not descend into `vendor/bundle/`.
- `.devrail.yml` `env:` section is now passed through to the container as
  `-e KEY=VALUE` flags on `docker run`. Lets projects declare environment
  variables (e.g. `ANSIBLE_ROLES_PATH`, `ANSIBLE_COLLECTIONS_PATH`) that
  tools inside the container need. Schema documented in
  `standards/devrail-yml-schema.md`.
- `_lint` Ansible branch now auto-detects `ANSIBLE_ROLES_PATH` from
  `ansible.cfg` (or `ansible/ansible.cfg`) when the env var is not set
  explicitly. Resolves a common stumble where `ansible-lint` cannot find
  roles in projects that keep their config under an `ansible/` subdirectory.
  Explicit configuration via `.devrail.yml` `env:` always wins.

## [1.8.1] - 2026-03-19

### Changed

- Bump Go builder from 1.24 to 1.25 (fixes govulncheck on Go 1.25 projects)
- Add critical rule 9 to agent instructions — ensure DevRail Makefile is active (GNUmakefile precedence)

## [1.8.0] - 2026-03-19

### Changed

- Replace deprecated tfsec with `trivy config` for Terraform security scanning
- Pin gitleaks to v8.30.0 with `-ldflags` for proper version reporting

### Removed

- tfsec (deprecated, merged into Trivy)

## [1.7.1] - 2026-03-16

### Fixed

- `community.general` Ansible collection now actually installs (`ansible-galaxy collection list` exits 0 even when not installed; check grep output instead)

## [1.7.0] - 2026-03-13

### Added

- `devrail-init.sh` progressive adoption script for bootstrapping DevRail in any project
- `community.general` Ansible collection in container (yaml callback, json_query, common modules)

### Fixed

- Interactive prompts now read from `/dev/tty` so `curl | bash` works correctly
- Version-manifest CI job no longer skipped on tag push

## [1.6.0] - 2026-03-09

### Added

- Rust language ecosystem support (clippy, rustfmt, cargo-audit, cargo-deny, cargo test)
- Terragrunt companion tool for Terraform (format checking, HCL validation)
- `make fix` target for in-place formatting across all languages
- `make check` pre-push hook for full validation before push
- `make release VERSION=x.y.z` target for manual version releases
- Tool version manifest (`report-tool-versions.sh`) for release artifacts
- git-cliff for automated changelog generation

### Changed

- Updated STABILITY.md from beta to v1 stable
- Updated README with all 8 languages in tools table
- Bumped conventional-commits hook to v1.1.0 (all language and workflow scopes)
- Added critical rule 8 — update documentation when changing behavior

### Fixed

- Added missing clippy and rustfmt rustup components to Rust toolchain

## [1.4.0] - 2026-03-01

### Added

- `make init` / `make _init` target for scaffolding config files based on `.devrail.yml`
- Scaffolds: ruff.toml, .shellcheckrc, .tflint.hcl, .ansible-lint, .rubocop.yml, .reek.yml, .rspec, .golangci.yml, eslint.config.js, .prettierrc, .prettierignore, .editorconfig

### Changed

- Updated contributing guide references from `contributing-a-language.md` to `contributing.md`

## [1.3.0] - 2026-03-01

### Added

- JavaScript/TypeScript language support (eslint, prettier, typescript, vitest, npm audit)
- Node.js 22 runtime in container (COPY'd from node:22-bookworm-slim)

### Fixed

- Switched trivy installation from GitHub release downloads to APT repository
- Fixed shfmt formatting in install-universal.sh

## [1.2.0] - 2026-02-27

### Added

- Go language support (golangci-lint, gofumpt, govulncheck, go test)
- Go SDK in container (COPY'd from golang builder stage)

## [1.1.0] - 2026-02-27

### Added

- Ruby language support (rubocop, reek, brakeman, bundler-audit, rspec, sorbet)

## [1.0.0] - 2026-02-20

### Added

- Initial repository structure with multi-stage Dockerfile
- Shared bash libraries (lib/log.sh, lib/platform.sh)
- Per-language install scripts (Python, Bash, Terraform, Ansible, Universal)
- Two-layer delegation Makefile with JSON summary output
- Multi-arch build (amd64 + arm64) and GHCR publishing workflows
- Cosign image signing
- Automated weekly builds with semver patch bump
- CI validation with self-check, trivy scan, and gitleaks

### Fixed

- Use v-prefixed major version tag for container image (`:v1` not `:1`)
