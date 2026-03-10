#!/usr/bin/env bash
# devrail-init.sh — Progressive DevRail adoption script
# Usage: curl -fsSL https://devrail.dev/init.sh | bash
#    or: ./devrail-init.sh [options]
#
# Generates DevRail configuration files in the current directory.
# Safe to re-run — existing files are never silently overwritten.
#
# See: https://devrail.dev/docs/getting-started/

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
DEVRAIL_VERSION="${DEVRAIL_VERSION:-v1}"
DEVRAIL_RAW_URL="https://raw.githubusercontent.com/devrail-dev/github-repo-template/main"
DEVRAIL_MARKER="# --- DevRail ---"
ALL_LANGUAGES="python bash terraform ansible ruby go javascript rust"

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
LANGUAGES=""
CI_PLATFORM=""
OPT_ALL=false
OPT_AGENTS_ONLY=false
OPT_YES=false
OPT_FORCE=false
OPT_DRY_RUN=false
LAYER_1=false
LAYER_2=false
LAYER_3=false
LAYER_4=false

CREATED=()
SKIPPED=()
BACKED_UP=()

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info() { printf '\033[0;32m✓\033[0m %s\n' "$1"; }
warn() { printf '\033[0;33m⚠\033[0m %s\n' "$1"; }
error() { printf '\033[0;31m✗\033[0m %s\n' "$1" >&2; }
ask() { printf '\033[0;36m?\033[0m %s ' "$1"; }

# Read user input from /dev/tty so interactive mode works when piped via
# curl | bash (where stdin is consumed by the script content).
prompt_read() {
  read -r "$@" </dev/tty
}

die() {
  error "$1"
  exit 1
}

# Write a file if it doesn't exist (or handle conflict).
# Usage: scaffold <path> <content>
scaffold() {
  local path="$1"
  local content="$2"
  local dir

  dir="$(dirname "$path")"
  if [ "$dir" != "." ] && [ ! -d "$dir" ]; then
    if $OPT_DRY_RUN; then
      info "[dry-run] would create directory: $dir"
    else
      mkdir -p "$dir"
    fi
  fi

  if [ -f "$path" ]; then
    if $OPT_FORCE; then
      if $OPT_DRY_RUN; then
        info "[dry-run] would overwrite: $path"
      else
        printf '%s\n' "$content" >"$path"
        info "overwritten: $path"
      fi
      CREATED+=("$path")
    elif $OPT_YES; then
      SKIPPED+=("$path")
    else
      ask "$path exists. [s]kip / [o]verwrite / [b]ackup+overwrite?"
      local choice
      prompt_read choice
      case "$choice" in
      o | O)
        if $OPT_DRY_RUN; then
          info "[dry-run] would overwrite: $path"
        else
          printf '%s\n' "$content" >"$path"
          info "overwritten: $path"
        fi
        CREATED+=("$path")
        ;;
      b | B)
        if $OPT_DRY_RUN; then
          info "[dry-run] would backup and overwrite: $path"
        else
          cp "$path" "${path}.pre-devrail"
          BACKED_UP+=("${path}.pre-devrail")
          printf '%s\n' "$content" >"$path"
          info "backed up to ${path}.pre-devrail, overwritten: $path"
        fi
        CREATED+=("$path")
        ;;
      *)
        SKIPPED+=("$path")
        ;;
      esac
    fi
  else
    if $OPT_DRY_RUN; then
      info "[dry-run] would create: $path"
    else
      printf '%s\n' "$content" >"$path"
      info "created: $path"
    fi
    CREATED+=("$path")
  fi
}

# Download a file from the template repo.
# Usage: download_file <remote_path> <local_path>
download_file() {
  local remote_path="$1"
  local local_path="$2"
  local content

  if ! content="$(curl -fsSL "${DEVRAIL_RAW_URL}/${remote_path}" 2>/dev/null)"; then
    error "failed to download: ${remote_path}"
    return 1
  fi

  scaffold "$local_path" "$content"
}

