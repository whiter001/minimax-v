# minimax-v TODO

## ✅ v1 已完成 (15项)

- [x] #write 偏移量 / 流式响应 / 配置=分割 / DEBUG开关 / 版本同步
- [x] HTTP超时 / JSON解析 / 信号处理 / 危险命令 / README
- [x] MCP轮询 / 参数校验 / JSON转义 / 死代码 / enable_tools一致性

## ✅ v2 已完成 (10项) — 对标 Mini-Agent

- [x] 1. Interleaved Thinking 支持
- [x] 2. 工具调用轮数 25 + `--max-rounds`
- [x] 3. 流式 + 工具调用组合模式
- [x] 4. 上下文自动摘要
- [x] 5. `--workspace` 工作目录
- [x] 6. 工具输出截断
- [x] 7. 默认 Agent 系统提示词
- [x] 8. `config` 命令增强
- [x] 9. 版本号 v0.7.0
- [x] 10. config 支持 max_rounds/workspace/token_limit

## ✅ v2.5 已完成 (5项) — 对标 Mini-Agent Phase 2

- [x] 11. Session Note 持久化记忆
- [x] 12. Claude Skills 15 专业角色
- [x] 13. Logging 日志系统
- [x] 14. Agent Loop 鲁棒性 (重试+退避)
- [x] 15. CLI 美化 (Box Banner + 彩色提示)

---

## ✅ v3 已完成 (9项) — 对标 Trae Agent (ByteDance)

> 版本: v0.8.0

### ✅ P0 — 核心工具升级

- [x] 1. **str_replace 精确编辑工具** — view/create/str_replace/insert 四子命令
- [x] 2. **持久化 Bash 会话** — cwd/env 状态保持, 120s 超时, 会话重启

### ✅ P1 — Agent 架构升级

- [x] 3. **Agent 状态机** — 5 状态生命周期 (thinking/calling_tool/reflecting/completed/error)
- [x] 4. **反思机制** — 工具失败自动反思 + 修正引导
- [x] 5. **Trajectory 轨迹记录** — JSON 完整记录, --trajectory 参数 + trajectory 命令

### ✅ P2 — 新工具

- [x] 6. **task_done 完成信号** — 显式完成 + 自动退出工具循环
- [x] 7. **代码搜索工具** — grep_search (正则搜索) + find_files (文件查找)

### ✅ P3 — 高级功能

- [x] 8. **sequentialthinking 思考链** — 结构化推理 + 修正/分支支持
- [x] 9. **JSON 编辑工具** — view/set/add/remove via jq (dot-notation 路径)

---

## 📋 v4 待实施 — 对标 Gemini CLI + Copilot CLI

> 目标版本: v0.9.0

### 🔴 P0 — 核心功能

- [x] 1. **Headless 非交互模式** — `-p "prompt"` 单次执行, 支持 JSON/文本输出, 退出码
- [x] 2. **AGENTS.md 上下文注入** — 项目级 `.agents/AGENTS.md` + 用户级 `~/.config/minimax/AGENTS.md`, 启动时自动加载为系统提示词
- [x] 3. **ask_user 工具** — AI 主动向用户提问澄清, 阻塞等待输入

### 🟠 P1 — Agent 增强

- [x] 4. **Plan 模式** — 先规划后执行, plan/execute 两阶段
- [x] 5. **Checkpointing 检查点** — 文件修改前自动快照 (git stash 或 cp), `/restore` 恢复
- [x] 6. **TODO 任务管理工具** — write_todos 子任务列表, AI 自主规划进度

### 🟡 P2 — 体验提升

- [x] 7. **@ 文件引用语法** — `@path/file` 直接附加文件内容到 prompt
- [x] 8. **! Shell 快捷语法** — `!command` 直接执行 shell 命令
- [x] 9. **read_many_files 工具** — 一次读取多文件 + glob 匹配
- [x] 10. **版本号 v0.9.0**
