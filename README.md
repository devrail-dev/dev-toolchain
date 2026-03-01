# dev-toolchain

> **Beta** -- DevRail is under active development. Standards, tooling, and container contents may change without notice. See [STABILITY.md](STABILITY.md) for details on what is ready and what is still in progress.

DevRail developer toolchain container image — a single Docker image containing all linters, formatters, security scanners, and test runners for Python, Bash, Terraform, and Ansible projects.

[![Build](https://github.com/devrail-dev/dev-toolchain/actions/workflows/build.yml/badge.svg)](https://github.com/devrail-dev/dev-toolchain/actions/workflows/build.yml)
[![CI](https://github.com/devrail-dev/dev-toolchain/actions/workflows/ci.yml/badge.svg)](https://github.com/devrail-dev/dev-toolchain/actions/workflows/ci.yml)

## Quick Start

1. Pull the image:
   ```bash
   docker pull ghcr.io/devrail-dev/dev-toolchain:v1
   ```

2. Run checks against your project:
   ```bash
   docker run --rm -v "$(pwd):/workspace" -w /workspace ghcr.io/devrail-dev/dev-toolchain:v1 make _check
   ```

3. Or use the Makefile in your DevRail-configured project:
   ```bash
   make check
   ```

## Usage

Run `make help` to see all available targets:

```
build                Build the container image locally
check                Run all checks (lint, format, security, scan, test)
format               Run formatters (shfmt on scripts)
help                 Show this help
lint                 Run linters (shellcheck on scripts)
scan                 Run vulnerability scan (trivy)
security             Run security checks (gitleaks)
test                 Run validation tests
```

## Included Tools

| Category   | Tools                                         |
|------------|-----------------------------------------------|
| Python     | ruff, bandit, semgrep, pytest, mypy            |
| Bash       | shellcheck, shfmt, bats                        |
| Terraform  | tflint, tfsec, checkov, terraform-docs, terraform |
| Ansible    | ansible-lint, molecule                         |
| Security   | trivy, gitleaks                                |

## Configuration

Projects configure their language support via `.devrail.yml`:

```yaml
languages:
  - python
  - bash
  - terraform
```

## Architecture

- **Base image:** Debian bookworm-slim (multi-arch: amd64 + arm64)
- **Go builder stage:** Compiles Go-based tools (tflint, terraform-docs, etc.)
- **Modular install scripts:** One script per language ecosystem
- **Shared libraries:** `lib/log.sh` (logging) and `lib/platform.sh` (platform detection)

## Contributing

See [DEVELOPMENT.md](DEVELOPMENT.md) for development setup and contributing guidelines.

To add a new language ecosystem, see the [Contributing to DevRail](../standards/contributing.md) guide.

## License

[MIT](LICENSE)
