# 开发与验证

本文档面向仓库维护者和参与实现的智能体，描述当前最小可信的开发流程。

## 构建

### 标准构建

```bash
./build.sh
```

等价核心命令：

```bash
v -enable-globals -o minimax_cli src/
```

必须带 -enable-globals，因为项目显式使用了多个 __global 变量。

### 生产构建

```bash
v -enable-globals -prod .
```

## 运行

### 单次调用

```bash
./minimax_cli -p "介绍一下 V 语言"
```

### 交互模式

```bash
./minimax_cli
```

### term.ui

```bash
./minimax_cli --term-ui
```

### MCP

```bash
./minimax_cli --mcp -p "搜索一下 V 语言最新版本"
```

## 格式化

### V 源码

修改 .v 文件后立即执行：

```bash
v fmt -w src/xxx.v
```

仓库有强制校验脚本：

```bash
./tests/check_vfmt.sh
```

### Markdown

仓库约定优先使用 oxfmt 处理 Markdown；如果环境没有该命令，可以先保持手工格式稳定，再按需要补装。

## 测试

### 单元测试

```bash
v -enable-globals test src/
```

### 运行单文件测试

```bash
v -enable-globals test src/config_test.v
```

### 集成测试

```bash
./integration_test.sh
```

真实维护脚本位于 tests/integration_test.sh，根目录脚本是便捷入口。

### 综合测试

```bash
./comprehensive_test.sh
```

## Git Hooks

仓库内置可版本化 hooks，通过 scripts/install-git-hooks.sh 安装后使用 .githooks 目录。

当前约定：

- pre-commit：执行 tests/check_vfmt.sh
- pre-push：执行 build.sh 和 v -enable-globals test src/

## 变更原则

- 以源码为准，不让文档领先实现。
- 优先修根因，不堆表面补丁。
- 非任务相关问题不顺手扩大修复范围。
- 涉及参数、默认值、命令名变更时同步更新文档。

## 常见排障

### 构建失败并提示 globals

检查是否漏掉 -enable-globals。

### 技能未发现

检查：

- SKILL.md 文件名是否正确。
- YAML frontmatter 是否包含 name 和 description。
- 文件目录是否位于 .agents/skills 或 ~/.config/minimax/skills。

### 扩展未生效

检查：

- minimax-extension.json 是否存在。
- 扩展是否已 enable。
- commands_path 和 mcp 配置是否有效。

### macOS 交互输入异常

当前实现对 macOS 中文输入做了兼容性回退。如果问题出在 REPL 输入而不是模型响应，优先检查交互输入路径，而不是 API 层。