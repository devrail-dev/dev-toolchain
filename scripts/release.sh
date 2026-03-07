#!/usr/bin/env bash
# scripts/release.sh — Cut a versioned release of dev-toolchain
#
# Purpose: Updates CHANGELOG.md, commits the changelog, creates a semver tag,
#          and pushes to origin. The tag push triggers the existing GitHub
#          Actions build and release workflows.
# Usage:   bash scripts/release.sh VERSION
#          VERSION is a semver string without the v prefix (e.g., 1.6.0)
# Dependencies: git, lib/log.sh
#
# This script runs on the HOST, not inside the container. It needs git push
# access to create and push tags.

set -euo pipefail

# --- Resolve library path ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVRAIL_LIB="${DEVRAIL_LIB:-${SCRIPT_DIR}/../lib}"

# Force human-readable output for interactive use (must be set before sourcing)
export DEVRAIL_LOG_FORMAT="${DEVRAIL_LOG_FORMAT:-human}"

# shellcheck source=../lib/log.sh
source "${DEVRAIL_LIB}/log.sh"

# --- Help ---
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  log_info "release.sh — Cut a versioned release of dev-toolchain"
  printf '\n' >&2
  log_info "Usage: bash scripts/release.sh VERSION"
  log_info "       make release VERSION=1.6.0"
  printf '\n' >&2
  log_info "  VERSION  Semver version without v prefix (e.g., 1.6.0)"
  printf '\n' >&2
  log_info "What this script does:"
  log_info "  1. Validates preconditions (on main, clean state, valid semver)"
  log_info "  2. Updates CHANGELOG.md (moves [Unreleased] to new version)"
  log_info "  3. Commits with: chore(release): prepare vX.Y.Z"
  log_info "  4. Creates annotated tag vX.Y.Z"
  log_info "  5. Pushes commit and tag (triggers build + release workflows)"
  printf '\n' >&2
  log_info "When to use:"
  log_info "  New language ecosystem  → minor bump (e.g., 1.6.0)"
  log_info "  New tool or feature     → minor bump (e.g., 1.6.0)"
  log_info "  Bug fix                 → patch bump (e.g., 1.5.1)"
  log_info "  Breaking change         → major bump (e.g., 2.0.0)"
  log_info "  Routine weekly rebuild  → automatic (no manual action needed)"
  exit 0
fi

# --- Parse version argument ---
VERSION="${1:-}"
if is_empty "${VERSION}"; then
  die "VERSION argument required. Usage: bash scripts/release.sh 1.6.0"
fi

# Strip v prefix if accidentally provided
VERSION="${VERSION#v}"

# Validate semver format (MAJOR.MINOR.PATCH only, no pre-release)
if ! [[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  die "Invalid semver: '${VERSION}'. Expected format: MAJOR.MINOR.PATCH (e.g., 1.6.0)"
fi

TAG="v${VERSION}"

# --- Precondition checks ---

require_cmd "git" "git is required"

# Must be on main branch
CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "${CURRENT_BRANCH}" != "main" ]]; then
  die "Must be on main branch (currently on '${CURRENT_BRANCH}')"
fi

# Must have clean working tree
if ! git diff --quiet || ! git diff --cached --quiet; then
  die "Working tree is not clean. Commit or stash changes first."
fi

# Tag must not already exist
if git rev-parse "${TAG}" &>/dev/null; then
  die "Tag '${TAG}' already exists"
fi

# Must be up to date with remote
git fetch origin main --quiet
LOCAL_SHA="$(git rev-parse HEAD)"
REMOTE_SHA="$(git rev-parse origin/main)"
if [[ "${LOCAL_SHA}" != "${REMOTE_SHA}" ]]; then
  die "Local main is not up to date with origin/main. Run 'git pull' first."
fi

log_info "Preconditions passed for release ${TAG}"

# --- Update CHANGELOG.md ---

CHANGELOG="CHANGELOG.md"
TODAY="$(date -u +%Y-%m-%d)"

if [[ ! -f "${CHANGELOG}" ]]; then
  die "${CHANGELOG} not found"
fi

# Verify [Unreleased] section exists
if ! grep -q '## \[Unreleased\]' "${CHANGELOG}"; then
  die "No [Unreleased] section found in ${CHANGELOG}"
fi

# Check that there's actual content under [Unreleased]
UNRELEASED_CONTENT="$(sed -n '/^## \[Unreleased\]/,/^## \[/{/^## \[/!p}' "${CHANGELOG}" | grep -v '^$' || true)"
if is_empty "${UNRELEASED_CONTENT}"; then
  die "No entries under [Unreleased] in ${CHANGELOG}. Nothing to release."
fi

log_info "Updating ${CHANGELOG} for ${TAG}"

# Insert new version header after [Unreleased], preserving unreleased section for future use
sed -i "s/^## \[Unreleased\]$/## [Unreleased]\n\n## [${VERSION}] - ${TODAY}/" "${CHANGELOG}"

log_info "CHANGELOG.md updated: [Unreleased] entries moved under [${VERSION}] - ${TODAY}"

# --- Commit, tag, and push ---

git add "${CHANGELOG}"

COMMIT_MSG="chore(release): prepare ${TAG}"
log_info "Committing: ${COMMIT_MSG}"
git commit -m "${COMMIT_MSG}"

log_info "Creating tag: ${TAG}"
git tag -a "${TAG}" -m "Release ${TAG}"

# Confirm before push
log_info "Ready to push commit and tag '${TAG}' to origin."
log_info "This will trigger the build and release workflows."
printf '\n  Push to origin? [y/N] ' >&2
read -r CONFIRM
if [[ "${CONFIRM}" != "y" && "${CONFIRM}" != "Y" ]]; then
  log_warn "Aborted. Commit and tag created locally but NOT pushed."
  log_warn "To push manually: git push origin main && git push origin ${TAG}"
  exit 0
fi

log_info "Pushing to origin..."
git push origin main
git push origin "${TAG}"

MAJOR="$(echo "${VERSION}" | cut -d. -f1)"
log_info "Release ${TAG} pushed successfully"
printf '\n' >&2
log_info "GitHub Actions will now:"
log_info "  1. Build and publish the container image to GHCR"
log_info "  2. Create a GitHub release with release notes"
log_info "  3. Update the v${MAJOR} floating tag"
log_info "  4. Generate and attach the tool version manifest"
