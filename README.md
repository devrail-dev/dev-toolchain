# dev-toolchain

> DevRail `v1` is stable. See [STABILITY.md](STABILITY.md) for component status.

DevRail developer toolchain container image — a single Docker image containing all linters, formatters, security scanners, and test runners for Python, Bash, Terraform, Ansible, Ruby, Go, and JavaScript/TypeScript projects.

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
format               Run formatters for declared languages
help                 Show this help
init                 Scaffold config files for declared languages
lint                 Run linters for declared languages
scan                 Run universal scanning (trivy, gitleaks)
security             Run language-specific security scanners
test                 Run project test suite
```

## Included Tools

| Category       | Tools                                             |
|----------------|---------------------------------------------------|
| Python         | ruff, bandit, semgrep, pytest, mypy               |
| Bash           | shellcheck, shfmt, bats                           |
| Terraform      | tflint, tfsec, checkov, terraform-docs, terraform |
| Ansible        | ansible-lint, molecule                            |
| Ruby           | rubocop, reek, brakeman, bundler-audit, rspec, sorbet |
| Go             | golangci-lint, gofumpt, govulncheck, go test      |
| JavaScript/TS  | eslint, prettier, typescript, vitest, npm audit   |
| Security       | trivy, gitleaks                                   |

## Configuration

Projects configure their language support via `.devrail.yml`:

```yaml
languages:
  - python
  - bash
  - terraform
  - ansible
  - ruby
  - go
  - javascript
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
