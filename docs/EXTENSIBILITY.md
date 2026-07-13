# 扩展机制

当前仓库的扩展能力不是单一系统，而是四套机制叠加：MCP、Skills、Custom Commands、Extensions。Experience 则承担长期知识沉淀。

## MCP

### 作用

MCP 用于把外部工具以 stdio JSON-RPC 的方式接入到 CLI。

### 配置位置

- ~/.config/minimax/mcp.json

### 示例配置

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

### 典型场景

- Web 搜索。
- 图像理解。
- Playwright 浏览器自动化。
- 其他兼容 MCP 的本地或远程工具。

### 行为特征

- 外部 MCP 服务需要显式 --mcp 才会加载；默认不再预置 MiniMax MCP。
- MCP 工具在运行时发现，不是编译期写死。
- 退出时会尝试统一回收子进程。

### 故障排查

- 如果 `--mcp` 没有加载任何服务，请检查 `mcp.json` 中每个 server 是否同时包含非空 `name` 和 `command`；空值条目会被跳过并打印警告。

## Skills

### 发现顺序

技能优先级从低到高如下：

1. 内置技能。
2. 用户技能，目录为 ~/.config/minimax/skills 或 ~/.agents/skills。
3. 项目技能，目录为 .agents/skills。

项目级会覆盖同名用户级和内置技能。

补充说明：

- 用户级技能默认会被扫描，无需额外参数。
- 项目级 `.agents/skills` 只有在 workspace 已设置时才会被扫描；可通过 `--workspace PATH` 或环境变量 `MINIMAX_WORKSPACE` 指定。
- `--skills` 用于列出当前已发现的技能，`--skill NAME` 用于直接启用某个技能。
- `--auto-skills` 会先根据当前任务在本地对已发现 skills 做轻量匹配和排序，把最相关的 skill 元信息与片段注入上下文，再让 AI 决定是否调用 `activate_skill`；若未显式设置 workspace，则默认使用当前目录来纳入项目级 `.agents/skills`。

## SOPs

### SOP 位置

- 全局：`~/.config/minimax/sops/{skill}/SOP.md`

### SOP 使用方式

- 交互命令：`sops`、`sops list`、`sops show NAME`、`sops sync NAME|all [mode]`
- 自动检查：只要启用了工具调用，CLI 就会向模型暴露可用 SOP 列表，并提供 `match_sop` 工具；模型会先用 `match_sop` 匹配最相关 SOP，再按 `suggested_read_order` 用 `read_file` 读取一个或多个 SOP。
- 匹配结果：`match_sop` 会返回总分、`score_breakdown`、`matched_layers` 和 `suggested_read_order`，便于模型解释命中原因并处理复合任务。
- 关闭方式：配置文件中设置 `auto_check_sops=false`，或环境变量 `MINIMAX_AUTO_CHECK_SOPS=0`。

### 文件格式

技能文件名固定为 `SKILL.md`，使用 YAML frontmatter 声明元信息。当前会识别 `name`、`description`、`tags`、`tools`、`triggers`、`platform`，其中后四项会参与 autoskill 的本地匹配与排序：

```md
---
name: reviewer
description: Review code changes for bugs and regressions
tags:
  - review
  - bug
tools:
  - read_file
  - grep_search
triggers:
  - review this diff
platform: cross-platform
---

这里开始写技能正文，正文会作为系统提示注入。
```

### Skills 交互命令

- CLI 参数：`--skills`、`--skill NAME`、`--auto-skills`
- 交互命令：`skills`、`skills reload`、`skills create NAME`、`skill NAME`
- 工具调用：`activate_skill`

## Custom Commands

### 命令模板作用

命令模板适合封装重复性提示词和注入逻辑，例如代码搜索、提交信息生成、批量诊断。

### 目录

- 全局：`~/.config/minimax/commands`
- 项目：`.minimax/commands`

项目目录优先级高于全局目录。

### 命令映射

命令文件使用 TOML，路径会映射为命令名。例如：

- `git/commit.toml` 对应 `/git:commit`

### 交互命令

- `commands list`
- `commands show NAME`
- `commands reload`
- `/command [args]`

## Extensions

### Extensions 作用

Extensions 是对命令模板和 MCP 服务的一层分发封装，用来安装和启用一组能力。

### Manifest

扩展根目录要求包含 `minimax-extension.json`。

当前实现关注这些字段：

