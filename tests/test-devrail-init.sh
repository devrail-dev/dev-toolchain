#!/usr/bin/env bats
# Tests for devrail-init.sh

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts/devrail-init.sh"

setup() {
  TEST_DIR="$(mktemp -d)"
  cd "$TEST_DIR" || exit 1
  git init --quiet
}

teardown() {
  rm -rf "$TEST_DIR"
}

# --- Option parsing ---

@test "help flag exits 0" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "unknown option exits 1" {
  run "$SCRIPT" --bogus
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown option"* ]]
}

# --- Greenfield (all layers) ---

@test "greenfield creates all agent files" {
  run "$SCRIPT" --agents-only --yes
  [ "$status" -eq 0 ]
  [ -f "CLAUDE.md" ]
  [ -f "AGENTS.md" ]
  [ -f ".cursorrules" ]
  [ -f ".opencode/agents.yaml" ]
}

@test "greenfield creates .devrail.yml with specified languages" {
  run "$SCRIPT" --all --languages python,bash --ci github --yes
  [ "$status" -eq 0 ]
  [ -f ".devrail.yml" ]
  grep -q "python" .devrail.yml
  grep -q "bash" .devrail.yml
}

@test "greenfield creates pre-commit config with language hooks" {
  run "$SCRIPT" --all --languages python --ci github --yes
  [ "$status" -eq 0 ]
  [ -f ".pre-commit-config.yaml" ]
  grep -q "ruff" .pre-commit-config.yaml
  # Should NOT have bash hooks
  run grep -q "shellcheck" .pre-commit-config.yaml
  [ "$status" -ne 0 ]
}

@test "greenfield creates github CI workflows" {
  run "$SCRIPT" --all --languages python --ci github --yes
  [ "$status" -eq 0 ]
  [ -f ".github/workflows/lint.yml" ]
  [ -f ".github/workflows/format.yml" ]
  [ -f ".github/workflows/test.yml" ]
  [ -f ".github/workflows/security.yml" ]
  [ -f ".github/workflows/scan.yml" ]
  [ -f ".github/workflows/docs.yml" ]
  [ -f ".github/PULL_REQUEST_TEMPLATE.md" ]
  [ -f ".github/CODEOWNERS" ]
}

@test "greenfield creates gitlab CI files" {
  run "$SCRIPT" --all --languages python --ci gitlab --yes
  [ "$status" -eq 0 ]
  [ -f ".gitlab-ci.yml" ]
  [ -f ".gitlab/merge_request_templates/default.md" ]
  [ -f ".gitlab/CODEOWNERS" ]
  # Should NOT have github files
  [ ! -d ".github" ]
}

@test "greenfield downloads Makefile and DEVELOPMENT.md" {
  run "$SCRIPT" --all --languages python --ci github --yes
  [ "$status" -eq 0 ]
  [ -f "Makefile" ]
  [ -f "DEVELOPMENT.md" ]
  # Makefile should contain DevRail targets
  grep -q "make check" Makefile || grep -q "_check" Makefile
}

# --- Idempotency ---

@test "re-run skips all existing files" {
  "$SCRIPT" --all --languages python --ci github --yes >/dev/null 2>&1
  run "$SCRIPT" --all --languages python --ci github --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"Skipped"* ]]
  [[ "$output" != *"created:"* ]]
}

# --- Dry run ---

@test "dry-run creates no files" {
  run "$SCRIPT" --all --languages python --ci github --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"dry-run"* ]]
  [ ! -f "CLAUDE.md" ]
  [ ! -f "Makefile" ]
  [ ! -f ".devrail.yml" ]
}

# --- Agents-only ---

@test "agents-only creates only layer 1 files" {
  run "$SCRIPT" --agents-only --yes
  [ "$status" -eq 0 ]
  [ -f "CLAUDE.md" ]
  [ -f "AGENTS.md" ]
  [ ! -f "Makefile" ]
  [ ! -f ".pre-commit-config.yaml" ]
  [ ! -f ".devrail.yml" ]
}

# --- Makefile merge ---

@test "existing non-devrail Makefile is backed up" {
  echo -e 'build:\n\techo hello' >Makefile
  run "$SCRIPT" --all --languages python --ci github --force
  [ "$status" -eq 0 ]
  [ -f "Makefile.pre-devrail" ]
  grep -q "echo hello" Makefile.pre-devrail
}

# --- .gitignore append ---

@test "existing .gitignore gets DevRail patterns appended" {
  echo "node_modules/" >.gitignore
  run "$SCRIPT" --all --languages python --ci github --yes
  [ "$status" -eq 0 ]
  grep -q "node_modules/" .gitignore
  grep -q "DevRail" .gitignore
  grep -q ".devrail-output/" .gitignore
}

@test "existing .gitignore with DevRail marker is not re-appended" {
  printf 'node_modules/\n# --- DevRail ---\n.devrail-output/\n' >.gitignore
  local before
  before="$(wc -l <.gitignore)"
  run "$SCRIPT" --all --languages python --ci github --yes
  [ "$status" -eq 0 ]
  local after
  after="$(wc -l <.gitignore)"
  [ "$before" -eq "$after" ]
}

# --- Language-specific pre-commit hooks ---

@test "all 8 languages produce hooks in pre-commit config" {
  run "$SCRIPT" --all --languages python,bash,terraform,ruby,go,javascript,rust --ci github --yes
  [ "$status" -eq 0 ]
  grep -q "ruff" .pre-commit-config.yaml
  grep -q "shellcheck" .pre-commit-config.yaml
  grep -q "terraform_fmt" .pre-commit-config.yaml
  grep -q "rubocop" .pre-commit-config.yaml
  grep -q "golangci-lint" .pre-commit-config.yaml
  grep -q "eslint" .pre-commit-config.yaml
  grep -q "cargo-fmt" .pre-commit-config.yaml
}

# --- .devrail.yml reading ---

@test "reads existing .devrail.yml for languages" {
  cat >.devrail.yml <<'EOF'
languages:
  - go
  - rust
EOF
  run "$SCRIPT" --all --ci github --yes
  [ "$status" -eq 0 ]
  grep -q "golangci-lint" .pre-commit-config.yaml
  grep -q "cargo-fmt" .pre-commit-config.yaml
  # Should NOT have python hooks
  run grep -q "ruff" .pre-commit-config.yaml
  [ "$status" -ne 0 ]
}