# Check if a language is in the LANGUAGES list.
has_language() {
  local lang="$1"
  case " $LANGUAGES " in
  *" $lang "*) return 0 ;;
  *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
  cat <<'USAGE'
Usage: devrail-init.sh [options]

Progressive DevRail adoption — add standards to any project.

Options:
  --languages <list>  Comma-separated languages (python,bash,terraform,ansible,ruby,go,javascript,rust)
  --ci <platform>     CI platform: github, gitlab, none
  --all               Install all layers (agent + hooks + makefile + ci)
  --agents-only       Install only agent instruction files (Layer 1)
  --yes, -y           Accept defaults non-interactively (skip existing files)
  --force             Overwrite existing files without prompting
  --dry-run           Show what would be created without writing
  --version <tag>     Container image tag (default: v1)
  --help, -h          Show this help

Layers:
  1. Agent files     CLAUDE.md, AGENTS.md, .cursorrules, .opencode/
  2. Pre-commit      .pre-commit-config.yaml
  3. Makefile        Makefile, .devrail.yml, DEVELOPMENT.md, .editorconfig
  4. CI pipeline     GitHub Actions or GitLab CI workflows

Examples:
  devrail-init.sh --agents-only              # Partial adoption (wedge)
  devrail-init.sh --all --ci github -y       # Full greenfield (non-interactive)
  devrail-init.sh --languages python,bash    # Interactive layer selection

USAGE
}

# ---------------------------------------------------------------------------
# Option Parsing
# ---------------------------------------------------------------------------
parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
    --languages)
      shift
      LANGUAGES="$(echo "$1" | tr ',' ' ')"
      ;;
    --ci)
      shift
      CI_PLATFORM="$1"
      ;;
    --all)
      OPT_ALL=true
      ;;
    --agents-only)
      OPT_AGENTS_ONLY=true
      ;;
    --yes | -y)
      OPT_YES=true
      ;;
    --force)
      OPT_FORCE=true
      ;;
    --dry-run)
      OPT_DRY_RUN=true
      ;;
    --version)
      shift
      DEVRAIL_VERSION="$1"
      ;;
    --help | -h)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1 (use --help for usage)"
      ;;
    esac
    shift
  done
}

# ---------------------------------------------------------------------------
# Interactive Prompts
# ---------------------------------------------------------------------------
prompt_languages() {
  if [ -n "$LANGUAGES" ]; then
    return
  fi

  # Check for existing .devrail.yml
  if [ -f ".devrail.yml" ]; then
    LANGUAGES="$(grep -E '^\s+-\s+\w' .devrail.yml | sed 's/.*-\s*//' | tr '\n' ' ')"
    if [ -n "$LANGUAGES" ]; then
      info "read languages from .devrail.yml: $LANGUAGES"
      return
    fi
  fi

  if $OPT_YES; then
    warn "no languages specified and no .devrail.yml found — skipping language-specific config"
    return
  fi

  echo ""
  echo "Which languages does this project use?"
  echo ""
  local i=1
  for lang in $ALL_LANGUAGES; do
    printf '  %d. %s\n' "$i" "$lang"
    i=$((i + 1))
  done
  echo ""
  ask "Enter numbers separated by spaces (e.g. 1 2 5), or 'none':"
  local choices
  prompt_read choices

  if [ "$choices" = "none" ] || [ -z "$choices" ]; then
    return
  fi

  for num in $choices; do
    local lang
    lang="$(echo "$ALL_LANGUAGES" | tr ' ' '\n' | sed -n "${num}p")"
    if [ -n "$lang" ]; then
      LANGUAGES="$LANGUAGES $lang"
    fi
  done
  LANGUAGES="$(echo "$LANGUAGES" | xargs)"
}

prompt_ci_platform() {
  if [ -n "$CI_PLATFORM" ]; then
    return
  fi

  if $OPT_YES; then
    CI_PLATFORM="none"
    return
  fi

  echo ""
  ask "CI platform? [g]ithub / [l]ab (GitLab) / [n]one:"
  local choice
  prompt_read choice
  case "$choice" in
  g | G | github) CI_PLATFORM="github" ;;
  l | L | gitlab) CI_PLATFORM="gitlab" ;;
  *) CI_PLATFORM="none" ;;
  esac
}

