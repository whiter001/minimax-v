# 文档索引

这套文档只保留当前实现仍然成立的内容，目标是让使用者、维护者和智能体都能在最短路径内找到可信信息。

## 阅读顺序

1. [README.md](../README.md)：项目入口、安装、使用方式、核心能力概览。
2. [ARCHITECTURE.md](ARCHITECTURE.md)：系统结构、主流程、关键状态和数据流。
3. [IMPLEMENTATION.md](IMPLEMENTATION.md)：按源码文件梳理模块职责与边界。
4. [EXTENSIBILITY.md](EXTENSIBILITY.md)：MCP、技能、命令模板、扩展和经验库机制。
5. [DEVELOPMENT.md](DEVELOPMENT.md)：构建、格式化、测试、提交流程和排障约定。

## API 参考

1. [api-reference/speech-synthesis.md](api-reference/speech-synthesis.md)：语音合成参考，覆盖同步 T2A 和异步长文本语音生成。
2. [api-reference/image-generation.md](api-reference/image-generation.md)：图像生成参考，覆盖模型、能力和使用流程。
3. [api-reference/file-management-list.md](api-reference/file-management-list.md)：文件列出参考，覆盖文件分类、鉴权和响应结构。

## 文档原则

- 只记录已经进入主分支实现的能力。
- 所有默认值以源码为准，优先参考 [src/config.v](../src/config.v) 和 [src/main.v](../src/main.v)。
- 所有交互命令以帮助文本和解析逻辑为准，优先参考 [src/main.v](../src/main.v)。
- 所有扩展能力以各模块源码为准，不再维护历史报告、阶段计划和对比材料。

## 不再保留的内容

- 阶段性计划、验证报告、临时总结。
- 已经过时的功能对比、路线图和操作草稿。
- 和当前仓库行为不一致的使用指南。

如果需要补充新文档，优先更新现有文件，而不是继续扩张 docs 目录。
