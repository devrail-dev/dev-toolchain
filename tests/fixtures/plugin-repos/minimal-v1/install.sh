#!/usr/bin/env bash
# Minimal install script — touches a sentinel file in its own directory so
# smoke tests can verify the script actually ran during docker build,
# regardless of which slug the test uses.
set -euo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd)"
echo "minimal plugin install ran" >"${script_dir}/.install-marker"
