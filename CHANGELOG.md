# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Initial repository structure with multi-stage Dockerfile
- Shared bash libraries (lib/log.sh, lib/platform.sh)
- Per-language install scripts (Python, Bash, Terraform, Ansible, Universal)
- Multi-arch build and GHCR publishing workflows
- Automated weekly builds with semver patch bump
- CI validation with self-check, trivy scan, and gitleaks
