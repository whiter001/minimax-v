#!/bin/bash
# MCP demo 批量验证脚本
# 用法:
#   bash tests/mcp_demo_verify.sh
# 环境变量:
#   CLI_BIN            可执行文件路径（默认 ./minimax_cli）
#   MCP_DEMO_TIMEOUT   单条用例超时秒数（默认 180）

set +e

CLI_BIN="${CLI_BIN:-./minimax_cli}"
MCP_DEMO_TIMEOUT="${MCP_DEMO_TIMEOUT:-180}"

PASS=0
FAIL=0
TOTAL=0

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
    PASS=$((PASS+1))
    TOTAL=$((TOTAL+1))
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    FAIL=$((FAIL+1))
    TOTAL=$((TOTAL+1))
}

run_case() {
    local name="$1"
    local prompt="$2"
    local must_regex="$3"

    log_info "运行: ${name}"
    local output
    if command -v timeout >/dev/null 2>&1; then
        output=$(timeout "${MCP_DEMO_TIMEOUT}" "$CLI_BIN" --mcp -p "$prompt" 2>&1)
    else
        output=$("$CLI_BIN" --mcp -p "$prompt" 2>&1)
    fi
    local code=$?

    local ok=true
    local reason=""

    if [ $code -ne 0 ]; then
        ok=false
        reason="exit code=${code}"
    fi

    if echo "$output" | grep -q "❌ 错误\|API 连续失败\|MCP response timeout"; then
        ok=false
        if [ -n "$reason" ]; then
            reason="${reason}; fatal error in output"
        else
            reason="fatal error in output"
        fi
    fi

    if ! echo "$output" | grep -Eq "回答:|✅ Agent 完成任务"; then
        ok=false
        if [ -n "$reason" ]; then
            reason="${reason}; missing final answer marker"
        else
            reason="missing final answer marker"
        fi
    fi

    if ! echo "$output" | grep -Eq "$must_regex"; then
        ok=false
        if [ -n "$reason" ]; then
            reason="${reason}; missing expected semantic keywords"
        else
            reason="missing expected semantic keywords"
        fi
    fi

    if [ "$ok" = true ]; then
        log_pass "$name"
    else
        log_fail "$name (${reason})"
        echo "------ 输出前 80 行 ------"
        echo "$output" | head -80
        echo "--------------------------"
    fi
}

echo ""
echo "==========================================="
echo " MiniMax MCP Demo 批量验证"
echo "==========================================="

if [ ! -f "$CLI_BIN" ]; then
    log_fail "未找到可执行文件: $CLI_BIN"
    echo "请先执行: bash build.sh"
    exit 1
fi

if [ -z "${MINIMAX_API_KEY:-}" ] && [ ! -f "$HOME/.config/minimax/config" ]; then
    log_info "未检测到 MINIMAX_API_KEY，且配置文件不存在。请先配置 API Key。"
fi

# 1) 你提供的核心场景
run_case \
  "X 首页 10 条消息价值筛选" \
  "打开https://x.com/home获取10条消息，判断一下过滤出来对我最有价值的，然后用中文列出来告诉我具体内容" \
  "价值|最有价值|过滤|排序|理由"

# 2) 百度基础导航
run_case \
  "百度页面可见性确认" \
  "请使用 playwright 打开百度首页，并告诉我页面标题与首页主搜索框是否可见" \
  "百度|标题|搜索框|可见"

# 3) 天气摘要
run_case \
  "北京天气页面摘要" \
  "打开https://nmc.cn/publish/forecast/ABJ/beijing.html 总结未来几日的天气情况，并用中文分点列出" \
  "天气|气温|未来|温度|降水"

# 4) HN 列表价值排序
run_case \
  "HN 前10标题价值排序" \
  "打开https://news.ycombinator.com，提取前10条标题，按对开发者实用价值排序后用中文说明理由" \
  "开发者|价值|排序|理由|标题"

# 5) GitHub Trending 排序
run_case \
  "GitHub Trending 项目筛选" \
  "打开https://github.com/trending，提取前10个项目并按‘值得今天关注’排序，给出中文理由" \
  "项目|排序|关注|理由|GitHub"

echo ""
echo "==========================================="
echo " 结果: 总计 ${TOTAL}, 通过 ${PASS}, 失败 ${FAIL}"
echo "==========================================="

if [ $FAIL -eq 0 ]; then
    exit 0
else
    exit 1
fi
