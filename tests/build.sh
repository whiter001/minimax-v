#!/bin/bash

set -e

echo "🔨 Building MiniMax V-Lang CLI..."

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

# Enforce formatting before building
if [ -f "./tests/check_vfmt.sh" ]; then
    bash ./tests/check_vfmt.sh
fi

# Build from src/
echo "📦 Compiling from src/..."
"$v_bin" -o minimax_cli src/

echo "✅ Build complete!"
echo "📍 Binary: ./minimax_cli"
echo "💡 Try: ./minimax_cli -p \"你好\""
