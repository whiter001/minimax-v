#!/bin/bash
# comprehensive_test.sh - 综合功能测试验证脚本

set +e  # 不在失败时退出，继续执行所有测试

COLOR_GREEN='\033[0;32m'
COLOR_RED='\033[0;31m'
COLOR_YELLOW='\033[1;33m'
COLOR_BLUE='\033[0;34m'
NC='\033[0m' # No Color

PASSED=0
FAILED=0
TOTAL=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

resolve_doc_path() {
    for candidate in "$@"; do
        if [ -f "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done
    echo ""
    return 1
}

# 日志函数
log_test() {
    echo -e "${COLOR_BLUE}[TEST]${NC} $1"
}

log_pass() {
    echo -e "${COLOR_GREEN}[✓ PASS]${NC} $1"
    ((PASSED++))
    ((TOTAL++))
}

log_fail() {
    echo -e "${COLOR_RED}[✗ FAIL]${NC} $1"
    ((FAILED++))
    ((TOTAL++))
}

log_info() {
    echo -e "${COLOR_YELLOW}[INFO]${NC} $1"
}

# ============================================================================
# 第一部分：编译验证
# ============================================================================

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║          第一部分：编译验证                                   ║"
echo "╚═══════════════════════════════════════════════════════════════╝"

log_test "检查所有模块编译状态"
if ! cd "$REPO_ROOT"; then
    log_fail "无法进入仓库目录: $REPO_ROOT"
    exit 1
fi

feature_guide_doc=$(resolve_doc_path "FEATURE-INTEGRATION-GUIDE.md" "docs/FEATURE-INTEGRATION-GUIDE.md")
quick_reference_doc=$(resolve_doc_path "FEATURES-QUICK-REFERENCE.md" "docs/FEATURES-QUICK-REFERENCE.md" "docs/archive/FEATURES-QUICK-REFERENCE.md")
implementation_summary_doc=$(resolve_doc_path "IMPLEMENTATION-SUMMARY.md" "docs/IMPLEMENTATION-SUMMARY.md" "docs/archive/IMPLEMENTATION-SUMMARY.md")

feature_guide_doc=${feature_guide_doc:-docs/FEATURE-INTEGRATION-GUIDE.md}
quick_reference_doc=${quick_reference_doc:-docs/archive/FEATURES-QUICK-REFERENCE.md}
implementation_summary_doc=${implementation_summary_doc:-docs/archive/IMPLEMENTATION-SUMMARY.md}

if v check src/sessions.v src/canvas.v src/nodes.v src/cron.v 2>&1 | grep -q "error"; then
    log_fail "模块编译检查"
    exit 1
else
    log_pass "模块编译检查"
fi

# ============================================================================
# 第二部分：文件验证
# ============================================================================

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║          第二部分：文件验证                                   ║"
echo "╚═══════════════════════════════════════════════════════════════╝"

log_test "检查关键文件存在"

files=(
    "src/sessions.v"
    "src/canvas.v"
    "src/nodes.v"
    "src/cron.v"
    "examples/integrated_demo.v"
    "$feature_guide_doc"
    "$quick_reference_doc"
    "$implementation_summary_doc"
)

for file in "${files[@]}"; do
    if [ -f "$file" ]; then
        log_pass "文件存在: $file"
    else
        log_fail "文件不存在: $file"
    fi
done

# ============================================================================
# 第三部分：代码质量检查
# ============================================================================

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║          第三部分：代码质量检查                               ║"
echo "╚═══════════════════════════════════════════════════════════════╝"

log_test "检查代码行数"
sessions_lines=$(wc -l < src/sessions.v)
canvas_lines=$(wc -l < src/canvas.v)
nodes_lines=$(wc -l < src/nodes.v)
cron_lines=$(wc -l < src/cron.v)

echo "  Sessions: $sessions_lines 行 (预期范围: 200-300)"
echo "  Canvas:   $canvas_lines 行 (预期范围: 150-350)"
echo "  Nodes:    $nodes_lines 行 (预期范围: 200-400)"
echo "  Cron:     $cron_lines 行 (预期范围: 250-450)"

if [ $sessions_lines -gt 200 ] && [ $sessions_lines -lt 300 ]; then
    log_pass "Sessions 代码行数合理"
else
    log_fail "Sessions 代码行数异常"
fi

if [ $canvas_lines -gt 150 ] && [ $canvas_lines -lt 350 ]; then
    log_pass "Canvas 代码行数合理"
else
    log_fail "Canvas 代码行数异常"
fi

if [ $nodes_lines -gt 200 ] && [ $nodes_lines -lt 400 ]; then
    log_pass "Nodes 代码行数合理"
else
    log_fail "Nodes 代码行数异常"
fi

if [ $cron_lines -gt 250 ] && [ $cron_lines -lt 450 ]; then
    log_pass "Cron 代码行数合理"
else
    log_fail "Cron 代码行数异常"
fi

# ============================================================================
# 第四部分：结构验证
# ============================================================================

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║          第四部分：结构验证                                   ║"
echo "╚═══════════════════════════════════════════════════════════════╝"

log_test "检查 Sessions 结构"
if grep -q "pub struct Session" src/sessions.v && \
   grep -q "pub struct SessionManager" src/sessions.v && \
   grep -q "pub struct Message" src/sessions.v; then
    log_pass "Sessions 结构完整"
else
    log_fail "Sessions 结构不完整"
fi

log_test "检查 Canvas 结构"
if grep -q "pub struct Canvas" src/canvas.v && \
   grep -q "pub struct TableData" src/canvas.v && \
   grep -q "pub struct ChartData" src/canvas.v; then
    log_pass "Canvas 结构完整"
else
    log_fail "Canvas 结构不完整"
fi

log_test "检查 Nodes 结构"
if grep -q "pub struct ComputeNode" src/nodes.v && \
   grep -q "pub struct ComputeGraph" src/nodes.v && \
   grep -q "pub struct Edge" src/nodes.v; then
    log_pass "Nodes 结构完整"
else
    log_fail "Nodes 结构不完整"
fi

log_test "检查 Cron 结构"
if grep -q "pub struct CronJob" src/cron.v && \
   grep -q "pub struct CronScheduler" src/cron.v && \
   grep -q "pub struct CronTime" src/cron.v; then
    log_pass "Cron 结构完整"
else
    log_fail "Cron 结构不完整"
fi

# ============================================================================
# 第五部分：API 验证
# ============================================================================

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║          第五部分：API 验证                                   ║"
echo "╚═══════════════════════════════════════════════════════════════╝"

log_test "检查 Sessions API"
sessions_apis=(
    "fn new_session_manager"
    "fn.*create_session"
    "fn.*switch_session"
    "fn.*add_message"
    "fn.*get_messages"
    "fn.*save"
    "fn.*load"
    "fn.*get_stats"
)

for api in "${sessions_apis[@]}"; do
    if grep -q "$api" src/sessions.v; then
        log_pass "Sessions: $api"
    else
        log_fail "Sessions: 缺少 $api"
    fi
done

log_test "检查 Canvas API"
canvas_apis=(
    "fn new_canvas"
    "fn.*add_text"
    "fn.*add_table"
    "fn.*add_chart"
    "fn.*render"
    "fn.*export_html"
)

for api in "${canvas_apis[@]}"; do
    if grep -q "$api" src/canvas.v; then
        log_pass "Canvas: $api"
    else
        log_fail "Canvas: 缺少 $api"
    fi
done

log_test "检查 Nodes API"
nodes_apis=(
    "fn new_graph"
    "fn.*add_node"
    "fn.*add_edge"
    "fn.*validate"
    "fn.*generate_execution_order"
    "fn.*execute"
    "fn.*get_predecessors"
    "fn.*get_successors"
)

for api in "${nodes_apis[@]}"; do
    if grep -q "$api" src/nodes.v; then
        log_pass "Nodes: $api"
    else
        log_fail "Nodes: 缺少 $api"
    fi
done

log_test "检查 Cron API"
cron_apis=(
    "fn new_cron_scheduler"
    "fn.*add_job"
    "fn.*start"
    "fn.*tick"
    "fn.*delete_job"
    "fn.*validate_cron_expression"
    "fn.*get_stats"
)

for api in "${cron_apis[@]}"; do
    if grep -q "$api" src/cron.v; then
        log_pass "Cron: $api"
    else
        log_fail "Cron: 缺少 $api"
    fi
done

# ============================================================================
# 第六部分：文档验证
# ============================================================================

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║          第六部分：文档验证                                   ║"
echo "╚═══════════════════════════════════════════════════════════════╝"

log_test "检查文档完整性"

if grep -q "Sessions" "$feature_guide_doc"; then
    log_pass "$feature_guide_doc 包含 Sessions"
else
    log_fail "$feature_guide_doc 缺少 Sessions"
fi

if grep -q "Canvas" "$feature_guide_doc"; then
    log_pass "$feature_guide_doc 包含 Canvas"
else
    log_fail "$feature_guide_doc 缺少 Canvas"
fi

if grep -q "Nodes" "$feature_guide_doc"; then
    log_pass "$feature_guide_doc 包含 Nodes"
else
    log_fail "$feature_guide_doc 缺少 Nodes"
fi

if grep -q "Cron" "$feature_guide_doc"; then
    log_pass "$feature_guide_doc 包含 Cron"
else
    log_fail "$feature_guide_doc 缺少 Cron"
fi

# ============================================================================
# 第七部分：演示程序验证
# ============================================================================

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║          第七部分：演示程序验证                               ║"
echo "╚═══════════════════════════════════════════════════════════════╝"

log_test "检查演示程序结构"

if grep -q "fn session_demo" examples/integrated_demo.v; then
    log_pass "演示程序包含 session_demo"
else
    log_fail "演示程序缺少 session_demo"
fi

if grep -q "fn canvas_demo" examples/integrated_demo.v; then
    log_pass "演示程序包含 canvas_demo"
else
    log_fail "演示程序缺少 canvas_demo"
fi

if grep -q "fn nodes_demo" examples/integrated_demo.v; then
    log_pass "演示程序包含 nodes_demo"
else
    log_fail "演示程序缺少 nodes_demo"
fi

if grep -q "fn cron_demo" examples/integrated_demo.v; then
    log_pass "演示程序包含 cron_demo"
else
    log_fail "演示程序缺少 cron_demo"
fi

# ============================================================================
# 第八部分：性能指标检查
# ============================================================================

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║          第八部分：性能指标检查                               ║"
echo "╚═══════════════════════════════════════════════════════════════╝"

log_test "检查性能优化相关代码"

if grep -q "O(V+E)" src/nodes.v || grep -q "topological" src/nodes.v; then
    log_pass "Nodes 包含算法优化说明"
else
    log_info "Nodes 未注释算法复杂度"
fi

if grep -q "DFS\|dfs" src/nodes.v; then
    log_pass "Nodes 包含 DFS 算法"
else
    log_fail "Nodes 缺少 DFS 算法"
fi

if grep -q "unix_milli\|timestamp" src/sessions.v; then
    log_pass "Sessions 包含时间戳"
else
    log_fail "Sessions 缺少时间戳"
fi

# ============================================================================
# 第九部分：Git 提交验证
# ============================================================================

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║          第九部分：Git 提交验证                               ║"
echo "╚═══════════════════════════════════════════════════════════════╝"

log_test "检查 Git 提交历史"

commit_count=$(git log --oneline | grep -c "feature\|Feature\|Add 4\|advanced" || echo "0")
echo "  相关提交数: $commit_count"

if [ "$commit_count" -gt 0 ]; then
    log_pass "Git 提交完整"
else
    log_info "检查最近提交"
    git log --oneline -5
fi

# ============================================================================
# 总结
# ============================================================================

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║          测试总结                                             ║"
echo "╚═══════════════════════════════════════════════════════════════╝"

echo ""
echo "总测试数: $TOTAL"
echo -e "通过: ${COLOR_GREEN}$PASSED${NC}"
echo -e "失败: ${COLOR_RED}$FAILED${NC}"

pass_rate=$((PASSED * 100 / TOTAL))
echo "通过率: ${pass_rate}%"

if [ $FAILED -eq 0 ]; then
    echo ""
    echo -e "${COLOR_GREEN}✅ 所有测试通过！${NC}"
    exit 0
else
    echo ""
    echo -e "${COLOR_RED}⚠️  有 $FAILED 个测试失败${NC}"
    exit 1
fi
