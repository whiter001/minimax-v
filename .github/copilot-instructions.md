# minimax-v Copilot 指南

本文档为在 minimax-v 仓库中工作的 Copilot 会话提供必要信息。

## 编译和测试命令

### 编译

```bash
./build.sh
# 运行: v -enable-globals -o minimax_cli src/
# 必须使用 -enable-globals 标志，因为代码使用了 __global 全局变量（如 g_mcp_manager, g_shutting_down, bash_session）
```

### 测试和验证

```bash
# 格式检查（强制）
./tests/check_vfmt.sh

# 完整集成测试（仅离线测试）
./integration_test.sh

# 集成测试含实际 API 调用（需要有效的 MINIMAX_API_KEY）
./integration_test.sh --with-api

# 综合测试套件
./comprehensive_test.sh

# 运行特定测试文件
v -enable-globals test src/config_test.v
```

## 高层架构

### 核心组件

1. **入口和 CLI (`main.v`)**
   - 解析命令行参数和环境变量
   - 支持交互模式（REPL）和单次提问模式
   - 支持文件引用展开（`@file-path` 语法）
   - 处理信号以优雅关闭（Ctrl+C）

2. **API 客户端 (`client.v`)**
   - 通过 HTTP 与 MiniMax/Anthropic API 通信
   - 支持流式（SSE）和非流式响应模式
   - 管理工具调用循环（最多 25 轮），用于 AI 驱动的工具执行
   - 维护会话历史（ChatMessage 数组）
   - 实现轨迹记录用于调试复杂交互

3. **配置管理 (`config.v`)**
   - 从 `~/.config/minimax/config`（key=value 格式）或 `~/.minimax_config`（旧版）加载配置
   - 支持环境变量覆盖（MINIMAX_API_KEY, MINIMAX_MODEL 等）
   - 跨平台路径展开（`~` 到主目录）
   - 默认值：model=MiniMax-M2.7, temperature=0.7, max_tokens=102400

4. **工具系统 (`tools.v`)**
   - 持久化 BashSession 跨工具调用维护工作目录和环境状态
   - 内置工具：read_file, write_file, list_dir, bash
   - 危险命令过滤（rm -rf, mkfs, dd 等）以确保安全
   - bash 自动检测；Windows 上回退到 cmd.exe
   - 工具定义以结构化 JSON 形式发送给 API，便于 AI 理解

5. **响应解析 (`parser.v`)**
   - 手写 JSON 解析（无外部 JSON 库）
   - 支持 SSE 流式和普通响应格式
   - 从 API 响应提取文本、思考块和工具使用/结果
   - 解析缓存统计（cache_read_input_tokens, cache_creation_input_tokens）

6. **MCP 协议 (`mcp.v`)**
   - JSON-RPC 2.0 客户端（stdio 上）用于 MCP 服务器
   - 管理 MCP 服务器生命周期（启动/停止）
   - 从 MCP 服务器发现工具（如 web_search, understand_image）
   - 全局 McpManager 用于集中管理服务器

7. **高级特性**
   - **会话 (`sessions.v`)**：多会话对话持久化和恢复
   - **画布 (`canvas.v`)**：终端表格/图表渲染
   - **节点 (`nodes.v`)**：基于 DAG 的任务编排
   - **定时任务 (`cron.v`)**：基于 Cron 表达式的任务调度
   - **技能 (`skills.v`)**：自动发现和可重用的技能管理
   - **Agent (`agent.v`)**：高级 agent 逻辑，带规划和执行

## 关键约定

### V 语言特性

- **模块**：使用 `module main` 声明的单文件模块
- **可变性**：可变接收器和变量使用显式 `mut` 关键字
- **内存安全**：特定操作使用 unsafe 块；指针使用 `&T` 语法
- **结构体字段访问**：直接字段访问（无 getter/setter）；使用 pub/private 修饰符

### 全局状态管理

```v
__global g_mcp_manager = &McpManager(unsafe { nil })
__global bash_session = BashSession{}
```

- 全局变量使用 `__global` 关键字
- 必须用 `-enable-globals` 标志编译
- 用于无法轻易传递的跨函数状态（如信号处理器、持久会话）

### Windows 兼容性

- Bash 路径检测：先尝试 Git Bash 位置（`D:\Program Files\Git\bin\bash.exe`），回退到 cmd.exe
- 路径展开：使用 `os.home_dir() + 字符串切片` 来处理 `~` 展开（不使用 `os.expand_tilde_to_home()`）
- 进程执行：复杂命令使用 `os.Process`；避免 Windows shell 限制

### API 和工具集成

- **工具 Schema**：以 JSON 形式发送工具，包含名称、描述和 input_schema，便于 AI 理解
- **工具执行循环**：最多 200 轮（const max_tool_call_rounds = 200），默认 100 轮；遵守 token 限制
- **工具输出截断**：每个工具输出最多 10000 个字符（const max_tool_output_chars = 10000）
- **工作空间上下文**：可选的工作空间参数限制文件操作和工作目录

### 配置层级

1. 命令行参数（最高优先级）
2. 环境变量（MINIMAX_API_KEY, MINIMAX_MODEL, MINIMAX_TEMPERATURE, MINIMAX_MAX_TOKENS, MINIMAX_ENABLE_TOOLS）
3. 配置文件（~/.config/minimax/config）
4. 默认值（最低优先级）

### 测试模式

- 测试文件使用 `_test.v` 后缀（如 `config_test.v`）
- 集成测试使用 shell 脚本（.sh）进行端到端验证
- 离线测试优先运行；实时 API 测试需要 --with-api 标志
- 测试辅助函数如 `check_contains()`, `check_not_contains()`, `check_exit_code()`

### 错误处理

- V 使用 `!` 操作符实现类似 try/catch 的错误传播（返回错误或值）
- API 错误通过响应体检查（手写 JSON 解析）
- 命令错误通过退出码和输出检查
- Ctrl+C 通过信号处理器优雅关闭，McpManager 清理资源

### 流式输出

- SSE 流式逐行解析；从 `data:` 前缀行提取文本
- 思考块与响应文本分离用于调试输出（正常模式下不可见）
- 终端输出使用 ANSI 转义码实现颜色/格式化（如 `\x1b[2m` 表示暗文本）

## 文件组织

- `src/*.v` — 核心模块（一文件一模块）
- `src/*_test.v` — 单元和集成测试
- `tests/*.sh` — Shell 脚本测试套件
- `docs/` — 扩展文档（功能指南、存档规范）
- `examples/` — 示例代码和演示提示
- `.github/` — GitHub 相关配置

## 配置文件

- `~/.config/minimax/config` — 主配置文件（key=value 格式）
- `~/.config/minimax/mcp.json` — MCP 服务器配置（JSON 格式）
- `~/.minimax_config` — 旧版配置位置（回退）

## MCP 服务器配置

### Playwright（浏览器自动化）

要启用 Playwright 用于浏览器自动化任务，将以下内容添加到 `~/.config/minimax/mcp.json`：

```json
{
  "servers": {
    "playwright": {
      "type": "stdio",
      "command": "npx",
      "args": ["-y", "@playwright/mcp@latest"]
    }
  }
}
```

需要：系统中安装了 `npm`。运行 CLI 时使用 `--mcp` 标志启用。
