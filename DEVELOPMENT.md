# dev-toolchain Development Guide

This document describes how to develop on the dev-toolchain repository. The dev-toolchain container is the single source of truth for all tool versions in the DevRail ecosystem.

This project follows [DevRail](https://devrail.dev) development standards. For the canonical reference, see the root [DEVELOPMENT.md](../DEVELOPMENT.md) in the devrail-standards repo.

---

<!-- devrail:critical-rules -->

## Critical Rules

These six rules are non-negotiable. Every developer and every AI agent must follow them without exception.

1. **Run `make check` before completing any story or task.** Never mark work done without passing checks. This is the single gate for all linting, formatting, security, and test validation.

2. **Use conventional commits.** Every commit message follows the `type(scope): description` format. No exceptions. Scopes for this repo: `container`, `python`, `bash`, `terraform`, `ansible`, `security`, `ci`.

3. **Never install tools outside the container.** All linters, formatters, scanners, and test runners live inside the dev-toolchain container image. The Makefile delegates to Docker.

4. **Respect `.editorconfig`.** Never override formatting rules (indent style, line endings, trailing whitespace) without explicit instruction.

5. **Write idempotent scripts.** Every script must be safe to re-run. Check before acting: `command -v tool || install_tool`, `mkdir -p`, guard file writes with existence checks.

6. **Use the shared logging library.** No raw `echo` for status messages. Use `log_info`, `log_warn`, `log_error`, `log_debug`, and `die` from `lib/log.sh`.

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
| `make docs` | Generate documentation |
| `make check` | Run all of the above in sequence |
| `make install-hooks` | Install pre-commit hooks |

## Repository Structure

```
dev-toolchain/
├── Dockerfile              # Multi-stage container build
├── Makefile                # Two-layer delegation Makefile
├── .devrail.yml            # DevRail project configuration
├── scripts/                # Per-language install scripts
│   ├── install-python.sh
│   ├── install-bash.sh
│   ├── install-terraform.sh
│   ├── install-ansible.sh
│   └── install-universal.sh
├── lib/                    # Shared bash libraries
│   ├── log.sh
│   └── platform.sh
└── tests/                  # Tool installation verification tests
    ├── test-python.sh
    ├── test-bash.sh
    ├── test-terraform.sh
    ├── test-ansible.sh
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

See the [Contributing a Language Ecosystem](../standards/contributing-a-language.md) guide for the step-by-step process.

## Conventional Commits

Scopes for this repository:

| Scope | Usage |
|---|---|
| `container` | Dockerfile, base image, multi-arch build |
| `python` | Python tool installation |
| `bash` | Bash tool installation |
| `terraform` | Terraform tool installation |
| `ansible` | Ansible tool installation |
| `security` | Security tool installation (trivy, gitleaks) |
| `ci` | CI/CD workflows |

Examples:
- `feat(python): add ruff linter to install script`
- `fix(container): resolve arm64 build failure`
- `chore(ci): update build workflow to use latest actions`