prompt_layers() {
  if $OPT_ALL; then
    LAYER_1=true
    LAYER_2=true
    LAYER_3=true
    LAYER_4=true
    return
  fi

  if $OPT_AGENTS_ONLY; then
    LAYER_1=true
    return
  fi

  if $OPT_YES; then
    LAYER_1=true
    LAYER_2=true
    LAYER_3=true
    LAYER_4=true
    return
  fi

  echo ""
  echo "DevRail adopts progressively. Choose what to add:"
  echo ""

  ask "1. Agent standards — CLAUDE.md, AGENTS.md, .cursorrules, .opencode/ [Y/n]"
  local c1
  prompt_read c1
  [ "$c1" != "n" ] && [ "$c1" != "N" ] && LAYER_1=true

  ask "2. Pre-commit hooks — .pre-commit-config.yaml [Y/n]"
  local c2
  prompt_read c2
  [ "$c2" != "n" ] && [ "$c2" != "N" ] && LAYER_2=true

  ask "3. Makefile + container — Makefile, .devrail.yml, DEVELOPMENT.md [Y/n]"
  local c3
  prompt_read c3
  [ "$c3" != "n" ] && [ "$c3" != "N" ] && LAYER_3=true

  ask "4. CI pipeline — GitHub Actions or GitLab CI [Y/n]"
  local c4
  prompt_read c4
  [ "$c4" != "n" ] && [ "$c4" != "N" ] && LAYER_4=true
}

