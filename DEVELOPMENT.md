# dev-toolchain Development Guide

This document describes how to develop on the dev-toolchain repository. The dev-toolchain container is the single source of truth for all tool versions in the DevRail ecosystem.

This project follows [DevRail](https://devrail.dev) development standards. For the canonical reference, see the root [DEVELOPMENT.md](../DEVELOPMENT.md) in the devrail-standards repo.

---

<!-- devrail:critical-rules -->

## Critical Rules

These eight rules are non-negotiable. Every developer and every AI agent must follow them without exception.

1. **Run `make check` before completing any story or task.** Never mark work done without passing checks. This is the single gate for all linting, formatting, security, and test validation.

2. **Use conventional commits.** Every commit message follows the `type(scope): description` format. No exceptions. Scopes for this repo: `container`, `python`, `bash`, `terraform`, `ansible`, `security`, `ci`.

3. **Never install tools outside the container.** All linters, formatters, scanners, and test runners live inside the dev-toolchain container image. The Makefile delegates to Docker.

4. **Respect `.editorconfig`.** Never override formatting rules (indent style, line endings, trailing whitespace) without explicit instruction.

5. **Write idempotent scripts.** Every script must be safe to re-run. Check before acting: `command -v tool || install_tool`, `mkdir -p`, guard file writes with existence checks.

6. **Use the shared logging library.** No raw `echo` for status messages. Use `log_info`, `log_warn`, `log_error`, `log_debug`, and `die` from `lib/log.sh`.

7. **Never suppress failing checks.** When a lint, format, security, or test check fails, fix the underlying issue. Never comment out code, add suppression annotations (`# noqa`, `# nosec`, `#tfsec:ignore`, `// nolint`), disable rules, or mark CI jobs as allowed-to-fail to bypass a failing check. If a finding is a confirmed false positive, document the justification inline alongside the tool's designated suppression mechanism.

8. **Update documentation when changing behavior.** When a change affects public interfaces, configuration, CLI usage, or setup steps, update the relevant documentation (README, DEVELOPMENT.md, inline docs) in the same commit or PR. Do not leave documentation out of sync with code.

<!-- /devrail:critical-rules -->

## Quick Start

```bash
# Build the container image locally
make build

# Run all checks (lint, format, test, security)
make check

# Install pre-commit hooks
make install-hooks
```

## Makefile Targets

Run `make help` to see all available targets:

| Target | Purpose |
|---|---|
| `make help` | List all targets with descriptions (default target) |
| `make build` | Build the container image locally |
| `make lint` | Run all linters (shellcheck on scripts) |
| `make format` | Run all formatters (shfmt on scripts) |
| `make test` | Run validation tests |
| `make security` | Run security checks |
| `make scan` | Run universal scanners (trivy, gitleaks) |
| `make docs` | Generate documentation (terraform-docs, tool version report) |
| `make changelog` | Generate CHANGELOG.md from conventional commits (git-cliff) |
| `make check` | Run all of the above in sequence |
| `make init` | Scaffold config files for declared languages |
| `make install-hooks` | Install pre-commit hooks |

## Repository Structure

```
dev-toolchain/
├── Dockerfile              # Multi-stage container build
├── Makefile                # Two-layer delegation Makefile
├── .devrail.yml            # DevRail project configuration
├── config/                 # Default configuration files
│   └── cliff.toml          # Default git-cliff changelog config
├── scripts/                # Per-language install scripts
│   ├── install-python.sh
│   ├── install-bash.sh
│   ├── install-terraform.sh
│   ├── install-ansible.sh
│   ├── install-ruby.sh
│   ├── install-go.sh
│   ├── install-javascript.sh
│   └── install-universal.sh
├── lib/                    # Shared bash libraries
│   ├── log.sh
│   └── platform.sh
└── tests/                  # Tool installation verification tests
    ├── test-python.sh
    ├── test-bash.sh
    ├── test-terraform.sh
    ├── test-ansible.sh
    ├── test-ruby.sh
    ├── test-go.sh
    ├── test-javascript.sh
    └── test-universal.sh
```

## Shell Script Conventions

All scripts in this repo follow the DevRail shell script pattern:

- `#!/usr/bin/env bash` + `set -euo pipefail` -- always, no exceptions
- Source `lib/log.sh` and `lib/platform.sh` for shared utilities
- Idempotent by default -- check before acting
- Support `--help` flag
- End with verification using `require_cmd`
- No raw `echo` -- use shared logging functions

## Adding a New Language

See the [Contributing to DevRail](../standards/contributing.md) guide for the step-by-step process.

## Conventional Commits

Scopes for this repository:

| Scope | Usage |
|---|---|
| `container` | Dockerfile, base image, multi-arch build |
| `python` | Python tool installation |
| `bash` | Bash tool installation |
| `terraform` | Terraform tool installation |
| `ansible` | Ansible tool installation |
| `ruby` | Ruby tool installation |
| `go` | Go tool installation |
| `javascript` | JavaScript/TypeScript tool installation |
| `rust` | Rust tool installation |
| `security` | Security tool installation (trivy, gitleaks) |
| `changelog` | Changelog generation tooling (git-cliff) |
| `ci` | CI/CD workflows |
| `release` | Release process and tooling |

Examples:
- `feat(python): add ruff linter to install script`
- `fix(container): resolve arm64 build failure`
- `chore(ci): update build workflow to use latest actions`
- `chore(release): prepare v1.6.0`

## Releasing

The dev-toolchain container is released via semver-tagged Docker images published to GHCR.

### When to Cut a Release

| Change Type | Version Bump | Example |
|---|---|---|
| New language ecosystem | Minor (x.Y.0) | Adding Java support → v1.7.0 |
| New tool or significant feature | Minor (x.Y.0) | Adding a new Makefile target |
| Bug fix or config correction | Patch (x.y.Z) | Fixing a broken install script |
| Breaking change | Major (X.0.0) | Removing a language or changing Makefile contract |
| Routine weekly rebuild | Patch (auto) | Handled automatically by scheduled CI |

Weekly cron builds (Monday 6AM UTC) automatically bump the patch version and publish. Manual releases are only needed for feature or breaking changes that warrant a specific version number.

### How to Release

1. Ensure all changes are merged to `main` and `make check` passes.
2. Run:
   ```bash
   make release VERSION=1.6.0
   ```
3. The script will:
   - Validate preconditions (on main, clean state, tag doesn't exist)
   - Update CHANGELOG.md (move [Unreleased] entries under the new version)
   - Commit with `chore(release): prepare v1.6.0`
   - Create annotated tag `v1.6.0`
   - Prompt for confirmation before pushing

### What Happens After Push

Once the tag is pushed to origin, GitHub Actions handles everything:

1. **build.yml** -- Builds multi-arch container image (amd64 + arm64) and publishes to GHCR
2. **release.yml** -- Creates a GitHub Release with auto-generated release notes and updates the `v1` floating tag
3. **build.yml (version-manifest)** -- Generates `tool-versions.json` from the published container and attaches it to the release

### Routine Rebuilds

Weekly Monday builds require no manual action. The `auto-version` job in `build.yml` finds the latest tag, bumps the patch version, and triggers the full build+release pipeline. This keeps tool versions current without manual intervention.

<!-- devrail:coding-practices -->

## Coding Practices

General software engineering standards that apply across all languages. For the full reference, see [`standards/coding-practices.md`](standards/coding-practices.md).

- **DRY, KISS, YAGNI** -- don't repeat yourself, keep it simple, build only what is needed now
- **Single responsibility** -- each function, class, or module does one thing
- **Fail fast** -- validate inputs at boundaries, return or raise immediately on invalid state
- **No swallowed exceptions** -- every error branch handles the error meaningfully or propagates it
- **Test behavior, not implementation** -- assert on outputs and side effects, follow the test pyramid (unit > integration > e2e)
- **New code must include tests** -- PRs that add logic without tests are incomplete
- **~50 line function guideline** -- split long functions into focused helpers
- **Pin dependency versions** -- commit lock files, update regularly, respond to security advisories promptly

<!-- /devrail:coding-practices -->

<!-- devrail:git-workflow -->

## Git Workflow

Git discipline and collaboration standards. For the full reference, see [`standards/git-workflow.md`](standards/git-workflow.md).

- **Never push directly to `main`** -- all changes reach the default branch through a pull/merge request
- **Branch naming** -- `type/short-description` (e.g., `feat/add-auth`, `fix/login-error`)
- **Minimum 1 approval required** before merging, no self-merge
- **Atomic commits** -- one logical change per commit, conventional commit format
- **No `--force-push` to shared branches** -- only force push your own feature branches
- **Squash-merge feature branches** for clean, linear history on `main`
- **No secrets in commits** -- enforced by gitleaks pre-commit hook and `make scan`
- **Branch protection on `main`** -- require PR, approvals, and CI pass

<!-- /devrail:git-workflow -->

<!-- devrail:release-versioning -->

## Release & Versioning

Release management and versioning discipline. For the full reference, see [`standards/release-versioning.md`](standards/release-versioning.md).

- **Semantic versioning** -- `MAJOR.MINOR.PATCH` with strict adherence after `v1.0.0`
- **Annotated tags only** -- `vX.Y.Z` format, tagged from `main`, never moved or deleted after push
- **Release process** -- review changelog, tag, push, create platform release with artifacts
- **Hotfixes** -- branch from tag, fix, merge to `main`, tag new patch release
- **Pre-release versions** -- `v1.0.0-rc.1`, `v1.0.0-beta.1` conventions for unstable releases
- **Libraries vs services** -- libraries follow semver strictly; services may use date-based versioning
- **Changelog** -- auto-generated from conventional commits, [Keep a Changelog](https://keepachangelog.com/) format

<!-- /devrail:release-versioning -->

<!-- devrail:ci-cd-pipelines -->

## CI/CD Pipelines

Continuous integration and deployment standards. For the full reference, see [`standards/ci-cd-pipelines.md`](standards/ci-cd-pipelines.md).

- **Standard stages** -- `lint → format → test → security → scan → build → deploy` (in order)
- **Stage contract** -- each CI stage calls a `make` target; identical behavior locally and in CI
- **Required jobs** -- lint, format, test, security, scan must pass before merge
- **Deployment gates** -- auto-deploy to staging on merge to `main`; manual approval for production
- **Pipeline types** -- library (test+publish), service (test+build+deploy), infrastructure (plan+apply)
- **Artifact management** -- release tags are immutable, pin toolchain versions, commit lock files
- **Performance** -- cache dependencies, parallelize independent stages, target < 10 min for PR checks

<!-- /devrail:ci-cd-pipelines -->

<!-- devrail:container-standards -->

## Container Standards

Container image build and runtime standards. For the full reference, see [`standards/container-standards.md`](standards/container-standards.md).

- **Pin base images** -- use specific tags or digests, never `latest`
- **Multi-stage builds** -- separate build dependencies from the runtime image
- **Layer ordering** -- least-changing layers first to maximize cache reuse
- **Non-root user** -- never run containers as root in production
- **No secrets in images** -- inject at runtime via env vars or mounted volumes
- **Image tagging** -- `vX.Y.Z` for releases, `sha-<short>` for CI builds, never overwrite release tags
- **Health checks** -- every service container exposes `/healthz` and `/readyz` endpoints
- **`.dockerignore` required** -- exclude `.git`, tests, docs, and build artifacts from the context

<!-- /devrail:container-standards -->

<!-- devrail:secrets-management -->

## Secrets Management

Standards for handling secrets and sensitive configuration. For the full reference, see [`standards/secrets-management.md`](standards/secrets-management.md).

- **Classify correctly** -- secrets vs sensitive config vs environment config vs application config
- **Never in source control** -- no API keys, passwords, or tokens in committed files (enforced by gitleaks)
- **Platform secrets** -- use GitHub/GitLab secrets or a dedicated manager (Vault, AWS SM, GCP SM)
- **`.env` gitignored, `.env.example` committed** -- document required variables with placeholders
- **`UPPER_SNAKE_CASE` naming** -- prefix by service or context to avoid collisions
- **Rotate on schedule** -- 90-day minimum for keys and credentials; immediately on exposure
- **Least privilege** -- no shared credentials, service accounts over personal, audit access

<!-- /devrail:secrets-management -->

<!-- devrail:api-cli-design -->

## API & CLI Design

Standards for designing APIs and CLIs. For the full reference, see [`standards/api-cli-design.md`](standards/api-cli-design.md).

- **Version APIs from day one** -- URL path (`/v1/`) preferred; never break clients without a version bump
- **JSON by default** -- consistent envelope, ISO 8601 timestamps, request IDs in every response
- **Structured errors** -- machine-readable `code`, human-readable `message`, detailed `fields`; correct HTTP status codes
- **CLI conventions** -- `--help` on every command, exit codes 0/1/2, JSON output for machines
- **Backward compatibility** -- additive changes are safe; removals require deprecation + version bump
- **OpenAPI for APIs** -- spec is the source of truth, kept in sync with code
- **Pagination and rate limiting** -- standard patterns for collection endpoints

<!-- /devrail:api-cli-design -->

<!-- devrail:monitoring-observability -->

## Monitoring & Observability

Runtime monitoring and observability standards. For the full reference, see [`standards/monitoring-observability.md`](standards/monitoring-observability.md).

- **Health endpoints** -- `/healthz` (liveness) and `/readyz` (readiness) for every service
- **Structured logging** -- JSON format, correlation IDs, log levels (`debug`, `info`, `warn`, `error`)
- **RED metrics** -- Rate, Errors, Duration for every service; Prometheus-style exposition
- **Alerting** -- alert on symptoms not causes, every alert links to a runbook, minimize noise
- **Dashboards** -- one per service minimum, golden signals visible at a glance
- **Never log PII** -- no secrets, tokens, emails, or government IDs in logs; redact if unavoidable

<!-- /devrail:monitoring-observability -->

<!-- devrail:incident-response -->

## Incident Response

Incident detection, response, and learning standards. For the full reference, see [`standards/incident-response.md`](standards/incident-response.md).

- **Severity levels** -- SEV1 (15 min response) through SEV4 (1 business day)
- **Incident workflow** -- detect → triage → mitigate → resolve → post-mortem
- **Communication** -- status page updates, stakeholder notification cadence per severity
- **Post-mortems** -- required for SEV1-SEV2, blameless, concrete action items with owners and due dates
- **Runbooks** -- required for every production service, stored alongside code, reviewed quarterly
- **On-call** -- defined rotation, clean handoffs, escalation path documented

<!-- /devrail:incident-response -->

<!-- devrail:data-handling -->

## Data Handling

Data classification, privacy, and compliance standards. For the full reference, see [`standards/data-handling.md`](standards/data-handling.md).

- **Data classification** -- public, internal, confidential, restricted; classify at collection time
- **PII handling** -- identify, minimize collection, encrypt at rest and in transit, document what is collected
- **Retention** -- define periods per data type, automate deletion, support right-to-deletion requests
- **Backups** -- regular, tested restores, encrypted, offsite copy, automated
- **Encryption** -- TLS 1.2+ in transit, AES-256 at rest, keys managed via secrets manager
- **Compliance awareness** -- GDPR, CCPA, HIPAA, PCI DSS as applicable; breach notification process documented
- **Never log PII** -- redact or mask if logging is unavoidable; route to restricted log stream

<!-- /devrail:data-handling -->
