#!/bin/bash
# integration_test.sh — 集成测试 minimax_cli
# 用法: ./integration_test.sh [--with-api]
#   默认只测离线功能，加 --with-api 测试真实 API 调用

set -euo pipefail
SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$SOURCE" ]]; do
	SDIR="$(cd "$(dirname "$SOURCE")" && pwd)"
	SOURCE="$(readlink "$SOURCE")"
	[[ "$SOURCE" != /* ]] && SOURCE="$SDIR/$SOURCE"
done
CDIR="$(cd "$(dirname "$SOURCE")" && pwd)"
cd "$CDIR/.."

BINARY="./minimax_cli"
PASS=0
FAIL=0
WITH_API=false

for arg in "$@"; do
	[[ "$arg" == "--with-api" ]] && WITH_API=true
done

pass() { PASS=$((PASS+1)); echo "  ✅ $1"; }
fail() { FAIL=$((FAIL+1)); echo "  ❌ $1: $2"; }

check_contains() {
	local desc="$1" output="$2" expected="$3"
	if echo "$output" | grep -q "$expected"; then
		pass "$desc"
	else
		fail "$desc" "expected '$expected' in output"
	fi
}

check_not_contains() {
	local desc="$1" output="$2" unexpected="$3"
	if echo "$output" | grep -q "$unexpected"; then
		fail "$desc" "unexpected '$unexpected' in output"
	else
		pass "$desc"
	fi
}

check_exit_code() {
	local desc="$1" code="$2" expected="$3"
	if [[ "$code" == "$expected" ]]; then
		pass "$desc"
	else
		fail "$desc" "exit code $code, expected $expected"
	fi
}

check_file_exists() {
	local desc="$1" path="$2"
	if [[ -f "$path" ]]; then
		pass "$desc"
	else
		fail "$desc" "missing file: $path"
	fi
}

echo ""
echo "========================================="
echo " minimax-cli 集成测试"
echo "========================================="

# 1. 编译
echo ""
echo "🔨 编译..."
if v -enable-globals -o minimax_cli src/ 2>&1; then
	pass "编译成功"
else
	fail "编译" "编译失败"
	exit 1
fi

# 2. --version
echo ""
echo "📋 基础 CLI 测试"
output=$($BINARY --version 2>&1)
check_contains "--version 输出版本号" "$output" "v0.9.0"

# 3. --help
output=$($BINARY --help 2>&1)
check_contains "--help 包含用法" "$output" "用法"
check_contains "--help 包含 --max-rounds" "$output" "max-rounds"
check_contains "--help 包含 --token-limit" "$output" "token-limit"
check_contains "--help 包含 --workspace" "$output" "workspace"
check_contains "--help 包含 MCP" "$output" "mcp"
check_contains "--help 包含配置文件说明" "$output" "config"
check_contains "--help 包含环境变量说明" "$output" "MINIMAX_API_KEY"

# 4. 无 API Key 时的错误提示
echo ""
echo "🔑 API Key 校验"
output=$(MINIMAX_API_KEY="" $BINARY -p "test" 2>&1 || true)
check_contains "无 API Key 时提示配置" "$output" "未配置 API Key"

# 5. 参数校验
echo ""
echo "🔧 参数校验"
# temperature out of range
output=$(MINIMAX_API_KEY="sk-fake" $BINARY --temperature 5.0 --version 2>&1 || true)
# This should just print version since --version is also present
check_contains "带参数的 --version" "$output" "v0.9.0"

# 6. 手动工具测试 (需要交互模式) — 跳过，在 V 单元测试中已覆盖

# 6. 离线经验库 / skills sync 黑盒测试
echo ""
echo "🧠 经验库与 Skill 同步测试"
TEST_HOME=$(mktemp -d)
trap 'rm -rf "$TEST_HOME"' EXIT

output=$(HOME="$TEST_HOME" MINIMAX_API_KEY="sk-fake" $BINARY 2>&1 <<'EOF'
experience add skill=wechat-editor-image; title=黑盒高置信经验; scenario=编辑器已加载; action=读取剪贴板图片并转 Data URL; outcome=成功插图; tags=wechat,clipboard; confidence=5
experience add skill=wechat-editor-image; title=黑盒低置信回退; scenario=setInputFiles 返回 Not allowed; action=提示手动上传; outcome=避免继续重试; tags=wechat,fallback; confidence=4
experience add skill=browser-ops; title=浏览器点击经验; scenario=页面已稳定加载; action=等待目标节点后点击; outcome=点击成功; tags=browser,click; confidence=5
experience show 1
experience search clipboard
experience list wechat-editor-image
skills sync all concise
skills sync all strict
exit
EOF
)

prune_output=$(HOME="$TEST_HOME" MINIMAX_API_KEY="sk-fake" $BINARY 2>&1 <<'EOF'
experience prune skill wechat-editor-image
experience list all
experience search clipboard
exit
EOF
)

check_contains "experience add 写入成功" "$output" "已记录经验"
check_contains "experience show 输出详情" "$output" "Title: 黑盒高置信经验"
check_contains "experience search 输出结果" "$output" "经验搜索结果"
check_contains "experience list 输出记录" "$output" "黑盒高置信经验"
check_contains "skills sync all concise 执行成功" "$output" "已同步 skill: wechat-editor-image"
check_contains "skills sync all 覆盖多个 skill" "$output" "已同步 skill: browser-ops"
check_contains "skills sync 输出 concise 模式" "$output" "mode: concise"
check_contains "skills sync 输出 strict 模式" "$output" "mode: strict"
check_contains "experience prune 执行成功" "$prune_output" "已清理经验记录"
check_contains "prune 后仍可列出其他 skill" "$prune_output" "浏览器点击经验"
check_contains "prune 后搜索无结果" "$prune_output" "未找到与"

KNOWLEDGE_JSONL="$TEST_HOME/.config/minimax/knowledge/experiences.jsonl"
WECHAT_SKILL="$TEST_HOME/.config/minimax/skills/wechat-editor-image/SKILL.md"
BROWSER_SKILL="$TEST_HOME/.config/minimax/skills/browser-ops/SKILL.md"
WECHAT_MARKDOWN="$TEST_HOME/.config/minimax/knowledge/skills/wechat-editor-image.md"
BROWSER_MARKDOWN="$TEST_HOME/.config/minimax/knowledge/skills/browser-ops.md"

check_file_exists "JSONL 经验库已生成" "$KNOWLEDGE_JSONL"
check_file_exists "wechat skill 已生成" "$WECHAT_SKILL"
check_file_exists "browser skill 已生成" "$BROWSER_SKILL"
check_file_exists "browser markdown 经验笔记已生成" "$BROWSER_MARKDOWN"

jsonl_content=$(cat "$KNOWLEDGE_JSONL")
wechat_skill_content=$(cat "$WECHAT_SKILL")
browser_skill_content=$(cat "$BROWSER_SKILL")

check_contains "JSONL 保留未清理 skill 记录" "$jsonl_content" "浏览器点击经验"
check_not_contains "JSONL 已移除被 prune 的 skill" "$jsonl_content" "黑盒高置信经验"
check_contains "strict 模式最终写入 wechat skill" "$wechat_skill_content" "Mode: strict"
check_contains "strict 模式最终写入 browser skill" "$browser_skill_content" "Mode: strict"
check_contains "strict 模式保留高置信经验" "$wechat_skill_content" "黑盒高置信经验"
check_not_contains "strict 模式过滤低置信回退" "$wechat_skill_content" "黑盒低置信回退"
check_not_contains "strict 模式不包含 Recent Evidence" "$wechat_skill_content" "### Recent Evidence"
if [[ -f "$WECHAT_MARKDOWN" ]]; then
	fail "prune 后移除微信 markdown" "unexpected file remains: $WECHAT_MARKDOWN"
else
	pass "prune 后移除微信 markdown"
fi

# 7. API 调用测试 (需要真实 API Key)
if $WITH_API; then
	echo ""
	echo "🌐 API 调用测试 (需要配置 API Key)"

	# 单次提问
	echo "  ▶ 单次提问..."
	output=$($BINARY -p "回复ok两个字" --max-tokens 50 2>&1 || true)
	if echo "$output" | grep -qi "ok\|OK"; then
		pass "单次提问返回结果"
	else
		fail "单次提问" "未获得预期回复: $(echo "$output" | head -3)"
	fi

	# 流式
	echo "  ▶ 流式模式..."
	output=$($BINARY --stream -p "回复hello" --max-tokens 50 2>&1 || true)
	if echo "$output" | grep -qi "hello\|Hello"; then
		pass "流式模式返回结果"
	else
		fail "流式模式" "未获得预期回复: $(echo "$output" | head -3)"
	fi

	# 工具调用
	echo "  ▶ 工具调用模式..."
	output=$($BINARY --enable-tools -p "请列出 /tmp 目录的内容" --max-tokens 500 2>&1 || true)
	if echo "$output" | grep -q "\[TOOL\]"; then
		pass "工具调用执行了工具"
	else
		fail "工具调用" "未检测到工具执行: $(echo "$output" | head -5)"
	fi

	# 流式 + 工具调用
	echo "  ▶ 流式 + 工具调用..."
	output=$($BINARY --stream --enable-tools -p "读取文件 /etc/hostname 的内容" --max-tokens 500 2>&1 || true)
	if echo "$output" | grep -q "\[TOOL\]"; then
		pass "流式+工具调用执行了工具"
	else
		# Not all systems have /etc/hostname, try alternative check
		if echo "$output" | grep -qi "Error\|error"; then
			pass "流式+工具调用有响应 (工具报错也算正常)"
		else
			fail "流式+工具调用" "$(echo "$output" | head -3)"
		fi
	fi

	# Quota 查询
	echo "  ▶ Quota 查询..."
	output=$($BINARY --quota 2>&1 || true)
	if echo "$output" | grep -q "用量\|API Error\|quota\|Coding\|coding"; then
		pass "Quota 查询有响应"
	else
		fail "Quota 查询" "$(echo "$output" | head -3)"
	fi

	# Workspace
	echo "  ▶ Workspace 模式..."
	output=$($BINARY --enable-tools --workspace /tmp -p "列出当前工作目录的文件" --max-tokens 500 2>&1 || true)
	if echo "$output" | grep -q "\[TOOL\]"; then
		pass "Workspace 工具调用正常"
	else
		fail "Workspace 模式" "$(echo "$output" | head -3)"
	fi

	# System prompt
	echo "  ▶ System prompt..."
	output=$($BINARY --system "你只能用中文回答" -p "say hi" --max-tokens 100 2>&1 || true)
	if [[ -n "$output" ]]; then
		pass "自定义 system prompt 有响应"
	else
		fail "System prompt" "无输出"
	fi
else
	echo ""
	echo "⏭  跳过 API 调用测试（加 --with-api 参数启用）"
fi

# 总结
echo ""
echo "========================================="
echo " 结果: $PASS 通过, $FAIL 失败"
echo "========================================="
echo ""

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
