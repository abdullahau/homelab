#!/usr/bin/env bash
# Installs the repo's git hooks. Run once per clone.
set -euo pipefail
cd "$(dirname "$0")/.."

install -m 755 scripts/pre-commit .git/hooks/pre-commit
echo "installed .git/hooks/pre-commit"

command -v gitleaks >/dev/null || echo "warning: gitleaks not installed (brew install gitleaks)" >&2
