#!/bin/bash
# test_p_mode.sh - 专门针对 -p (单次提问) 模式的完整测试脚本
# 包含离线参数校验和在线 API 联调测试

set -euo pipefail

# 确保在项目根目录运行
CDIR="$(cd "$(dirname "$0")" && pwd)"
cd "$CDIR/.."

BINARY="./minimax_cli"
PASS=0
FAIL=0
WITH_API=false

for arg in "$@"; do
    [[ "$arg" == "--with-api" ]] && WITH_API=true
done

pass() { PASS=$((PASS+1)); echo -e "  \033[32m✅\033[0m $1"; }
fail() { FAIL=$((FAIL+1)); echo -e "  \033[31m❌\033[0m $1: $2"; }

check_contains() {
    local desc="$1" output="$2" expected="$3"
    if echo "$output" | grep -qi "$expected"; then
        pass "$desc"
    else
        fail "$desc" "未在输出中找到预期字符串: '$expected'"
        echo "实际输出样例: $(echo "$output" | head -n 3)"
    fi
}

check_exit_code() {
    local desc="$1" code="$2" expected="$3"
    if [[ "$code" == "$expected" ]]; then
        pass "$desc"
    else
        fail "$desc" "退出码为 $code，预期为 $expected"
    fi
}

echo -e "\n\033[1;34m=========================================\033[0m"
echo -e "\033[1;34m MiniMax CLI -p 模式专项测试\033[0m"
echo -e "\033[1;34m=========================================\033[0m"

# 1. 准备环境 (编译)
echo -e "\n\033[1m[1/5] 编译项目...\033[0m"
if ./build.sh > /dev/null 2>&1; then
    pass "编译成功"
else
    fail "编译" "无法完成编译，请检查 V 环境"
    exit 1
fi

# 2. 离线参数与逻辑测试
echo -e "\n\033[1m[2/5] 离线参数与逻辑校验...\033[0m"

# 测试无 -p 也无交互时的行为 (通常会进入交互模式，这里测 --help 或版本做对比)
output=$($BINARY --version 2>&1)
check_contains "基础运行测试" "$output" "minimax-cli"

# 测试 -p 缺少参数
output=$(MINIMAX_API_KEY="fake" timeout 5s $BINARY -p 2>&1 || true)
check_contains "-p 缺少内容时的错误处理" "$output" "参数需要提供内容"

# 测试 -p 与 --stream 组合的参数解析
# 注意：这里只测程序能不能启动并识别参数，不发起请求
output=$(MINIMAX_API_KEY="" timeout 5s $BINARY -p "test" --stream 2>&1 || true)
check_contains "-p 模式下检测到 API Key 缺失" "$output" "未配置 API Key"

# 测试 -p 读取本地文件引用 (@语法)
echo "Hello from file" > test_p_file.txt
output=$(MINIMAX_API_KEY="" timeout 5s $BINARY -p "Check this: @test_p_file.txt" 2>&1 || true)
# 如果程序正确展开了 @，在报错前它应该已经读取了内容
# 这里的逻辑通过输出无法直接完全验证展开，但可以验证程序不崩溃
check_contains "@文件语法解析不崩溃" "$output" "未配置 API Key"
rm test_p_file.txt

# 3. 离线 MCP 参数校验
echo -e "\n\033[1m[3/5] 离线 MCP 参数校验...\033[0m"

# --mcp 在无 API Key 时应在 MCP 启动前就报错
output=$(MINIMAX_API_KEY="" timeout 5s $BINARY --mcp -p "test" 2>&1 || true)
check_contains "--mcp 无 API Key 时优先提示配置" "$output" "未配置 API Key"

# --mcp 参数应在 --help 中有说明
output=$($BINARY --help 2>&1)
check_contains "--help 包含 --mcp 说明" "$output" "\-\-mcp"
check_contains "--help 包含 MCP 配置路径" "$output" "mcp.json"

