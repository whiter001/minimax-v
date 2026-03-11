#!/bin/bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if ! git rev-parse --git-dir >/dev/null 2>&1; then
	echo "❌ Not inside a Git repository"
	exit 1
fi

chmod +x .githooks/pre-commit .githooks/pre-push
git config core.hooksPath .githooks

echo "✅ Git hooks installed"
echo "📍 core.hooksPath=$(git config --get core.hooksPath)"
echo "💡 Included hooks: pre-commit, pre-push"
