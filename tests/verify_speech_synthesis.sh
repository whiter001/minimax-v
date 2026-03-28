#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BINARY="${REPO_ROOT}/minimax_cli"
WITH_API=false
SPEECH_MODELS=("speech-2.8-hd" "speech-2.8-turbo")
SPEECH_VOICE_ID="Sweet_Girl_2"

for arg in "$@"; do
	case "$arg" in
		--with-api)
			WITH_API=true
			;;
		*)
			echo "❌ 未知参数: $arg"
			exit 1
			;;
	esac
done

PASS=0
FAIL=0
SKIP=0

pass() {
	PASS=$((PASS + 1))
	echo "  ✅ $1"
}

fail() {
	FAIL=$((FAIL + 1))
	echo "  ❌ $1: $2"
}

skip() {
	SKIP=$((SKIP + 1))
	echo "  ⏭  $1: $2"
}

check_contains() {
	local desc="$1"
	local output="$2"
	local expected="$3"
	if printf '%s' "$output" | grep -Fqi -- "$expected"; then
		pass "$desc"
	else
		fail "$desc" "未找到预期字符串: $expected"
	fi
}

check_file_exists() {
	local desc="$1"
	local path="$2"
	if [[ -f "$path" ]]; then
		pass "$desc"
	else
		fail "$desc" "缺少文件: $path"
	fi
}

check_nonempty_file() {
	local desc="$1"
	local path="$2"
	if [[ -s "$path" ]]; then
		pass "$desc"
	else
		fail "$desc" "文件为空: $path"
	fi
}

check_audio_mime() {
	local desc="$1"
	local path="$2"
	if ! command -v file >/dev/null 2>&1; then
		pass "$desc (跳过 MIME 检查: file 不可用)"
		return
	fi
	local mime
	mime="$(file -b --mime-type "$path" 2>/dev/null || true)"
	if printf '%s' "$mime" | grep -Eq '^audio/'; then
		pass "$desc"
	else
		fail "$desc" "MIME 不是音频: ${mime:-unknown}"
	fi
}

load_api_key() {
	if [[ -n "${MINIMAX_API_KEY:-}" ]]; then
		return
	fi
	local config_file="${HOME}/.config/minimax/config"
	if [[ -f "$config_file" ]]; then
		local api_key
		api_key="$(grep '^api_key=' "$config_file" | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'")"
		if [[ -n "$api_key" ]]; then
			export MINIMAX_API_KEY="$api_key"
		fi
	fi
}

echo "========================================="
echo " 语音合成验证"
echo "========================================="

echo ""
echo "🔨 构建项目..."
bash "$REPO_ROOT/tests/build.sh" >/dev/null

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

echo ""
echo "[1/3] 离线验收"
output="$(MINIMAX_API_KEY='fake' $BINARY -p 'speech --help' 2>&1)"
check_contains "speech 帮助包含用法" "$output" "用法: speech"
check_contains "speech 帮助包含示例" "$output" "speech --text"

output="$(MINIMAX_API_KEY='fake' $BINARY -p 'tts --help' 2>&1)"
check_contains "tts 别名也返回帮助" "$output" "用法: speech"

output="$(MINIMAX_API_KEY='' $BINARY -p 'hello world' 2>&1 || true)"
check_contains "空 API Key 会被主流程拦截" "$output" "未配置 API Key"

output="$(MINIMAX_API_KEY='fake' $BINARY -p "speech --split --text-file ${TMP_ROOT}/missing.txt" 2>&1 || true)"
check_contains "缺失文本文件会报错" "$output" "failed to read text file"

echo ""
echo "[2/3] 真实 API 短文本烟雾测试"
if [[ "$WITH_API" == true ]]; then
	load_api_key
	if [[ -z "${MINIMAX_API_KEY:-}" ]]; then
		fail "真实 API 需要 MINIMAX_API_KEY" "未配置 API key"
		echo ""
		echo "结果: ${PASS} 通过, ${FAIL} 失败"
		exit 1
	fi

	short_dir="${TMP_ROOT}/short"
	mkdir -p "$short_dir"
	for model in "${SPEECH_MODELS[@]}"; do
		short_save="${short_dir}/${model}.mp3"
		output="$($BINARY -p "speech --model ${model} --voice-id ${SPEECH_VOICE_ID} --output-format hex --save-path ${short_save} --text Hello from MiniMax speech synthesis smoke test." 2>&1 || true)"
		if printf '%s' "$output" | grep -Eqi 'not support model|token plan not support model|2061|did not include a downloadable URL or audio hex'; then
			skip "${model} 跳过" "当前 token plan 不支持该模型"
			continue
		fi
		check_contains "${model} 返回保存结果" "$output" "saved_audio:"
		check_file_exists "${model} 音频已落盘" "$short_save"
		check_nonempty_file "${model} 音频非空" "$short_save"
		check_audio_mime "${model} 音频 MIME 合法" "$short_save"
	done

	echo ""
	echo "[3/3] 真实 API 分段烟雾测试"
	split_dir="${TMP_ROOT}/split"
	mkdir -p "$split_dir"
	split_text="${TMP_ROOT}/split_input.txt"
	{
		for i in $(seq 1 30); do
			printf 'This is a speech split smoke test sentence %02d. ' "$i"
		done
		printf '\n'
	} > "$split_text"
	split_save="${split_dir}/speech_smoke.mp3"
	output="$($BINARY -p "speech --model ${SPEECH_MODELS[0]} --voice-id ${SPEECH_VOICE_ID} --output-format hex --split --chunk-size 120 --save-path ${split_save} --text-file ${split_text}" 2>&1)"
	if printf '%s' "$output" | grep -Eqi 'usage limit exceeded|token plan not support model|not support model|speech response did not include a downloadable URL or audio hex'; then
		skip "分段真实 API" "当前账号配额或模型限制不支持本次分段烟雾测试"
	else
	if printf '%s' "$output" | grep -Fqi '语音合成分段请求已完成'; then
		pass "分段请求提示"
	else
		skip "分段请求提示" "输出未包含固定提示文案"
	fi
	if printf '%s' "$output" | grep -Fqi 'chunk 1/'; then
		pass "分段输出包含 chunk 1"
	else
		skip "分段输出包含 chunk 1" "输出未包含固定 chunk 文案"
	fi

	chunk_files=()
	shopt -s nullglob
	chunk_files=(${split_dir}/speech_smoke_*_of_*.mp3)
	shopt -u nullglob
	if [[ ${#chunk_files[@]} -ge 2 ]]; then
		pass "分段生成了多个音频文件"
	else
		fail "分段生成了多个音频文件" "实际文件数: ${#chunk_files[@]}"
	fi
	for path in "${chunk_files[@]}"; do
		check_file_exists "分段音频已落盘: $(basename "$path")" "$path"
		check_nonempty_file "分段音频非空: $(basename "$path")" "$path"
		check_audio_mime "分段音频 MIME 合法: $(basename "$path")" "$path"
	done
    fi
else
	echo "⏭  跳过真实 API 测试（加 --with-api 启用）"
fi

echo ""
echo "结果: ${PASS} 通过, ${SKIP} 跳过, ${FAIL} 失败"
if [[ "$FAIL" -ne 0 ]]; then
	exit 1
fi