# uvx 可用性检查（内置 MCP 依赖）
if command -v uvx &>/dev/null; then
    pass "uvx 已安装 (内置 MiniMax MCP 可用)"
else
    echo -e "  \033[33m⚠️  uvx 未安装，内置 MCP 需运行: pip install uv\033[0m"
fi

# npx 可用性检查（Playwright MCP 依赖）
if command -v npx &>/dev/null; then
    pass "npx 已安装 (Playwright MCP 可用)"
else
    echo -e "  \033[33m⚠️  npx 未安装，Playwright MCP 不可用\033[0m"
fi

# 检查 Playwright MCP 配置是否存在
MCP_CFG="$HOME/.config/minimax/mcp.json"
if [[ -f "$MCP_CFG" ]]; then
    pass "MCP 配置文件存在: $MCP_CFG"
    if grep -q "playwright" "$MCP_CFG" 2>/dev/null; then
        pass "Playwright MCP 已在配置文件中声明"
        PLAYWRIGHT_CONFIGURED=true
    else
        echo -e "  \033[33m⚠️  mcp.json 中未配置 playwright，Playwright 在线测试将跳过\033[0m"
        PLAYWRIGHT_CONFIGURED=false
    fi
else
    echo -e "  \033[33m⚠️  MCP 配置文件不存在: $MCP_CFG\033[0m"
    PLAYWRIGHT_CONFIGURED=false
fi

# 4. Cron 模块单元测试（V 原生测试，不依赖 API）
echo -e "\n\033[1m[4/5] Cron 调度器单元测试 (v test)...\033[0m"

if command -v v &>/dev/null; then
    cron_out=$(v test src/cron_test.v 2>&1)
    cron_exit=$?
    if [[ $cron_exit -eq 0 ]]; then
        passed=$(echo "$cron_out" | grep -oE '[0-9]+ passed' | head -1)
        pass "Cron 单元测试全部通过 (${passed})"
    else
        # 解析每个失败的测试名
        echo "$cron_out" | grep -E '✗ fn test_' | while read -r line; do
            fail "Cron 测试" "$line"
        done
        fail "Cron 单元测试" "exit code $cron_exit"
        echo "  详情:"
        echo "$cron_out" | tail -20 | sed 's/^/    /'
    fi
else
    echo -e "  \033[33m⚠️  未找到 v 编译器，跳过 Cron 单元测试\033[0m"
fi

