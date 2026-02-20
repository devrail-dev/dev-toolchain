# Stability

DevRail is in **beta** (`v0.x`). The project is under active development. This document tracks what is ready for use, what is in progress, and what is planned.

## What "Beta" Means

- **Standards may change.** Section content, naming, and structure may be revised as we learn from real-world usage.
- **Tooling may change.** Tool versions, container contents, and Makefile targets may be updated without prior deprecation.
- **No backward-compatibility guarantee.** Until `v1.0.0`, any release may include breaking changes. Pin to a specific tag if you need stability.
- **Feedback is welcome.** File issues, open discussions, or submit PRs. Early adopters shape the final product.

## Status by Component

| Component | Status | Notes |
|---|---|---|
| **Container image** | Beta | Builds and runs. Tool versions are unpinned (`@latest`); will be pinned before v1. |
| **Makefile contract** | Beta | Two-layer delegation pattern works. Target names and behavior are stabilizing. |
| **Shell conventions** | Stable | `lib/log.sh`, `lib/platform.sh`, header format, and idempotency patterns are settled. |
| **Conventional commits** | Stable | Types, scopes, and format are finalized. |
| **Language standards** | Beta | Python, Bash, Terraform, Ansible tool selections are set. Configuration details may shift. |
| **Coding practices** | Stable | General principles (DRY, KISS, testing, error handling) are finalized. |
| **Git workflow** | Stable | Branch strategy, PR process, and merge policy are finalized. |
| **Release & versioning** | Beta | Semver policy is defined. Automated release tooling is not yet implemented. |
| **CI/CD pipelines** | Beta | Stage contract is defined. Reusable workflow templates are not yet published. |
| **Container standards** | Beta | Guidelines are written. Enforcement tooling is not yet integrated. |
| **Secrets management** | Stable | Policy is defined. No custom tooling required. |
| **API & CLI design** | Stable | Guidelines are written. No custom tooling required. |
| **Monitoring & observability** | Stable | Guidelines are written. No custom tooling required. |
| **Incident response** | Stable | Process is defined. Templates are provided. |
| **Data handling** | Stable | Policy is defined. No custom tooling required. |
| **CI workflow templates** | Not started | Reusable GitHub Actions / GitLab CI templates are planned. |
| **Pre-commit hooks** | Beta | Conventional commit hook works. Additional hooks planned. |
| **Documentation site** | Beta | devrail.dev is live but content is being backfilled. |

## Versioning

All DevRail repos use `v0.x.y` during beta. The `0.x` range signals that breaking changes may occur in any release, per [Semantic Versioning](https://semver.org/) conventions.

Once the core standards, toolchain image, and CI templates are stable and validated in production use, we will release `v1.0.0` and commit to backward compatibility.

## How to Track Changes

- Watch the [CHANGELOG.md](CHANGELOG.md) in each repo for release-by-release details.
- Breaking changes will be called out explicitly in changelog entries during beta.