- `name`
- `version`
- `commands_path`
- `mcp_servers`

### Extensions 交互命令

- `extensions list`
- `extensions show NAME`
- `extensions install PATH|GIT`
- `extensions enable NAME`
- `extensions disable NAME`
- `extensions uninstall NAME`
- `extensions update [name]`

### 冲突处理

当扩展命令和已有命令重名时，系统会尝试生成带扩展名前缀的唯一名字，而不是直接覆盖。

## Experience

### Experience 作用

Experience 不是模型上下文记忆，而是本地知识沉淀层，用来记录任务经验并反哺技能。

### 存储位置

位于 `~/.config/minimax/knowledge`，下列副本会根据环境写入：

- SQLite
- JSONL
- Markdown

### 能力

- `experience add`
- `experience list`
- `experience show`
- `experience search`
- `experience prune`
- `skills sync`
- `sops sync`

当 AI 处于工具调用模式时，也可以直接调用 `record_experience`，将任务经验写入本地知识库并触发配置好的自动同步。

`skills sync` 支持 `concise`、`balanced`、`strict` 三种模式，把经验摘要写回技能内容。

`sops sync` 也支持 `concise`、`balanced`、`strict` 三种模式，把经验摘要升级为全局 SOP 文档。

SOP 还支持以下查看命令：

- `sops`
- `sops list`
- `sops show SKILL-NAME`

默认情况下，`experience add` 在写入 SQLite/JSONL/Markdown 后，会继续自动执行两步：

- 把当前 skill 的经验同步到 `~/.config/minimax/skills/{skill}/SKILL.md`
- 把当前 skill 的经验同步到 `~/.config/minimax/sops/{skill}/SOP.md`

可以通过以下配置项调整：

- `auto_write_skills=true|false`
- `auto_upgrade_sops=true|false`
- `knowledge_sync_mode=concise|balanced|strict`

## Hooks

### 作用

Hooks 让用户不改源码就能在关键事件点插入自定义 shell 命令，主要用途是安全护栏（阻断危险工具调用）和自动化审计。

### 配置位置

- ~/.config/minimax/hooks.json（文件不存在则钩子全部禁用）

### 示例配置

```json
{
  "hooks": [
    {"event": "PreToolUse", "matcher": "bash", "command": "echo denied >&2; exit 2", "timeout": 10},
    {"event": "PostToolUse", "command": "cat \"$MINIMAX_HOOK_INPUT\" >> ~/hook_audit.log"}
  ]
}
```

### 事件清单

- 可阻断（退出码 2 = deny，stderr 作为原因）：`UserPromptSubmit`（匹配用户输入文本）、`PreToolUse`（匹配工具名）、`Stop`（模型即将结束任务，每次任务最多被拦回一次）。
- 通知型（结果忽略）：`PostToolUse`、`PostToolUseFailure`（匹配工具名）、`SessionStart`（source=startup）、`SessionEnd`（reason=exit/interrupt）、`PreCompact`/`PostCompact`（trigger=auto）。

### 执行协议

- 命令通过 bash `-c` 执行，cwd 为启动目录，默认超时 30 秒（可配 1-600）。
- payload JSON 写入临时文件，路径经环境变量 `MINIMAX_HOOK_INPUT` 传入（不走 stdin：V 的 os.Process 无法关闭子进程 stdin）。
- 基础字段：`hook_event_name`、`session_id`、`cwd`；工具事件附加 `tool_name`、`tool_call_id`、`tool_input`（输出/错误截断到 2000 字符）。
- fail-open：除退出码 2 外（非零退出、超时、命令不存在、配置损坏）一律放行，钩子故障不影响主流程。
- 超时只 kill hook 进程组；若 hook fork 出持有管道的孙进程，输出读取采用非阻塞 drain（最多 ~200ms 宽限），不会被拖住。

### 实现位置

- [src/hooks.v](../src/hooks.v)：配置加载、匹配、执行器、阻断聚合。
- 触发点：[src/client.v](../src/client.v)（chat 入口、execute_tool_batch、Stop、PreCompact/PostCompact）、[src/main.v](../src/main.v)（SessionStart/SessionEnd）。

## 文档更新原则

扩展能力一旦变更，应至少同步以下文档：

- [README.md](../README.md)
- [AGENTS.md](../AGENTS.md)
- [docs/IMPLEMENTATION.md](IMPLEMENTATION.md)
- 本文档
