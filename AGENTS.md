# AGENTS.md

本文档面向在本仓库内工作的智能体和维护者，目标是把工程约束压缩成最短可执行说明。

## 先看什么

开始改动前，优先读取这些文件：

1. [README.md](README.md)
2. [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
3. [docs/IMPLEMENTATION.md](docs/IMPLEMENTATION.md)
4. [docs/EXTENSIBILITY.md](docs/EXTENSIBILITY.md)
5. [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)

如果文档和实现冲突，以源码为准。

## 重要外部资源

- **[V 语言官网](https://vlang.io)**：语言概况、下载、新闻。
- **[V 文档 (docs.vlang.io)](https://docs.vlang.io/)**：V 语言官方文档，包含语言教程、标准库参考等。
- **[V 模块文档 (modules.vlang.io)](https://modules.vlang.io/)**：V 标准库和第三方模块的完整文档，可搜索/浏览。
- **[V GitHub](https://github.com/vlang/v)**：源码、Issue、RFCs。
- **[V Playground](https://play.vlang.io/)**：在线运行 V 代码。

## 硬性约束

- 构建、测试、运行直接使用 `v` 即可。
- 修改 .v 文件后立刻执行 `v fmt -w` 对应文件。
- 修改 .md 文件后立刻执行 `oxfmt --write` 对应文件。
- 不引入外部运行时依赖来替代现有标准库实现，除非任务明确要求。
- 这是单二进制 CLI，不要假设存在服务端常驻进程架构。
- 涉及帮助文本、默认值、命令名变更时，同时更新 README 和 docs。

## 标准命令

### 构建

```bash
./build.sh
# 开发构建:
v -o minimax_cli src/
# 生产构建:
v -prod .
# 调试构建:
v -g -o minimax_cli src/
```

### 运行

```bash
./minimax_cli
./minimax_cli --term-ui
./minimax_cli -p "你的问题"
./minimax_cli --mcp -p "搜索一下 V 语言最新版本"
./minimax_cli --acp
```

### 测试

```bash
v test src/
v test src/config_test.v
./tests/check_vfmt.sh
./integration_test.sh
./comprehensive_test.sh
```

## 模块地图

- [src/main.v](src/main.v)：CLI 入口、运行模式、交互命令、帮助文本。
- [src/config.v](src/config.v)：默认值、配置文件、环境变量覆盖。
- [src/client.v](src/client.v)：API 请求、消息流、工具循环、计划模式。
- [src/parser.v](src/parser.v)：SSE 和 JSON 解析。
- [src/tools.v](src/tools.v)：本地工具系统和安全限制。
- [src/mcp.v](src/mcp.v)：MCP 客户端与子进程管理。
- [src/skills.v](src/skills.v)：技能发现、覆盖、激活。
- [src/commands.v](src/commands.v)：命令模板、扩展安装与管理。
- [src/experience.v](src/experience.v)：经验库与技能同步。
- [src/term_ui.v](src/term_ui.v)：终端 UI。
- [src/acp.v](src/acp.v)：ACP server。

## 代码风格

- 单文件模块使用 module main。
- 结构体使用 PascalCase，函数使用 snake_case。
- 明确使用 mut，不依赖隐式可变性。
- 错误优先用 ! 传播或用 or 块就地处理。
- 只在必要时使用 unsafe。
- 结构体字段直接访问，不额外套 getter。
- 保持 tab 缩进和现有文件风格。

## 关键实现事实

- 全局变量被真实用于 MCP 管理、Bash 会话、技能注册表等状态。
- Bash 工具是持久会话，不是一次性 shell 调用。
- Skills 支持内置、用户级、项目级三级发现，项目级优先。
- Commands 和 Extensions 在同一套注册体系中汇合。
- Experience 会把数据写入 ~/.config/minimax/knowledge，并支持同步回技能。
- macOS 交互输入对中文输入法做了兼容性回退。

## 修改时的联动检查

### 改 CLI 参数或命令

同时检查：

- [src/main.v](src/main.v)
- [src/config.v](src/config.v)
- [README.md](README.md)

### 改工具或安全限制

同时检查：

- [src/tools.v](src/tools.v)
- [src/client.v](src/client.v)
- [docs/EXTENSIBILITY.md](docs/EXTENSIBILITY.md)

### 改技能、命令模板、扩展

同时检查：

- [src/skills.v](src/skills.v)
- [src/commands.v](src/commands.v)
- [docs/EXTENSIBILITY.md](docs/EXTENSIBILITY.md)

### 改测试流程或仓库约定

同时检查：

- [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)
- [scripts/install-git-hooks.sh](scripts/install-git-hooks.sh)
- [tests/check_vfmt.sh](tests/check_vfmt.sh)

## 不要做的事

- 不要在文档里保留阶段性计划、验证报告或历史对比结论。
- 不要把 README 写成功能堆砌清单而缺少默认值和入口路径。
- 不要修改一个命令名却遗漏帮助文本和交互命令分发。
- 不要假设根目录的集成测试脚本和 tests 下的是两套独立逻辑。
