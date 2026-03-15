# 实现梳理

本文按源码文件说明模块职责，目的是让维护者快速知道能力在哪里实现、修改时应该看哪些文件。

## 入口层

### [src/main.v](../src/main.v)

负责整个 CLI 生命周期：

- 启动参数解析。
- API Key 检查。
- 运行模式选择。
- 交互模式命令分发。
- 帮助文本输出。
- 信号处理与优雅退出。
- @file 引用展开。

文档和测试如果涉及参数、命令、帮助文本，优先核对这个文件。

### [src/config.v](../src/config.v)

负责配置模型与优先级：

- 默认值定义。
- 配置文件读取。
- 环境变量覆盖。
- 数值合法性校验。

凡是默认值漂移，优先更新这里和 README，而不是只改文档。

## 模型与执行层

### [src/client.v](../src/client.v)

这是请求执行主引擎，职责包括：

- 构造 API 请求。
- 管理消息历史。
- 注入工具定义。
- 执行工具调用循环。
- 处理 max_rounds 和 token_limit。
- 处理流式和非流式输出。
- 支持 plan mode、轨迹记录、日志等运行时行为。

如果行为表现为模型没有继续调用工具、上下文被摘要、输出格式变化，通常先看这里。

### [src/parser.v](../src/parser.v)

负责手写 JSON 和 SSE 解析。项目不依赖外部 JSON 解析库，响应解析逻辑主要集中在这里。

## 工具层

### [src/tools.v](../src/tools.v)

这是本地工具系统中心，包含：

- Bash 持久会话。
- 读写文件和列目录。
- 结构化编辑器。
- grep、find、json_edit。
- 桌面控制和截图。
- session notes、todo、checkpoint、ask_user。
- MCP 相关二次封装工具。

这里既定义工具 schema，也定义执行逻辑，因此任何工具名、参数或安全限制变化都需要同步检查两部分。

## 扩展层

### [src/mcp.v](../src/mcp.v)

负责 MCP JSON-RPC over stdio：

- 启停 MCP 子进程。
- 初始化握手。
- 工具发现。
- 统一纳入调用面。

### [src/skills.v](../src/skills.v)

负责技能系统：

- 内置技能定义。
- 用户级技能发现。
- 项目级技能发现。
- YAML frontmatter 解析。
- 同名覆盖优先级。
- 技能切换和元数据注入。

### [src/experience.v](../src/experience.v)

除经验库读写外，还负责全局 SOP 的生成、列出、展示，以及为请求构造阶段提供 SOP 元数据摘要。

### [src/commands.v](../src/commands.v)

负责命令模板与扩展安装：

- 扫描全局和项目命令目录。
- 解析 TOML 命令模板。
- 扩展发现、安装、启用、更新、卸载。
- 扩展携带的命令与 MCP 服务注册。

如果交互命令中的 commands 或 extensions 有异常，优先从这个文件排查。

### [src/experience.v](../src/experience.v)

负责经验沉淀：

- 录入经验记录。
- SQLite、JSONL、Markdown 多副本存储。
- 搜索、展示、清理。
- skill sync，把经验压缩写回技能文档。
- SOP sync，把经验升级为全局 SOP 文档。
- experience add 后按配置自动触发全局 skill 与 SOP 同步。

## 用户界面层

### [src/term_ui.v](../src/term_ui.v)

负责终端 UI 展示状态、活动流和输入交互。

### [src/canvas.v](../src/canvas.v)

负责终端中的表格和可视化渲染辅助。

## 任务与自动化层

### [src/agent.v](../src/agent.v)

提供 Agent 执行状态机、步骤记录和轨迹输出的骨架结构。

### [src/cron.v](../src/cron.v) 和 [src/cron_cli.v](../src/cron_cli.v)

负责本地 Cron 调度与命令行子命令。

### [src/nodes.v](../src/nodes.v)

负责 DAG 式节点编排。

## 配套能力

### [src/sessions.v](../src/sessions.v)

负责多会话持久化，当前会话数据保存到本地目录。

### [src/logger.v](../src/logger.v)

负责日志文件记录。

### [src/acp.v](../src/acp.v)

负责 ACP server 模式下的协议承接。

## 测试布局

测试文件基本遵循一一对应：

- 主模块对应的单测放在 src 下，命名为 \*\_test.v。
- Shell 集成测试放在 tests 下。
- 根目录的 build.sh、integration_test.sh、comprehensive_test.sh 是常用入口。

## 改动建议

### 修改参数和帮助文本时

同时检查：

- [src/main.v](../src/main.v)
- [src/config.v](../src/config.v)
- [README.md](../README.md)
- [AGENTS.md](../AGENTS.md)

### 修改工具能力时

同时检查：

- [src/tools.v](../src/tools.v)
- [src/client.v](../src/client.v)
- [docs/EXTENSIBILITY.md](EXTENSIBILITY.md)

### 修改扩展机制时

同时检查：

- [src/mcp.v](../src/mcp.v)
- [src/skills.v](../src/skills.v)
- [src/commands.v](../src/commands.v)
- [docs/EXTENSIBILITY.md](EXTENSIBILITY.md)
