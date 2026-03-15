#!/bin/bash

set -euo pipefail

echo "🎨 Checking V formatting..."

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

v_bin="$(find_cmd v /opt/homebrew/bin/v /usr/local/bin/v "$HOME/bin/v" "$HOME/.local/bin/v")" || {
	echo "❌ V compiler not found. Please install V from https://vlang.io/"
	exit 1
}

v_files=()
while IFS= read -r file; do
	v_files+=("$file")
done < <(git ls-files '*.v')
if [ "${#v_files[@]}" -eq 0 ]; then
	echo "ℹ️ No V files found."
	exit 0
fi

"$v_bin" fmt -verify "${v_files[@]}"

echo "✅ V formatting check passed"