# ---------------------------------------------------------------------------
# Layer 1: Agent Instruction Files
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016
install_layer_1() {
  info "Layer 1: Agent instruction files"

  scaffold "CLAUDE.md" '# Project Standards

This project follows [DevRail](https://devrail.dev) development standards.
See DEVELOPMENT.md for the complete reference.

## Critical Rules

1. **Run `make check` before completing any story or task.** Never mark work done without passing checks. This is the single gate for all linting, formatting, security, and test validation.
2. **Use conventional commits.** Every commit message follows the `type(scope): description` format. No exceptions.
3. **Never install tools outside the container.** All linters, formatters, scanners, and test runners live inside `ghcr.io/devrail-dev/dev-toolchain:'"$DEVRAIL_VERSION"'`. The Makefile delegates to Docker. Do not install tools on the host.
4. **Respect `.editorconfig`.** Never override formatting rules (indent style, line endings, trailing whitespace) without explicit instruction.
5. **Write idempotent scripts.** Every script must be safe to re-run. Check before acting: `command -v tool || install_tool`, `mkdir -p`, guard file writes with existence checks.
6. **Use the shared logging library.** No raw `echo` for status messages. Use `log_info`, `log_warn`, `log_error`, `log_debug`, and `die` from `lib/log.sh`.
7. **Never suppress failing checks.** When a lint, format, security, or test check fails, fix the underlying issue. Never comment out code, add suppression annotations, disable rules, or mark CI jobs as allowed-to-fail to bypass a failing check.
8. **Update documentation when changing behavior.** When a change affects public interfaces, configuration, CLI usage, or setup steps, update the relevant documentation (README, DEVELOPMENT.md, inline docs) in the same commit or PR. Do not leave documentation out of sync with code.

## Quick Reference

- Run `make check` to validate all standards
- Run `make help` to see available targets
- All tools run inside the dev-toolchain container'

  scaffold "AGENTS.md" '# Agent Instructions

This project follows [DevRail](https://devrail.dev) development standards.
See DEVELOPMENT.md for the complete reference.

## Critical Rules

1. **Run `make check` before completing any story or task.** Never mark work done without passing checks. This is the single gate for all linting, formatting, security, and test validation.
2. **Use conventional commits.** Every commit message follows the `type(scope): description` format. No exceptions.
3. **Never install tools outside the container.** All linters, formatters, scanners, and test runners live inside `ghcr.io/devrail-dev/dev-toolchain:'"$DEVRAIL_VERSION"'`. The Makefile delegates to Docker. Do not install tools on the host.
4. **Respect `.editorconfig`.** Never override formatting rules (indent style, line endings, trailing whitespace) without explicit instruction.
5. **Write idempotent scripts.** Every script must be safe to re-run. Check before acting: `command -v tool || install_tool`, `mkdir -p`, guard file writes with existence checks.
6. **Use the shared logging library.** No raw `echo` for status messages. Use `log_info`, `log_warn`, `log_error`, `log_debug`, and `die` from `lib/log.sh`.
7. **Never suppress failing checks.** When a lint, format, security, or test check fails, fix the underlying issue. Never comment out code, add suppression annotations, disable rules, or mark CI jobs as allowed-to-fail to bypass a failing check.
8. **Update documentation when changing behavior.** When a change affects public interfaces, configuration, CLI usage, or setup steps, update the relevant documentation (README, DEVELOPMENT.md, inline docs) in the same commit or PR. Do not leave documentation out of sync with code.

## Quick Reference

- Run `make check` to validate all standards
- Run `make help` to see available targets
- All tools run inside the dev-toolchain container'

  scaffold ".cursorrules" 'This project follows DevRail development standards.
See DEVELOPMENT.md for the complete reference.

Critical Rules:

1. Run `make check` before completing any story or task. Never mark work done
   without passing checks. This is the single gate for all linting, formatting,
   security, and test validation.
2. Use conventional commits. Every commit message follows the
   `type(scope): description` format. No exceptions.
3. Never install tools outside the container. All linters, formatters, scanners,
   and test runners live inside `ghcr.io/devrail-dev/dev-toolchain:'"$DEVRAIL_VERSION"'`. The
   Makefile delegates to Docker. Do not install tools on the host.
4. Respect `.editorconfig`. Never override formatting rules (indent style, line
   endings, trailing whitespace) without explicit instruction.
5. Write idempotent scripts. Every script must be safe to re-run. Check before
   acting: `command -v tool || install_tool`, `mkdir -p`, guard file writes with
   existence checks.
6. Use the shared logging library. No raw `echo` for status messages. Use
   `log_info`, `log_warn`, `log_error`, `log_debug`, and `die` from
   `lib/log.sh`.
7. Never suppress failing checks. When a lint, format, security, or test
   check fails, fix the underlying issue. Never comment out code, add
   suppression annotations, disable rules, or mark CI jobs as
   allowed-to-fail to bypass a failing check.
8. Update documentation when changing behavior. When a change affects
   public interfaces, configuration, CLI usage, or setup steps, update
   the relevant documentation (README, DEVELOPMENT.md, inline docs) in
   the same commit or PR. Do not leave documentation out of sync with
   code.

Quick Reference:

- Run `make check` to validate all standards
- Run `make help` to see available targets
- All tools run inside the dev-toolchain container'

  scaffold ".opencode/agents.yaml" 'agents:
  - name: devrail
    description: DevRail development standards
    instructions: |
      This project follows DevRail development standards.
      See DEVELOPMENT.md for the complete reference.

      Critical Rules:

      1. Run `make check` before completing any story or task. Never mark work
         done without passing checks. This is the single gate for all linting,
         formatting, security, and test validation.
      2. Use conventional commits. Every commit message follows the
         `type(scope): description` format. No exceptions.
      3. Never install tools outside the container. All linters, formatters,
         scanners, and test runners live inside
         `ghcr.io/devrail-dev/dev-toolchain:'"$DEVRAIL_VERSION"'`. The Makefile delegates to
         Docker. Do not install tools on the host.
      4. Respect `.editorconfig`. Never override formatting rules (indent style,
         line endings, trailing whitespace) without explicit instruction.
      5. Write idempotent scripts. Every script must be safe to re-run. Check
         before acting: `command -v tool || install_tool`, `mkdir -p`, guard
         file writes with existence checks.
      6. Use the shared logging library. No raw `echo` for status messages. Use
         `log_info`, `log_warn`, `log_error`, `log_debug`, and `die` from
         `lib/log.sh`.
      7. Never suppress failing checks. When a lint, format, security, or test
         check fails, fix the underlying issue. Never comment out code, add
         suppression annotations, disable rules, or mark CI jobs as
         allowed-to-fail to bypass a failing check.
      8. Update documentation when changing behavior. When a change affects
         public interfaces, configuration, CLI usage, or setup steps, update
         the relevant documentation (README, DEVELOPMENT.md, inline docs) in
         the same commit or PR. Do not leave documentation out of sync with
         code.

      Quick Reference:

      - Run `make check` to validate all standards
      - Run `make help` to see available targets
      - All tools run inside the dev-toolchain container'
}

# ---------------------------------------------------------------------------
# Layer 2: Pre-Commit Hooks
# ---------------------------------------------------------------------------
generate_precommit_config() {
  local config='# .pre-commit-config.yaml — DevRail pre-commit hooks
# Install: make install-hooks
# Docs: https://pre-commit.com/

repos:
  # --- Conventional Commits ---
  - repo: https://github.com/devrail-dev/pre-commit-conventional-commits
    rev: v1.1.0
    hooks:
      - id: conventional-commits'

  if has_language python; then
    config="$config"'

  # --- Python ---
  - repo: https://github.com/astral-sh/ruff-pre-commit
    rev: v0.9.7
    hooks:
      - id: ruff
        args: [--fix]
      - id: ruff-format'
  fi

  if has_language bash; then
    config="$config"'

  # --- Bash ---
  - repo: https://github.com/shellcheck-py/shellcheck-py
    rev: v0.10.0.1
    hooks:
      - id: shellcheck
  - repo: https://github.com/scop/pre-commit-shfmt
    rev: v3.9.0-1
    hooks:
      - id: shfmt
        args: [--diff]'
  fi

  if has_language terraform; then
    config="$config"'

  # --- Terraform ---
  - repo: https://github.com/antonbabenko/pre-commit-terraform
    rev: v1.96.3
    hooks:
      - id: terraform_fmt
      - id: terraform_tflint
      # Uncomment if using Terragrunt:
      # - id: terragrunt_fmt'
  fi

  if has_language ruby; then
    config="$config"'

  # --- Ruby ---
  - repo: https://github.com/rubocop/rubocop
    rev: v1.73.2
    hooks:
      - id: rubocop'
  fi

  if has_language go; then
    config="$config"'

  # --- Go ---
  - repo: https://github.com/golangci/golangci-lint
    rev: v2.1.6
    hooks:
      - id: golangci-lint-full'
  fi

  if has_language javascript; then
    config="$config"'

  # --- JavaScript/TypeScript ---
  - repo: https://github.com/pre-commit/mirrors-eslint
    rev: v9.27.0
    hooks:
      - id: eslint
        additional_dependencies:
          - eslint
          - "@eslint/js"
          - typescript-eslint
          - typescript
  - repo: https://github.com/pre-commit/mirrors-prettier
    rev: v4.0.0-alpha.8
    hooks:
      - id: prettier'
  fi

  if has_language rust; then
    config="$config"'

  # --- Rust ---
  - repo: https://github.com/AndrejOrsula/pre-commit-cargo
    rev: v0.4.0
    hooks:
      - id: cargo-fmt
        args: ["--all", "--", "--check"]
      - id: cargo-clippy
        args: ["--all-targets", "--all-features", "--workspace", "--", "-D", "warnings"]'
  fi

  config="$config"'

  # --- Secret Detection ---
  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.22.1
    hooks:
      - id: gitleaks

  # --- Pre-Push: Full Check Gate ---
  - repo: local
    hooks:
      - id: make-check
        name: make check
        entry: make check
        language: system
        always_run: true
        pass_filenames: false
        stages: [pre-push]'

  echo "$config"
}

install_layer_2() {
  info "Layer 2: Pre-commit hooks"

  # Check for pre-commit
  if ! command -v pre-commit >/dev/null 2>&1; then
    warn "pre-commit is not installed. Install it with: pip install pre-commit"
    warn "After installing, run: make install-hooks"
  fi

  local config
  config="$(generate_precommit_config)"
  scaffold ".pre-commit-config.yaml" "$config"
}

# ---------------------------------------------------------------------------
# Layer 3: Makefile + Container
# ---------------------------------------------------------------------------
generate_devrail_yml() {
  local yml='# .devrail.yml — DevRail project configuration

languages:'

  if [ -n "$LANGUAGES" ]; then
    for lang in $LANGUAGES; do
      yml="$yml
  - $lang"
    done
  else
    yml="$yml"'
  # - python
  # - bash
  # - terraform
  # - ansible
  # - ruby
  # - go
  # - javascript
  # - rust'
  fi

  yml="$yml"'

# fail_fast: false          # default: false (run-all-report-all)
# log_format: json          # default: json | options: json, human'

  echo "$yml"
}

install_makefile() {
  if [ ! -f "Makefile" ]; then
    # No existing Makefile — download fresh
    download_file "Makefile" "Makefile"
    return
  fi

  # Check for DevRail markers
  if grep -q "$DEVRAIL_MARKER" Makefile 2>/dev/null; then
    info "Makefile already contains DevRail targets — updating"
    if $OPT_DRY_RUN; then
      info "[dry-run] would update DevRail section in Makefile"
      CREATED+=("Makefile")
    else
      download_file "Makefile" "Makefile.devrail-new"
      if [ -f "Makefile.devrail-new" ]; then
        cp Makefile Makefile.pre-devrail
        BACKED_UP+=("Makefile.pre-devrail")
        mv Makefile.devrail-new Makefile
        info "updated Makefile (backup: Makefile.pre-devrail)"
        CREATED+=("Makefile")
      fi
    fi
    return
  fi

  # Non-DevRail Makefile — backup and replace with include guidance
  if $OPT_DRY_RUN; then
    info "[dry-run] would backup Makefile and install DevRail Makefile"
    CREATED+=("Makefile")
    return
  fi

  if ! $OPT_FORCE && ! $OPT_YES; then
    warn "existing Makefile detected (not DevRail-managed)"
    ask "Backup to Makefile.pre-devrail and install DevRail Makefile? [Y/n]"
    local choice
    prompt_read choice
    if [ "$choice" = "n" ] || [ "$choice" = "N" ]; then
      SKIPPED+=("Makefile")
      return
    fi
  elif $OPT_YES; then
    SKIPPED+=("Makefile")
    return
  fi

  cp Makefile Makefile.pre-devrail
  BACKED_UP+=("Makefile.pre-devrail")
  download_file "Makefile" "Makefile"
  info "original Makefile backed up to Makefile.pre-devrail"
  echo ""
  warn "Your original Makefile targets are in Makefile.pre-devrail."
  warn "To include them, add this at the bottom of the new Makefile:"
  warn "  -include Makefile.pre-devrail"
}

install_gitignore() {
  if [ ! -f ".gitignore" ]; then
    download_file ".gitignore" ".gitignore"
    return
  fi

  # Append DevRail patterns if not already present
  if grep -q "$DEVRAIL_MARKER" .gitignore 2>/dev/null; then
    SKIPPED+=(".gitignore")
    return
  fi

  if $OPT_DRY_RUN; then
    info "[dry-run] would append DevRail patterns to .gitignore"
    CREATED+=(".gitignore")
    return
  fi

  cat >>.gitignore <<'GITIGNORE'

# --- DevRail ---
.devrail-output/
GITIGNORE
  info "appended DevRail patterns to .gitignore"
  CREATED+=(".gitignore")
}

install_layer_3() {
  info "Layer 3: Makefile + container"

  # .devrail.yml
  if [ -f ".devrail.yml" ]; then
    SKIPPED+=(".devrail.yml")
  else
    local yml
    yml="$(generate_devrail_yml)"
    scaffold ".devrail.yml" "$yml"
  fi

  # Makefile (special merge handling)
  install_makefile

  # DEVELOPMENT.md (download — too large to embed)
  download_file "DEVELOPMENT.md" "DEVELOPMENT.md"

  # .editorconfig
  scaffold ".editorconfig" 'root = true

[*]
charset = utf-8
end_of_line = lf
insert_final_newline = true
trim_trailing_whitespace = true
indent_style = space
indent_size = 2

[Makefile]
indent_style = tab

[*.py]
indent_size = 4

[*.sh]
indent_size = 2'

  # .gitignore (special append handling)
  install_gitignore

  # .gitleaksignore
  scaffold ".gitleaksignore" '# .gitleaksignore — Gitleaks false positive allowlist
#
# When gitleaks flags a false positive (e.g., example tokens in docs,
# content hashes, or test fixtures), add its fingerprint here.
#
# To find the fingerprint, run:
#   make scan
# or inside the container:
#   gitleaks detect -v
#
# Copy the "Fingerprint" value for the finding you want to allow.
# Format: <file>:<rule>:<line>
#
# See: https://github.com/gitleaks/gitleaks#configuration'
}

# ---------------------------------------------------------------------------
# Layer 4: CI Pipeline
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016
install_github_ci() {
  local workflow_template='# %s workflow — runs %s via the dev-toolchain container.
name: %s

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  %s:
    runs-on: ubuntu-latest
    container:
      image: ghcr.io/devrail-dev/dev-toolchain:%s
    steps:
      - uses: actions/checkout@v4%s
      - name: Run %s
        run: make _%s'

  local targets="lint format test security scan docs"
  for target in $targets; do
    local extra_steps=""
    if [ "$target" = "scan" ]; then
      extra_steps='
        with:
          fetch-depth: 0'
    fi

    local name
    name="${target^}"
    local desc="all ${target}s"
    case "$target" in
    lint) desc="all linters" ;;
    format) desc="all formatters" ;;
    test) desc="all tests" ;;
    security) desc="security scanners" ;;
    scan) desc="universal scanners (trivy, gitleaks)" ;;
    docs) desc="documentation generation and validation" ;;
    esac

    local content
    # shellcheck disable=SC2059
    content="$(printf "$workflow_template" "$name" "$desc" "$name" "$target" "$DEVRAIL_VERSION" "$extra_steps" "$target" "$target")"
    scaffold ".github/workflows/${target}.yml" "$content"
  done

  scaffold ".github/PULL_REQUEST_TEMPLATE.md" '## Summary

