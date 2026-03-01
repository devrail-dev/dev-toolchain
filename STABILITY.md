# Stability

DevRail has reached **v1.0** across all repositories. The core standards, toolchain, templates, and documentation are stable and in production use. This document tracks component status.

## What "v1.0" Means

- **Backward compatibility.** Breaking changes require a major version bump (`v2.0.0`). Minor and patch releases are additive.
- **Stable interfaces.** Makefile targets, `.devrail.yml` schema, and CLI behavior are committed contracts.
- **New languages are additive.** Adding a language ecosystem is a minor version bump — existing languages and behavior are unaffected.
- **Feedback is welcome.** File issues, open discussions, or submit PRs.

## Status by Component

| Component | Status | Notes |
|---|---|---|
| **Container image** | Stable | Multi-arch (amd64 + arm64), signed with cosign, weekly rebuilds. |
| **Makefile contract** | Stable | Two-layer delegation pattern, JSON summary output, `init` scaffolding. |
| **Shell conventions** | Stable | `lib/log.sh`, `lib/platform.sh`, header format, and idempotency patterns are settled. |
| **Conventional commits** | Stable | Types, scopes, and format are finalized. Pre-commit hook published. |
| **Language standards** | Stable | Python, Bash, Terraform, Ansible, Ruby, Go, JavaScript/TypeScript — all 7 ecosystems shipped. |
| **Coding practices** | Stable | General principles (DRY, KISS, testing, error handling) are finalized. |
| **Git workflow** | Stable | Branch strategy, PR process, and merge policy are finalized. |
| **Release & versioning** | Stable | Semver policy is defined and in use across all repos. |
| **CI/CD pipelines** | Stable | Stage contract defined. GitHub Actions and GitLab CI templates shipped. |
| **Container standards** | Stable | Guidelines are written. |
| **Secrets management** | Stable | Policy is defined. No custom tooling required. |
| **API & CLI design** | Stable | Guidelines are written. No custom tooling required. |
| **Monitoring & observability** | Stable | Guidelines are written. No custom tooling required. |
| **Incident response** | Stable | Process is defined. Templates are provided. |
| **Data handling** | Stable | Policy is defined. No custom tooling required. |
| **CI workflow templates** | Stable | GitHub Actions workflows and GitLab CI pipeline shipped in template repos. |
| **Pre-commit hooks** | Stable | Conventional commit hook and per-language hooks configured in template repos. |
| **Documentation site** | Stable | [devrail.dev](https://devrail.dev) is live with full standards coverage. |

## Versioning

All DevRail repos follow [Semantic Versioning](https://semver.org/). The container image uses a floating major tag (`:v1`) that always points to the latest `v1.x.x` release. Pin to a specific tag (e.g., `:v1.4.0`) if you need exact reproducibility.

## How to Track Changes

- Watch the [CHANGELOG.md](CHANGELOG.md) in each repo for release-by-release details.
- Breaking changes will be called out explicitly in changelog entries during beta.
