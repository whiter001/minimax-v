# 快捷命令调用封装
# 默认已开启: enable_tools, auto_skills, enable_logging
# 仅显式启用: refine(提示词优化), trajectory(轨迹记录)
#
# 使用方式:
#   source config.nu   # 加载函数
#   mi "帮我重构 main.v"  # 基础模式
#   ma "用 playwright 打开 GitHub"  # MCP 模式
def mi [msg: string] {
  minimax_cli --refine --trajectory -system '你是各个领域的编程专家，擅长分析和解决复杂的技术问题。当你发现新的技术模式，必须调用 record_experience 记录经验。完成任务后主动总结关键步骤和可能的优化点。' -p $msg
}

# 多 MCP 版本的调用封装（支持 playwright 等浏览器自动化）
def ma [msg: string] {
  minimax_cli --refine --trajectory --mcp -system '你是专业的浏览器自动化助手，熟练使用 playwright 完成任务。善于发现页面结构和新的接口模式，并记录经验。' -p $msg
}