<!-- Brief description of the changes -->

## Changes

<!-- List the key changes made -->

-

## Related Issues

<!-- Link related issues: Closes #123, Relates to #456 -->

## Test Plan

<!-- How were these changes tested? -->

- [ ] `make check` passes
- [ ] Manual testing completed (describe below)

## Checklist

- [ ] Code follows project standards (see DEVELOPMENT.md)
- [ ] All commits use conventional commit format
- [ ] Documentation updated (if applicable)
- [ ] CHANGELOG.md updated (if applicable)
- [ ] No secrets or credentials in the changeset'

  scaffold ".github/CODEOWNERS" '# .github/CODEOWNERS
# GitHub Code Owners file
# Docs: https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-code-owners
#
# Each line defines a file pattern and the users/teams responsible.
# The last matching pattern takes precedence.
#
# Examples:
# * @default-team
# Makefile @devops-team
# .github/ @devops-team
# .devrail.yml @devops-team
# *.py @python-team
# *.tf @infra-team'
}

# shellcheck disable=SC2016
install_gitlab_ci() {
  scaffold ".gitlab-ci.yml" '# .gitlab-ci.yml — DevRail CI pipeline
# Runs parallel check jobs using the dev-toolchain container.

image: ghcr.io/devrail-dev/dev-toolchain:'"$DEVRAIL_VERSION"'

stages:
  - check

lint:
  stage: check
  script:
    - make _lint
  artifacts:
    paths:
      - .devrail-output/
    expire_in: 1 week
    when: always

format:
  stage: check
  script:
    - make _format
  artifacts:
    paths:
      - .devrail-output/
    expire_in: 1 week
    when: always

security:
  stage: check
  script:
    - make _security
  artifacts:
    paths:
      - .devrail-output/
    expire_in: 1 week
    when: always

test:
  stage: check
  script:
    - make _test
  artifacts:
    paths:
      - .devrail-output/
    expire_in: 1 week
    when: always

scan:
  stage: check
  script:
    - make _scan
  artifacts:
    paths:
      - .devrail-output/
    expire_in: 1 week
    when: always

docs:
  stage: check
  script:
    - make _docs
  artifacts:
    paths:
      - .devrail-output/
    expire_in: 1 week
    when: always'

  scaffold ".gitlab/merge_request_templates/default.md" '## Summary

<!-- Brief description of the changes -->

## Changes

<!-- List the key changes made -->

-

## Related Issues

<!-- Link related issues: Closes #123, Relates to #456 -->

## Test Plan

<!-- How were these changes tested? -->

- [ ] `make check` passes
- [ ] Manual testing completed (describe below)

## Checklist

- [ ] Code follows project standards (see DEVELOPMENT.md)
- [ ] All commits use conventional commit format
- [ ] Documentation updated (if applicable)
- [ ] CHANGELOG.md updated (if applicable)
- [ ] No secrets or credentials in the changeset'

  scaffold ".gitlab/CODEOWNERS" '# .gitlab/CODEOWNERS
# GitLab Code Owners file
# Docs: https://docs.gitlab.com/ee/user/project/codeowners/
#
# Each line defines a file pattern and the users/teams responsible.
# The last matching pattern takes precedence.
#
# Examples:
# * @default-team
# Makefile @devops-team
# .gitlab-ci.yml @devops-team
# .devrail.yml @devops-team
# *.py @python-team
# *.tf @infra-team'
}