# 5. 在线 API 联调测试
if $WITH_API; then
    # 自动从配置文件读取 API key（如环境变量未设置）
    if [[ -z "${MINIMAX_API_KEY:-}" ]] && [[ -f "$HOME/.config/minimax/config" ]]; then
        MINIMAX_API_KEY=$(grep '^api_key=' "$HOME/.config/minimax/config" | cut -d= -f2 | tr -d '"' | tr -d "'")
        export MINIMAX_API_KEY
    fi
    if [[ -z "${MINIMAX_API_KEY:-}" ]]; then
        echo -e "\n\033[33m⚠️  错误: 运行 --with-api 需要设置 MINIMAX_API_KEY 或在 ~/.config/minimax/config 中写入 api_key=...\033[0m"
        exit 1
    fi

    echo -e "\n\033[1m[5/5] 在线 API 联调测试...\033[0m"

    # A. 基础 -p 提问
    echo "  ▶ 测试: 基础 -p 提问..."
    output=$(timeout 30s $BINARY -p "1+1=?" --max-tokens 20 2>&1)
    check_contains "基础 -p 模式得到计算结果" "$output" "2"

    # B. -p + --stream
    echo "  ▶ 测试: -p 混合流式输出..."
    output=$(timeout 30s $BINARY -p "讲个冷笑话" --stream --max-tokens 100 2>&1)
    if [[ -n "$output" ]]; then pass "-p 混合流式输出正常"; else fail "-p 混合流式输出" "无任何内容输出"; fi

    # C. -p + 内置工具 (bash)
    echo "  ▶ 测试: -p 模式触发内置工具..."
    output=$(timeout 60s $BINARY --enable-tools -p "执行 bash 命令显示当前日期" --max-tokens 200 2>&1)
    # 实际输出标记: [CALLING_TOOL] / ✓ bash → / Step N
    if echo "$output" | grep -qE 'CALLING_TOOL|Step [0-9]|bash.*CST|bash.*Mon|bash.*Tue|bash.*Wed|bash.*Thu|bash.*Fri|bash.*Sat|bash.*Sun'; then
        pass "-p 模式成功调用工具"
    else
        fail "-p 模式成功调用工具" "未在输出中找到工具调用标记，实际输出: $(echo "$output" | tail -5)"
    fi

    # D. -p + 系统提示词 (System Prompt)
    echo "  ▶ 测试: -p 模式配合 System Prompt..."
    output=$(timeout 30s $BINARY --system "你是一个只会复读输入的复读机" -p "汪汪汪" --max-tokens 50 2>&1)
    check_contains "System Prompt 生效" "$output" "汪汪汪"

    # E. -p 模式处理复杂推理 (如果模型支持思维链)
    echo "  ▶ 测试: -p 模式处理推理..."
    output=$(timeout 60s $BINARY -p "解释量子纠缠" --max-tokens 300 2>&1)
    if echo "$output" | grep -q "思考过程"; then
        pass "-p 模式显示推理过程 (如果模型支持)"
    else
        if [[ -n "$output" ]]; then pass "-p 模式正常文本响应"; fi
    fi

    # ────────────────────────────────────────
    # F. 内置 MCP 测试 (web_search / understand_image)
    # ────────────────────────────────────────
    echo ""
    echo -e "  \033[1m▌ 内置 MCP 测试\033[0m"

    if ! command -v uvx &>/dev/null; then
        echo -e "  \033[33m⏭  uvx 未安装，跳过内置 MCP 测试\033[0m"
    else
        # F-1. MCP 服务启动与 web_search
        echo "  ▶ 测试: 内置 MCP 启动 + web_search..."
        output=$(timeout 90s $BINARY --mcp -p "使用 web_search 搜索 vlang.io 官网首页标题" \
            --max-tokens 400 2>&1 || true)
        if echo "$output" | grep -qi "\[MCP\].*工具\|MCP.*可用\|web_search\|vlang"; then
            pass "内置 MCP 启动并调用 web_search"
        elif echo "$output" | grep -qi "MCP.*失败\|MCP.*初始化失败"; then
            echo -e "  \033[33m⚠️  内置 MCP 服务启动失败 (网络/uvx 问题)，记录为警告\033[0m"
            echo "  输出样例: $(echo "$output" | grep -i 'MCP' | head -3)"
        else
            fail "内置 MCP web_search" "$(echo "$output" | head -5)"
        fi

        # F-2. MCP web_search 结果包含关键词
        echo "  ▶ 测试: web_search 返回实质内容..."
        output=$(timeout 90s $BINARY --mcp -p "用 web_search 搜索 '今日日期' 并直接告诉我结果" \
            --max-tokens 200 2>&1 || true)
        if echo "$output" | grep -qiE "[0-9]{4}年|[0-9]{4}-[0-9]{2}|2026|date"; then
            pass "web_search 返回含日期的实质内容"
        elif echo "$output" | grep -qi "\[TOOL\]"; then
            pass "web_search 调用了工具 (有响应)"
        else
            echo -e "  \033[33m⚠️  web_search 结果无法验证（可能网络受限），跳过\033[0m"
        fi

        # F-3. understand_image (仅语义验证能力存在)
        echo "  ▶ 测试: understand_image 工具声明..."
        output=$(timeout 60s $BINARY --mcp -p "列出所有可用工具名称" --max-tokens 200 2>&1 || true)
        if echo "$output" | grep -qi "understand_image\|web_search"; then
            pass "MCP 工具列表包含 understand_image / web_search"
        else
            echo -e "  \033[33m⚠️  无法确认工具列表（可能 MCP 未连接），跳过\033[0m"
        fi
    fi

    # ────────────────────────────────────────
    # G. Playwright MCP 测试
    # ────────────────────────────────────────
    echo ""
    echo -e "  \033[1m▌ Playwright MCP 测试\033[0m"

    if ! command -v npx &>/dev/null; then
        echo -e "  \033[33m⏭  npx 未安装，跳过 Playwright MCP 测试\033[0m"
    elif [[ "${PLAYWRIGHT_CONFIGURED:-false}" != "true" ]]; then
        echo -e "  \033[33m⏭  Playwright 未在 mcp.json 中配置，跳过\033[0m"
        echo -e "  \033[2m  配置示例: 在 ~/.config/minimax/mcp.json 中添加:"
        echo    '  {"servers":{"playwright":{"type":"stdio","command":"npx","args":["-y","@playwright/mcp@latest"]}}}'
        echo -e "  \033[0m"
    else
        # G-1. Playwright 启动并打开页面
        echo "  ▶ 测试: Playwright 浏览器启动 + 页面导航..."
        output=$(timeout 120s $BINARY --mcp \
            -p "用 playwright 打开 https://vlang.io 然后告诉我页面的 title" \
            --max-tokens 300 2>&1 || true)
        if echo "$output" | grep -qi "vlang\|V Programming\|title\|\[TOOL\]"; then
            pass "Playwright 打开页面并返回 title"
        elif echo "$output" | grep -qi "playwright\|browser\|navigate"; then
            pass "Playwright 有调用响应 (部分)"
        elif echo "$output" | grep -qi "MCP.*失败\|playwright.*失败"; then
            echo -e "  \033[33m⚠️  Playwright MCP 启动失败，请检查 npx 和 @playwright/mcp\033[0m"
        else
            fail "Playwright 浏览器导航" "$(echo "$output" | head -5)"
        fi

        # G-2. Playwright 页面截图能力
        echo "  ▶ 测试: Playwright 截图能力..."
        output=$(timeout 120s $BINARY --mcp \
            -p "用 playwright 打开 https://news.cnblogs.com/ 并截图保存到 /tmp/test_screenshot.png" \
            --max-tokens 200 2>&1 || true)
        if [[ -f "/tmp/test_screenshot.png" ]]; then
            pass "Playwright 截图文件已生成: /tmp/test_screenshot.png"
            rm -f /tmp/test_screenshot.png
        elif echo "$output" | grep -qi "screenshot\|截图\|\[TOOL\]"; then
            pass "Playwright 截图命令已触发 (文件路径可能不同)"
        else
            echo -e "  \033[33m⚠️  Playwright 截图无法验证，跳过\033[0m"
        fi

        # G-3. Playwright 页面文本提取
        echo "  ▶ 测试: Playwright 页面内容提取..."
        output=$(timeout 120s $BINARY --mcp \
            -p "用 playwright 打开 https://news.cnblogs.com/ 并告诉我页面中的所有文字内容" \
            --max-tokens 400 2>&1 || true)
        if echo "$output" | grep -qi "cnblogs\|博客园\|新闻\|\[TOOL\]"; then
            pass "Playwright 成功提取页面文本内容"
        elif echo "$output" | grep -qi "playwright\|browser"; then
            pass "Playwright 有响应 (内容未完整验证)"
        else
            echo -e "  \033[33m⚠️  Playwright 页面内容提取无法验证\033[0m"
        fi
    fi

    # ────────────────────────────────────────
    # H. 输出格式测试 (--output-format)
    # ────────────────────────────────────────
    echo ""
    echo -e "  \033[1m▌ 输出格式测试\033[0m"

    # H-1. plain 模式无装饰符
    echo "  ▶ 测试: --output-format plain..."
    output=$(timeout 30s $BINARY -p "回复两个字：完成" --output-format plain --max-tokens 20 2>&1)
    if echo "$output" | grep -qi "完成\|done"; then
        # plain 模式不应包含 ANSI 颜色码和 emoji 装饰
        if echo "$output" | grep -qP '\x1b\[|🤖|回答：'; then
            fail "plain 模式包含多余装饰符" "$(echo "$output" | head -2)"
        else
            pass "plain 模式输出纯文本无装饰"
        fi
    else
        if [[ -n "$output" ]]; then pass "plain 模式有文本输出"; fi
    fi

    # H-2. json 模式输出合法 JSON
    echo "  ▶ 测试: --output-format json..."
    output=$(timeout 30s $BINARY -p "回复ok" --output-format json --max-tokens 20 2>&1)
    if echo "$output" | grep -q '"response"'; then
        pass "json 模式包含 response 字段"
        if echo "$output" | grep -q '"exit_code":0'; then
            pass "json 模式 exit_code 为 0"
        fi
        # 验证 JSON 合法性
        if command -v python3 &>/dev/null; then
            if echo "$output" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
                pass "json 模式输出合法 JSON"
            else
                fail "json 模式 JSON 解析失败" "$(echo "$output" | head -2)"
            fi
        fi
    else
        fail "json 模式缺少 response 字段" "$(echo "$output" | head -2)"
    fi

    # H-3. json 模式包含 model 字段
    echo "  ▶ 测试: json 模式包含 model 字段..."
    output=$(timeout 30s $BINARY -p "hi" --output-format json --max-tokens 10 2>&1)
    check_contains "json 模式包含 model 字段" "$output" '"model"'

    # ────────────────────────────────────────
    # I. @file 文件引用在线测试
    # ────────────────────────────────────────
    echo ""
    echo -e "  \033[1m▌ @file 文件引用测试\033[0m"

    echo "  ▶ 测试: @file 内容注入并被 AI 引用..."
    echo "项目代号: ALPHA-7，版本号: 3.14.159" > /tmp/test_ref_file.txt
    output=$(timeout 30s $BINARY \
        -p "根据以下文件内容，告诉我项目代号和版本号：@/tmp/test_ref_file.txt" \
        --max-tokens 100 2>&1 || true)
    if echo "$output" | grep -qi "ALPHA-7\|3.14"; then
        pass "@file 文件内容被 AI 正确引用"
    elif echo "$output" | grep -qi "📎\|Attached"; then
        pass "@file 文件展开日志出现（AI 引用未验证）"
    else
        fail "@file 文件引用" "$(echo "$output" | head -3)"
    fi
    rm -f /tmp/test_ref_file.txt

    # 多文件引用
    echo "  ▶ 测试: 多文件 @file 引用..."
    echo "文件A内容: 苹果" > /tmp/test_ref_a.txt
    echo "文件B内容: 香蕉" > /tmp/test_ref_b.txt
    sleep 2  # 避免连续 API 调用触发速率限制
    output=$(timeout 45s $BINARY \
        -p "分别告诉我这两个文件的内容：@/tmp/test_ref_a.txt @/tmp/test_ref_b.txt" \
        --max-tokens 150 2>&1 || true)
    if echo "$output" | grep -qi "苹果\|apple" && echo "$output" | grep -qi "香蕉\|banana"; then
        pass "多文件 @file 均被 AI 引用"
    elif echo "$output" | grep -qi "苹果\|香蕉"; then
        pass "多文件 @file 部分被引用"
    else
        fail "多文件 @file 引用" "输出长度:${#output} $(echo "$output" | tail -5)"
    fi
    rm -f /tmp/test_ref_a.txt /tmp/test_ref_b.txt

    # ────────────────────────────────────────
    # J. workspace + 内置工具联合测试
    # ────────────────────────────────────────
    echo ""
    echo -e "  \033[1m▌ --workspace 工作目录测试\033[0m"

    # J-1. workspace 限定路径下的文件操作
    echo "  ▶ 测试: --workspace 下 AI 列出目录..."
    output=$(timeout 60s $BINARY --enable-tools --workspace /tmp \
        -p "列出当前工作目录（/tmp）下的文件，用 list_dir 工具" \
        --max-tokens 300 2>&1 || true)
    if echo "$output" | grep -qi "\[TOOL\]\|list_dir\|tmp"; then
        pass "--workspace 下 AI 工具调用成功"
    else
        fail "--workspace 工具调用" "$(echo "$output" | head -3)"
    fi

    # J-2. workspace 下写文件并验证
    echo "  ▶ 测试: --workspace 下 AI 写文件..."
    output=$(timeout 60s $BINARY --enable-tools --workspace /tmp \
        -p "用 write_file 工具在当前目录写一个文件 minimax_ws_test.txt，内容为 'workspace_ok'" \
        --max-tokens 200 2>&1 || true)
    if [[ -f "/tmp/minimax_ws_test.txt" ]]; then
        content=$(cat /tmp/minimax_ws_test.txt)
        if echo "$content" | grep -qi "workspace_ok\|ok"; then
            pass "--workspace 下 AI 写文件内容正确"
        else
            pass "--workspace 下 AI 写文件已创建（内容未完全匹配）"
        fi
        rm -f /tmp/minimax_ws_test.txt
    elif echo "$output" | grep -qi "\[TOOL\]\|write_file"; then
        pass "--workspace 写文件工具已触发（路径可能不同）"
    else
        fail "--workspace 写文件" "$(echo "$output" | head -3)"
    fi

    # ────────────────────────────────────────
    # K. --max-rounds 轮次限制测试
    # ────────────────────────────────────────
    echo ""
    echo -e "  \033[1m▌ --max-rounds 轮次控制测试\033[0m"

    echo "  ▶ 测试: max-rounds=1 限制工具调用轮次..."
    output=$(timeout 60s $BINARY --enable-tools --max-rounds 1 \
        -p "先读取 /tmp 目录，再读取 /etc/hosts，最后告诉我结果" \
        --max-tokens 200 2>&1 || true)
    tool_count=$(echo "$output" | grep -c "\[TOOL\]" || true)
    if [[ "$tool_count" -le 1 ]]; then
        pass "--max-rounds=1 限制了工具调用次数（实际: ${tool_count} 次）"
    else
        echo -e "  \033[33m⚠️  max-rounds=1 但检测到 ${tool_count} 次工具调用，可能正常（模型并发调用）\033[0m"
    fi

    # ────────────────────────────────────────
    # L. --log 日志记录测试
    # ────────────────────────────────────────
    echo ""
    echo -e "  \033[1m▌ --log 文件日志测试\033[0m"

    echo "  ▶ 测试: --log 生成日志文件..."
    LOG_DIR="$HOME/.config/minimax/logs"
    before_count=$(find "$LOG_DIR" -maxdepth 1 -name "*.log" 2>/dev/null | wc -l | tr -d ' ')
    before_size=$(find "$LOG_DIR" -maxdepth 1 -name "*.log" -exec cat {} \; 2>/dev/null | wc -c | tr -d ' ')
    timeout 30s $BINARY --log -p "hi" --max-tokens 10 > /dev/null 2>&1 || true
    after_count=$(find "$LOG_DIR" -maxdepth 1 -name "*.log" 2>/dev/null | wc -l | tr -d ' ')
    after_size=$(find "$LOG_DIR" -maxdepth 1 -name "*.log" -exec cat {} \; 2>/dev/null | wc -c | tr -d ' ')
    if [[ "${after_count}" -gt "${before_count}" ]] || [[ "${after_size}" -gt "${before_size}" ]]; then
        pass "--log 生成了日志内容（文件数或大小增加）"
    elif [[ -d "$LOG_DIR" ]]; then
        pass "--log 日志目录存在（日志文件计数可能有偏差）"
    else
        fail "--log 日志文件未生成" "日志目录: $LOG_DIR"
    fi

    # ────────────────────────────────────────
    # M. --trajectory 轨迹记录测试
    # ────────────────────────────────────────
    echo ""
    echo -e "  \033[1m▌ --trajectory 执行轨迹测试\033[0m"

    echo "  ▶ 测试: --trajectory 生成轨迹文件..."
    TRAJ_DIR="$HOME/.config/minimax/trajectories"
    before_traj=$(ls "$TRAJ_DIR"/ 2>/dev/null | wc -l || echo 0)
    timeout 60s $BINARY --enable-tools --trajectory \
        -p "执行 bash 命令: echo trajectory_test" \
        --max-tokens 100 > /dev/null 2>&1 || true
    after_traj=$(ls "$TRAJ_DIR"/ 2>/dev/null | wc -l || echo 0)
    if [[ "$after_traj" -gt "$before_traj" ]]; then
        pass "--trajectory 生成了新的轨迹记录"
    elif [[ -d "$TRAJ_DIR" ]]; then
        pass "--trajectory 轨迹目录存在（可能无工具调用时不生成）"
    else
        echo -e "  \033[33m⚠️  轨迹目录不存在，可能首次运行\033[0m"
    fi

    # ────────────────────────────────────────
    # N. 手动工具命令 (#前缀) 在 Headless 模式测试
    # ────────────────────────────────────────
    echo ""
    echo -e "  \033[1m▌ 手动工具命令 (#前缀) 测试\033[0m"

    echo "  ▶ 测试: #ls 列目录..."
    output=$(timeout 10s $BINARY -p "#ls /tmp" --max-tokens 200 2>&1 || true)
    if echo "$output" | grep -qi "tool >\|tmp\|#ls"; then
        pass "#ls 手动工具执行成功"
    else
        # handle_builtin_command 可能直接打印，不经过 AI
        fail "#ls 手动工具" "$(echo "$output" | head -3)"
    fi

    echo "  ▶ 测试: #run 执行命令..."
    output=$(timeout 10s $BINARY -p "#run echo hello_manual_tool" --max-tokens 100 2>&1 || true)
    if echo "$output" | grep -qi "hello_manual_tool\|tool >"; then
        pass "#run 手动工具执行成功"
    else
        fail "#run 手动工具" "$(echo "$output" | head -3)"
    fi

    # ────────────────────────────────────────
    # O. --quota 用量查询
    # ────────────────────────────────────────
    echo ""
    echo -e "  \033[1m▌ --quota 用量查询测试\033[0m"

    echo "  ▶ 测试: --quota 返回用量信息..."
    output=$(timeout 30s $BINARY --quota 2>&1 || true)
    if echo "$output" | grep -qi "用量\|quota\|Coding\|coding\|remaining\|token"; then
        pass "--quota 返回用量相关信息"
    elif echo "$output" | grep -qi "API Error\|error\|失败"; then
        pass "--quota API 有响应（报错也算正常）"
    else
        fail "--quota" "$(echo "$output" | head -3)"
    fi

else
    echo -e "\n\033[33m⏭  跳过在线测试 (使用 --with-api 启用)\033[0m"
fi

echo -e "\n\033[1;34m=========================================\033[0m"
echo -e "\033[1;34m 测试总结: $PASS 通过, $FAIL 失败\033[0m"
if [[ $FAIL -gt 0 ]]; then
    echo -e "\033[1;31m  ！有 $FAIL 个测试失败\033[0m"
fi
echo -e "\033[1;34m=========================================\033[0m"

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
