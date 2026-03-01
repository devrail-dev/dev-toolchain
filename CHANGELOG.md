# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Updated STABILITY.md from beta to v1 stable
- Updated README with all 7 languages in tools table

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