install_layer_4() {
  info "Layer 4: CI pipeline"

  case "$CI_PLATFORM" in
  github)
    install_github_ci
    ;;
  gitlab)
    install_gitlab_ci
    ;;
  none | "")
    warn "no CI platform selected — skipping Layer 4"
    ;;
  *)
    error "unknown CI platform: $CI_PLATFORM"
    ;;
  esac
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print_summary() {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  if $OPT_DRY_RUN; then
    echo "  Dry run complete (no files written)"
  else
    echo "  DevRail init complete"
  fi

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  if [ ${#CREATED[@]} -gt 0 ]; then
    echo ""
    if $OPT_DRY_RUN; then
      echo "  Would create:"
    else
      echo "  Created:"
    fi
    for f in "${CREATED[@]}"; do
      echo "    $f"
    done
  fi

  if [ ${#SKIPPED[@]} -gt 0 ]; then
    echo ""
    echo "  Skipped (already exists):"
    for f in "${SKIPPED[@]}"; do
      echo "    $f"
    done
  fi

  if [ ${#BACKED_UP[@]} -gt 0 ]; then
    echo ""
    echo "  Backups:"
    for f in "${BACKED_UP[@]}"; do
      echo "    $f"
    done
  fi

  echo ""
  if ! $OPT_DRY_RUN; then
    echo "  Next steps:"
    if $LAYER_3; then
      echo "    1. Run 'make check' to validate"
      echo "    2. Run 'make init' to scaffold tool configs (ruff.toml, etc.)"
    fi
    if $LAYER_2 && command -v pre-commit >/dev/null 2>&1; then
      echo "    3. Run 'make install-hooks' to activate pre-commit hooks"
    fi
  fi
  echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"

  echo ""
  echo "  DevRail Init"
  echo "  https://devrail.dev"
  echo ""

  # Gather inputs
  if $LAYER_3 || $LAYER_2 || $LAYER_4 || ! $OPT_AGENTS_ONLY; then
    prompt_languages
  fi
  if $LAYER_4 || ($OPT_ALL && [ -z "$CI_PLATFORM" ]); then
    prompt_ci_platform
  fi
  prompt_layers

  # Execute layers
  echo ""
  $LAYER_1 && install_layer_1
  $LAYER_2 && install_layer_2
  $LAYER_3 && install_layer_3
  $LAYER_4 && install_layer_4

  print_summary
}

main "$@"
