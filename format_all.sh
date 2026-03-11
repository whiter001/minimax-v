#!/bin/bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$repo_root"

find_cmd() {
	local name="$1"
	shift

	if command -v "$name" >/dev/null 2>&1; then
		command -v "$name"
		return 0
	fi

	local candidate
	for candidate in "$@"; do
		if [ -x "$candidate" ]; then
			echo "$candidate"
			return 0
		fi
	done

	return 1
}

v_bin="$(find_cmd v /opt/homebrew/bin/v /usr/local/bin/v)" || {
	echo "❌ V compiler not found. Please install V from https://vlang.io/"
	exit 1
}

oxfmt_bin="$(find_cmd oxfmt "$HOME/Library/pnpm/oxfmt" /opt/homebrew/bin/oxfmt /usr/local/bin/oxfmt)" || {
	echo "❌ oxfmt not found. Install it with: pnpm i -g oxfmt"
	exit 1
}

v_files=()
while IFS= read -r -d '' file; do
	v_files+=("$file")
done < <(git ls-files -z '*.v')

md_files=()
while IFS= read -r -d '' file; do
	md_files+=("$file")
done < <(git ls-files -z '*.md')

if [ "${#v_files[@]}" -gt 0 ]; then
	echo "🎨 Formatting V files..."
	"$v_bin" fmt -w "${v_files[@]}"
else
	echo "ℹ️ No V files found."
fi

if [ "${#md_files[@]}" -gt 0 ]; then
	echo "📝 Formatting Markdown files..."
	"$oxfmt_bin" --write "${md_files[@]}"
else
	echo "ℹ️ No Markdown files found."
fi

echo "✅ Formatting complete"