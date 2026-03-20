# MiniMax V CLI

MiniMax V CLI 是一个用 V 语言实现的本地 AI Agent 运行时，提供统一的命令行入口，把模型调用、工具执行、MCP 集成、技能体系和终端交互组合在一起。

当前文档以源码为准，重点覆盖已经进入主分支的能力，不再保留阶段性报告和历史草稿。

## 项目定位

这个项目不是单纯的 API 封装器，而是一个可在本机执行动作的 CLI Agent：

- 支持单次提问和持续交互。
- 支持工具调用循环，而不是只返回一次文本。
- 支持 MCP 工具发现和接入。
- 支持 Skills、Custom Commands、Extensions、Experience 等扩展机制。
- 支持普通 REPL、term.ui 和 ACP server 三种主要交互形态。

## 快速开始

### 1. 配置 API Key

```bash
mkdir -p ~/.config/minimax
cat > ~/.config/minimax/config <<'EOF'
api_key=sk-cp-xxx
EOF
```

也可以使用环境变量：

```bash
export MINIMAX_API_KEY=sk-cp-xxx
```

### 2. 构建

```bash
./build.sh
```

等价命令：

```bash
v -enable-globals -o minimax_cli src/
```

### 3. 运行

```bash
./minimax_cli -p "用 V 语言写一个 Hello World"
./minimax_cli
./minimax_cli --term-ui
./minimax_cli --enable-tools -p "读取当前目录的文件列表"
./minimax_cli --mcp -p "搜索一下 V 语言最新版本"
./minimax_cli --acp
./minimax_cli --quota
```

## 核心能力

### 基础调用

- Headless 模式：使用 -p 或 --prompt 发起单次请求。
- REPL 模式：默认进入交互会话。
- 流式输出：通过 --stream 输出 SSE 流。
- 输出格式：headless 模式支持 text、json、plain。

### 工具调用

启用 --enable-tools 后，模型可以调用本地工具执行动作。当前内置工具体系包括：

- 持久化 Bash 会话。
- 读写文件与列目录。
- 结构化文本替换与插入。
- grep、find、json 编辑。
- ask_user、session notes、todo、checkpoint。
- 桌面控制和截图工具。

补充说明：

- Windows 下 `bash` 工具默认仍保持持久 shell 语义；针对 `nu ...`、`pwsh ...`、`pueue ...` 这类命令会优先走直执行路径，以避免部分 Git Bash 子进程环境与后台任务环境不一致。

工具执行具有危险命令过滤，不会无条件放开系统破坏性命令。

### MCP

使用 --mcp 时：

- 从 ~/.config/minimax/mcp.json 加载额外 MCP 服务（如 Playwright）。
- 内置 MiniMax MCP（web_search / understand_image）默认已注册，无需此标志。

### 交互增强

- term.ui：状态栏、活动流、工具状态和 ask_user 交互。
- @文件引用：把文件内容附加到问题中。
- 手动工具前缀：#read、#write、#ls、#run。
- Shell 直达：!command。

### 扩展能力

- Skills：按目录自动发现和切换，默认扫描 `~/.config/minimax/skills` / `~/.agents/skills`，项目级 `.agents/skills` 需要先设置 `--workspace` 或 `MINIMAX_WORKSPACE`；可用 `--auto-skills` 让 AI 自动选择并激活匹配 skill。
- SOPs：默认扫描 `~/.config/minimax/sops/<skill>/SOP.md`；开启工具调用后会自动暴露可用 SOP，并在任务匹配时先读取对应 SOP 作为执行前检查。
- Custom Commands：基于 TOML 的命令模板。
- Extensions：安装、启用、更新命令与 MCP 组合包。
- Experience：把经验记录到本地知识库，并自动写回全局 skill 与全局 SOP。
- Cron：本地定时任务子命令。

## 默认配置

默认值来自 [src/config.v](src/config.v)：

```ini
api_url=https://api.minimaxi.com/anthropic/v1/messages
model=MiniMax-M2.7
temperature=0.7
max_tokens=102400
max_rounds=5000
token_limit=80000
enable_tools=false
auto_skills=false
auto_check_sops=true
auto_write_skills=true
auto_upgrade_sops=true
knowledge_sync_mode=balanced
enable_desktop_control=false
enable_screen_capture=false
enable_logging=false
debug=false
```

配置文件位置：

- 主路径：~/.config/minimax/config
- 兼容旧路径：~/.minimax_config

## 常用命令

### CLI 参数

- --model NAME
- --temperature (0.0, 1.0]
- --max-tokens N
- --max-rounds N
- --token-limit N
- --system PROMPT
- --workspace PATH
- --skill NAME
- --auto-skills
- --skills
- --stream
- --enable-tools
- --enable-desktop-control
- --enable-screen-capture
- --mcp
- --acp
- --term-ui
- --log
- --trajectory
- --plan
- --output-format text|json|plain
- --quota

### 交互模式命令

- exit, quit
- clear
- config
- doctor
- tools, tools on, tools off
- skills, skills reload, skills create NAME, skills sync NAME|all [mode]
- sops, sops list, sops show NAME, sops sync NAME|all [mode]
- skill NAME
- experience add, list, show, search, prune
- commands list, commands show NAME, commands reload
- extensions list, show, install, enable, disable, uninstall, update
- notes, notes clear
- log, trajectory, plan
- checkpoint, checkpoints, restore
- quota
- cron ...
- mcp, mcp start, mcp stop

准确行为以 [src/main.v](src/main.v) 的帮助文本和命令分发逻辑为准。

补充说明：

- `--enable-tools` 开启时，模型会收到已发现 skills 的元信息，并可通过 `activate_skill` 工具自行加载对应 skill。
- `--auto-skills` 会显式鼓励模型优先自行选择匹配的 skill；若未设置 `workspace`，会默认使用当前目录以纳入项目级 `.agents/skills`。
- 开启工具调用且存在全局 SOP 时，模型会先调用 `match_sop` 工具匹配最相关的 SOP。该工具会返回分项评分、命中层级以及 `suggested_read_order`，模型再按建议顺序用 `read_file` 读取对应 SOP；可通过 `auto_check_sops=false` 或环境变量 `MINIMAX_AUTO_CHECK_SOPS=0` 关闭。
- `experience add` 默认会按 `knowledge_sync_mode` 自动同步到全局 `~/.config/minimax/skills` 和 `~/.config/minimax/sops`；可通过 `auto_write_skills`、`auto_upgrade_sops` 或对应环境变量关闭。
- AI 开启工具调用后，还可以直接使用 `record_experience` 工具沉淀经验，不必依赖交互命令。

## 文档索引

- [docs/README.md](docs/README.md)：文档入口。
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)：系统结构和数据流。
- [docs/IMPLEMENTATION.md](docs/IMPLEMENTATION.md)：源码模块职责映射。
- [docs/EXTENSIBILITY.md](docs/EXTENSIBILITY.md)：MCP、技能、命令模板、扩展、经验库。
- [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)：开发、格式化、测试与排障约定。

## 测试与验证

```bash
v -enable-globals test src/
./tests/check_vfmt.sh
./integration_test.sh
./comprehensive_test.sh
```

如果需要启用 Git hooks：

```bash
bash scripts/install-git-hooks.sh
```

当前 hooks 约定：

- pre-commit 运行 tests/check_vfmt.sh
- pre-push 运行 build.sh 和 v -enable-globals test src/

## 前置依赖

- V 编译器。
- MCP 场景下需要对应工具运行时，例如 npx 或 uv。
- 如果使用 SQLite 经验库存储，系统中需要可用的 sqlite3。

## 许可证

MIT
