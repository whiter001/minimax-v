# 扩展机制

当前仓库的扩展能力不是单一系统，而是四套机制叠加：MCP、Skills、Custom Commands、Extensions。Experience 则承担长期知识沉淀。

## MCP

### 作用

MCP 用于把外部工具以 stdio JSON-RPC 的方式接入到 CLI。

### 配置位置

- ~/.config/minimax/mcp.json

### 典型场景

- Web 搜索。
- 图像理解。
- Playwright 浏览器自动化。
- 其他兼容 MCP 的本地或远程工具。

### 行为特征

- 使用 --mcp 时会启用内置 MiniMax MCP 能力。
- 额外服务从 mcp.json 读取。
- MCP 工具在运行时发现，不是编译期写死。
- 退出时会尝试统一回收子进程。

## Skills

### 发现顺序

技能优先级从低到高如下：

1. 内置技能。
2. 用户技能，目录为 ~/.config/minimax/skills 或 ~/.agents/skills。
3. 项目技能，目录为 .agents/skills。

项目级会覆盖同名用户级和内置技能。

补充说明：

- 用户级技能默认会被扫描，无需额外参数。
- 项目级 `.agents/skills` 只有在 workspace 已设置时才会被扫描；可通过 `--workspace <path>` 或环境变量 `MINIMAX_WORKSPACE` 指定。
- `--skills` 用于列出当前已发现的技能，`--skill <name>` 用于直接启用某个技能。
- `--auto-skills` 会让 AI 优先自行决定是否激活某个 skill；若未显式设置 workspace，则默认使用当前目录来纳入项目级 `.agents/skills`。

### 文件格式

技能文件名固定为 SKILL.md，使用 YAML frontmatter 声明元信息：

```md
---
name: reviewer
description: Review code changes for bugs and regressions
---

这里开始写技能正文，正文会作为系统提示注入。
```

### 使用方式

- CLI 参数：--skills、--skill <name>、--auto-skills
- 交互命令：skills、skills reload、skills create <name>、skill <name>
- 工具调用：activate_skill

## Custom Commands

### 作用

命令模板适合封装重复性提示词和注入逻辑，例如代码搜索、提交信息生成、批量诊断。

### 目录

- 全局：~/.config/minimax/commands
- 项目：.minimax/commands

项目目录优先级高于全局目录。

### 命名规则

命令文件使用 TOML，路径会映射为命令名。例如：

- git/commit.toml 对应 /git:commit

### 交互命令

- commands list
- commands show <name>
- commands reload
- /<command> [args]

## Extensions

### 作用

Extensions 是对命令模板和 MCP 服务的一层分发封装，用来安装和启用一组能力。

### Manifest

扩展根目录要求包含 minimax-extension.json。

当前实现关注这些字段：

- name
- version
- commands_path
- mcp_servers

### 交互命令

- extensions list
- extensions show <name>
- extensions install <path|git>
- extensions enable <name>
- extensions disable <name>
- extensions uninstall <name>
- extensions update [name]

### 冲突处理

当扩展命令和已有命令重名时，系统会尝试生成带扩展名前缀的唯一名字，而不是直接覆盖。

## Experience

### 作用

Experience 不是模型上下文记忆，而是本地知识沉淀层，用来记录任务经验并反哺技能。

### 存储位置

位于 ~/.config/minimax/knowledge，下列副本会根据环境写入：

- SQLite
- JSONL
- Markdown

### 能力

- experience add
- experience list
- experience show
- experience search
- experience prune
- skills sync
- sops sync

当 AI 处于工具调用模式时，也可以直接调用 `record_experience`，将任务经验写入本地知识库并触发配置好的自动同步。

skills sync 支持 concise、balanced、strict 三种模式，把经验摘要写回技能内容。

sops sync 也支持 concise、balanced、strict 三种模式，把经验摘要升级为全局 SOP 文档。

SOP 还支持以下查看命令：

- `sops`
- `sops list`
- `sops show <skill-name>`

默认情况下，experience add 在写入 SQLite/JSONL/Markdown 后，会继续自动执行两步：

- 把当前 skill 的经验同步到 `~/.config/minimax/skills/<skill>/SKILL.md`
- 把当前 skill 的经验同步到 `~/.config/minimax/sops/<skill>/SOP.md`

可以通过以下配置项调整：

- `auto_write_skills=true|false`
- `auto_upgrade_sops=true|false`
- `knowledge_sync_mode=concise|balanced|strict`

## 文档更新原则

扩展能力一旦变更，应至少同步以下文档：

- [README.md](../README.md)
- [AGENTS.md](../AGENTS.md)
- [docs/IMPLEMENTATION.md](IMPLEMENTATION.md)
- 本文档
