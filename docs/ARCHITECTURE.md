# 架构总览

MiniMax V CLI 是一个使用 V 语言实现的本地 AI Agent 运行时，核心目标是把一次请求扩展为以下能力组合：

- 模型调用：对接 MiniMax Anthropic 兼容接口。
- 工具执行：在本地执行文件、Shell、桌面和结构化编辑工具。
- 运行模式切换：支持 headless、REPL、term.ui、ACP server、Cron 子命令。
- 扩展机制：支持 MCP、Skills、Custom Commands、Extensions、Experience 知识沉淀。

## 核心设计

### 1. 单体 CLI，模块化实现

项目没有拆分为多进程服务架构，所有核心能力都在同一个二进制中实现。模块拆分主要按职责划分，而不是按部署边界划分。

这样做的结果是：

- 启动和分发简单，核心入口只有一个 [src/main.v](../src/main.v)。
- 全局状态可直接在进程内共享，例如 MCP 管理器、Bash 会话、技能注册表、TODO 管理器。
- 编译时必须启用全局变量支持，也就是始终使用 -enable-globals。

### 2. 配置层级明确

配置从低到高依次是：

1. 默认值。
2. 配置文件。
3. 环境变量。
4. CLI 参数。

默认值定义在 [src/config.v](../src/config.v)，例如：

- model: MiniMax-M2.5
- temperature: 0.7
- max_tokens: 102400
- max_rounds: 5000
- token_limit: 80000

### 3. 请求处理是一个工具循环

单次用户请求不是简单的一问一答，而是一个可能带工具调用的循环：

1. 组装系统提示、对话历史、技能元数据、可用工具 schema。
2. 发起模型请求。
3. 解析文本、thinking 和 tool use。
4. 本地执行工具。
5. 把工具结果回灌模型。
6. 重复直到模型结束或达到轮次限制。

这条链路的核心位于 [src/client.v](../src/client.v) 和 [src/parser.v](../src/parser.v)。

## 运行模式

### Headless

使用 -p 或 --prompt 进入单次执行模式，适合脚本化调用、CI 或外部编排。

### REPL

默认进入交互模式，保留上下文和命令面板。macOS 中文输入存在兼容性处理，当前实现对 read_interactive_input 做了保守回退。

### term.ui

通过 --term-ui 启动终端界面，保留独立输入区、状态栏、工具活动流和 ask_user 交互承接。

### ACP server

通过 --acp 把 CLI 以 stdio server 方式运行，用于外部宿主集成。该模式下会关闭一部分面向终端的人类可读输出。

### Cron 子命令

在入口早期先分流 Cron 子命令，避免进入普通聊天启动流程。

## 关键状态

### 全局变量

当前实现依赖多个全局变量承载跨模块状态，例如：

- g_mcp_manager
- g_shutting_down
- g_acp_mode
- bash_session
- skill_registry
- command_registry

这也是构建命令必须携带 -enable-globals 的原因。

### 持久化状态

用户本地状态主要落在 ~/.config/minimax 下：

- config：主配置。
- mcp.json：MCP 服务定义。
- sessions：会话存档。
- logs：日志输出。
- trajectories：执行轨迹。
- knowledge：经验库数据。
- skills：全局技能。
- commands：全局命令模板。

## 数据流

### 输入流

用户输入会先经过 [src/main.v](../src/main.v) 处理：

- CLI 参数解析。
- @file 语法展开。
- 交互命令和手动工具前缀分流。
- 运行模式选择。

### 模型流

[src/client.v](../src/client.v) 负责：

- 构造请求体。
- 注入系统提示和技能说明。
- 控制是否启用工具 schema。
- 处理 token limit 摘要策略。
- 执行工具循环。

### 工具流

[src/tools.v](../src/tools.v) 负责：

- 内置工具 schema 暴露。
- 实际工具执行。
- 危险命令过滤。
- 会话笔记、TODO、检查点等辅助能力。

### 扩展流

扩展能力由多个子系统叠加：

- MCP：远程或本地 stdio 工具发现。
- Skills：提示词级能力加载。
- Commands：模板级命令注入。
- Extensions：命令和 MCP 的分发封装。
- Experience：把历史经验转为可复用知识。

## 信号与退出

Ctrl+C 会优雅关闭当前流程，并尝试停止所有 MCP 子进程。相关逻辑位于 [src/main.v](../src/main.v)。

这意味着：

- 终端直接中断时不会无条件留下 MCP 孤儿进程。
- 交互模式和 ACP 模式的退出提示不完全相同。

## 架构边界

当前项目仍然是单机本地工具，不负责：

- 多用户服务端会话隔离。
- 远端任务队列或分布式执行。
- 独立数据库迁移系统。
- 浏览器 UI 或 Web 控制台。

如果后续需要演进到服务化部署，最先会受影响的是配置加载、全局状态和 Bash 会话模型。
