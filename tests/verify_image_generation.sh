#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENDPOINT='https://api.minimaxi.com/v1/image_generation'
WITH_API=false
IMAGE_MODELS=("image-01" "image-01-live")
IMAGE_PROMPT='a red fox sitting on a mossy stump, studio lighting, photorealistic'

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

check_image_mime() {
	local desc="$1"
	local path="$2"
	if ! command -v file >/dev/null 2>&1; then
		pass "$desc (跳过 MIME 检查: file 不可用)"
		return
	fi
	local mime
	mime="$(file -b --mime-type "$path" 2>/dev/null || true)"
	if printf '%s' "$mime" | grep -Eq '^image/'; then
		pass "$desc"
	else
		fail "$desc" "MIME 不是图片: ${mime:-unknown}"
	fi
}

load_api_key() {
	# Prefer an explicit environment variable; fall back to the shared CLI config file.
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

save_response_image() {
	local response_file="$1"
	local output_file="$2"
	# The API may return either base64 data or downloadable URLs, so normalize both cases here.
	python3 - "$response_file" "$output_file" <<'PY'
import base64
import json
import pathlib
import sys
import urllib.request

response_path = sys.argv[1]
output_path = pathlib.Path(sys.argv[2])

try:
	with open(response_path, 'r', encoding='utf-8') as handle:
		payload = json.load(handle)
except Exception as exc:
	print(f'ERROR:PARSE:{exc}')
	sys.exit(0)

if not payload:
	print('ERROR:EMPTY_RESPONSE')
	sys.exit(0)

base_resp = payload.get('base_resp') or {}
status_code = int(base_resp.get('status_code') or 0)
status_msg = str(base_resp.get('status_msg') or '')
if status_code != 0:
    print(f'ERROR:{status_code}:{status_msg}')
    sys.exit(0)

data = payload.get('data') or {}
images = data.get('image_base64') or []
if images:
    output_path.write_bytes(base64.b64decode(images[0]))
    print(f'SAVED:{output_path}')
    sys.exit(0)

for key in ('image_url', 'download_url', 'url'):
    candidate = data.get(key) or payload.get(key)
    if candidate:
        with urllib.request.urlopen(candidate) as response:
            output_path.write_bytes(response.read())
        print(f'DOWNLOADED:{output_path}')
        sys.exit(0)

print('NO_IMAGE_DATA')
PY
}

echo "========================================="
echo " 图片生成验证"
echo "========================================="

echo ""
echo "🔨 构建项目..."
bash "$REPO_ROOT/tests/build.sh" >/dev/null

# Keep all temporary API artifacts isolated and remove them on exit.
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

echo ""
# Offline coverage only checks local behavior and does not require a real API key.
echo "[1/3] 离线验收"
v -enable-globals test src/tools_test.v
check_contains "缺少 API Key 有明确提示" "$(MINIMAX_API_KEY='' "$REPO_ROOT/minimax_cli" -p 'test' 2>&1 || true)" "未配置 API Key"

echo ""
# These live checks stay opt-in so the script still works in offline or token-limited environments.
echo "[2/3] 真实 API 短文本烟雾测试"
if [[ "$WITH_API" == true ]]; then
	load_api_key
	if [[ -z "${MINIMAX_API_KEY:-}" ]]; then
		fail "真实 API 需要 MINIMAX_API_KEY" "未配置 API key"
		echo ""
		echo "结果: ${PASS} 通过, ${SKIP} 跳过, ${FAIL} 失败"
		exit 1
	fi

	short_dir="${TMP_ROOT}/short"
	mkdir -p "$short_dir"
	for model in "${IMAGE_MODELS[@]}"; do
		response_file="${short_dir}/${model}.json"
		image_file="${short_dir}/${model}.jpg"
		payload=$(cat <<JSON
{"model":"${model}","prompt":"${IMAGE_PROMPT}","response_format":"base64","n":1,"prompt_optimizer":false,"aigc_watermark":false}
JSON
)
		curl -sS "$ENDPOINT" -H "Authorization: Bearer ${MINIMAX_API_KEY}" -H 'Content-Type: application/json' -d "$payload" > "$response_file" || true
		result="$(save_response_image "$response_file" "$image_file" || true)"
		if printf '%s' "$result" | grep -Fqi 'ERROR:2061'; then
			skip "${model} 跳过" "当前 token plan 不支持该模型"
			continue
		fi
		if printf '%s' "$result" | grep -Fqi 'ERROR:'; then
			fail "${model} 返回图片" "$result"
			continue
		fi
		check_contains "${model} 返回保存结果" "$result" "SAVED:"
		check_file_exists "${model} 图片已落盘" "$image_file"
		check_nonempty_file "${model} 图片非空" "$image_file"
		check_image_mime "${model} 图片 MIME 合法" "$image_file"
	done
else
	echo "⏭  跳过真实 API 测试（加 --with-api 启用）"
fi

echo ""
# This exercises the image-to-image path that uses subject_reference payloads.
echo "[3/3] 图生图检查"
if [[ "$WITH_API" == true && -n "${MINIMAX_API_KEY:-}" ]]; then
	ref_dir="${TMP_ROOT}/ref"
	mkdir -p "$ref_dir"
	ref_response="${ref_dir}/reference.json"
	ref_image="${ref_dir}/reference.jpg"
	ref_payload=$(cat <<JSON
{"model":"image-01","prompt":"a fox wearing a scarf in a snowy forest","response_format":"base64","n":1,"prompt_optimizer":false,"aigc_watermark":false,"subject_reference":[{"type":"character","image_file":"https://cdn.hailuoai.com/prod/2025-08-12-17/video_cover/1754990600020238321-411603868533342214-cover.jpg"}]}
JSON
)
	curl -sS "$ENDPOINT" -H "Authorization: Bearer ${MINIMAX_API_KEY}" -H 'Content-Type: application/json' -d "$ref_payload" > "$ref_response" || true
	ref_result="$(save_response_image "$ref_response" "$ref_image" || true)"
	if printf '%s' "$ref_result" | grep -Fqi 'ERROR:2061'; then
		skip "图生图跳过" "当前 token plan 不支持图生图验证模型"
	elif printf '%s' "$ref_result" | grep -Fqi 'ERROR:'; then
		fail "图生图返回图片" "$ref_result"
	else
		check_contains "图生图返回保存结果" "$ref_result" "SAVED:"
		check_file_exists "图生图图片已落盘" "$ref_image"
		check_nonempty_file "图生图图片非空" "$ref_image"
		check_image_mime "图生图图片 MIME 合法" "$ref_image"
	fi
else
	echo "⏭  跳过图生图检查（加 --with-api 启用）"
fi

echo ""
echo "结果: ${PASS} 通过, ${SKIP} 跳过, ${FAIL} 失败"
if [[ "$FAIL" -ne 0 ]]; then
	exit 1
fi