# 快捷命令调用封装
# 单入口 mi：自动分类任务
# - 文本/代码任务：走保守 refine
# - 截屏/网页/桌面/命令任务：跳过 refine，直接开工具
#
# 使用方式:
#   source config.nu   # 加载函数
#   mi "帮我重构 main.v"
#   mi "用 playwright 打开 GitHub"
#   mi "截取当前屏幕并分析"

def is_screen_task [text: string] {
  (
    ($text | str contains '截图') or
    ($text | str contains '截屏') or
    ($text | str contains '屏幕') or
    ($text | str contains '识图') or
    ($text | str contains '看图') or
    ($text | str contains '图片') or
    ($text | str contains 'screen_analyze') or
    ($text | str contains 'capture_screen')
  )
}

def is_browser_task [text: string] {
  (
    ($text | str contains '网页') or
    ($text | str contains '浏览器') or
    ($text | str contains 'playwright') or
    ($text | str contains 'mcp') or
    ($text | str contains 'web_search') or
    ($text | str contains '搜索一下') or
    ($text | str contains '打开网站') or
    ($text | str contains '打开网页')
  )
}

def is_desktop_task [text: string] {
  (
    ($text | str contains '鼠标') or
    ($text | str contains '键盘') or
    ($text | str contains '点击') or
    ($text | str contains '双击') or
    ($text | str contains '拖拽') or
    ($text | str contains '输入') or
    ($text | str contains '桌面') or
    ($text | str contains '记事本') or
    ($text | str contains '窗口')
  )
}

def is_command_task [text: string] {
  (
    ($text | str contains '执行命令') or
    ($text | str contains 'run_command') or
    ($text | str contains 'bash') or
    ($text | str contains 'shell') or
    ($text | str contains '终端') or
    ($text | str contains 'powershell')
  )
}

def is_tool_task [text: string] {
  (
    (is_screen_task $text) or
    (is_browser_task $text) or
    (is_desktop_task $text) or
    (is_command_task $text) or
    ($text | str contains '读文件') or
    ($text | str contains '写文件') or
    ($text | str contains '列出目录') or
    ($text | str contains 'read_file') or
    ($text | str contains 'write_file') or
    ($text | str contains 'list_dir')
  )
}

def mi [msg: string] {
  let text = ($msg | str downcase)

  if (is_screen_task $text) {
    minimax_cli --trajectory --enable-tools --mcp --enable-screen-capture -system '你是专业的屏幕分析助手。先截取屏幕，再结合图片内容回答；只在必要时解释，优先给出结论和可执行建议。' -p $msg
  } else if (is_browser_task $text) {
    minimax_cli --trajectory --enable-tools --mcp -system '你是专业的网页与浏览器自动化助手。先执行网页搜索、浏览器操作或 MCP 工具，再简洁汇报结果。' -p $msg
  } else if (is_desktop_task $text) {
    minimax_cli --trajectory --enable-tools --enable-desktop-control -system '你是专业的桌面自动化助手。直接使用鼠标、键盘和命令工具完成任务，避免把执行型请求改写成解释。' -p $msg
  } else if (is_command_task $text) {
    minimax_cli --trajectory --enable-tools -system '你是执行型编程助手。面对命令、脚本或终端任务时，优先直接执行并返回结果，保持步骤简洁。' -p $msg
  } else if (is_tool_task $text) {
    minimax_cli --trajectory --enable-tools -system '你是一个执行型编程助手。遇到文件、命令或脚本任务时，优先使用工具完成任务，保持步骤简洁。' -p $msg
  } else {
    minimax_cli --refine --trajectory -system '你是一个严谨的编程专家。优先保留用户原始意图，避免擅自改变任务类型；如果信息不足，只补充最少必要上下文。完成任务后主动总结关键步骤和可能的优化点。' -p $msg
  }
}


