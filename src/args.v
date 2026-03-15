module main

import os

fn enable_auto_skills(mut client ApiClient) {
	client.auto_skills = true
	client.enable_tools = true
	if client.workspace.len == 0 {
		client.workspace = os.getwd()
	}
}

fn handle_early_cli_exit(args []string) bool {
	for arg in args[1..] {
		match arg {
			'--help', '-h' {
				print_help()
				return true
			}
			'--version' {
				println('minimax-cli ${version}')
				return true
			}
			else {}
		}
	}
	return false
}

fn apply_cli_boolean_flag(mut client ApiClient, arg string) bool {
	match arg {
		'--stream' {
			client.use_streaming = true
		}
		'--enable-tools' {
			client.enable_tools = true
		}
		'--auto-skills' {
			enable_auto_skills(mut client)
		}
		'--enable-desktop-control' {
			client.enable_desktop_control = true
			client.enable_tools = true
		}
		'--enable-screen-capture' {
			client.enable_screen_capture = true
			client.enable_tools = true
		}
		'--debug' {
			client.debug = true
		}
		'--log' {
			client.logger = new_logger(true)
		}
		'--trajectory' {
			client.trajectory = new_trajectory_recorder(true)
		}
		'--plan' {
			client.plan_mode = true
			client.enable_tools = true
		}
		else {
			return false
		}
	}
	return true
}

struct CliRuntimeFlags {
mut:
	mcp_enabled     bool
	acp_mode        bool
	term_ui_mode    bool
	interactive_set bool
	is_interactive  bool = true
	show_skills     bool
}

fn apply_cli_runtime_flag(mut client ApiClient, arg string, mut runtime_flags CliRuntimeFlags) bool {
	match arg {
		'--mcp' {
			runtime_flags.mcp_enabled = true
			client.enable_tools = true
		}
		'--acp' {
			runtime_flags.acp_mode = true
			client.enable_tools = true
			runtime_flags.interactive_set = true
			runtime_flags.is_interactive = false
		}
		'--term-ui' {
			runtime_flags.term_ui_mode = true
			runtime_flags.interactive_set = true
			runtime_flags.is_interactive = true
		}
		'--skills' {
			runtime_flags.show_skills = true
		}
		else {
			return false
		}
	}
	return true
}

fn cli_option_takes_value(arg string) bool {
	return match arg {
		'-p', '--prompt', '--system', '--model', '--temperature', '--max-tokens', '--max-rounds',
		'--workspace', '--skill', '--output-format', '--token-limit' {
			true
		}
		else {
			false
		}
	}
}

fn detect_prompt_mode(args []string) !(string, bool) {
	mut prompt := ''
	mut is_interactive := true
	mut j := 1
	for j < args.len {
		arg := args[j]
		match arg {
			'-p', '--prompt' {
				if j + 1 >= args.len {
					return error('missing prompt')
				}
				return args[j + 1], false
			}
			else {
				if cli_option_takes_value(arg) && j + 1 < args.len {
					j += 2
					continue
				}
				if !arg.starts_with('-') {
					prompt = arg
					is_interactive = false
				}
			}
		}
		j++
	}
	return prompt, is_interactive
}

fn build_help_text() string {
	return [
		'\x1b[1;36mMiniMax CLI ${version}\x1b[0m — AI Agent 命令行工具',
		'',
		'\x1b[1m用法:\x1b[0m',
		'  minimax_cli                     交互模式（默认）',
		'  minimax_cli -p "你的问题"       单次提问模式 (Headless)',
		'  minimax_cli -p "问题" --output-format json  JSON输出模式',
		'  minimax_cli -p "问题" --output-format plain 纯文本输出',
		'  minimax_cli --help             显示帮助信息',
		'  minimax_cli --version          显示版本信息',
		'  minimax_cli --quota            查看 Coding Plan 剩余用量',
		'  minimax_cli cron ...           本地 Cron 任务管理',
		'  minimax_cli --term-ui          启动 term.ui 交互界面',
		'  minimax_cli --skills           列出所有可用技能',
		'',
		'\x1b[1m参数选项:\x1b[0m',
		'  --model <name>                 选择模型 (default: MiniMax-M2.5)',
		'  --temperature <0.0-2.0>        调整创意度 (default: 0.7)',
		'  --max-tokens <n>               限制输出长度，最大 1000000 (default: 200000)',
		'  --system <prompt>              设置系统提示词',
		'  --skill <name>                 使用技能 (内置/自定义 SKILL.md)',
		'  --auto-skills                  暴露所有已发现 skills，让 AI 自动选择并激活最合适的 skill',
		'  --stream                       启用流式响应模式',
		'  --enable-tools                 启用AI工具调用（AI可主动读写文件/执行命令）',
		'  --enable-desktop-control       启用鼠标/键盘控制工具（高权限）',
		'  --enable-screen-capture        启用屏幕截图工具',
		'  --mcp                          启用MCP服务（加载 ~/.config/minimax/mcp.json 配置）',
		'  --acp                          启动 ACP stdio server 模式（MVP）',
		'  --term-ui                      使用 term.ui 终端界面（交互模式）',
		'  --max-rounds <1-${max_tool_call_rounds}>          最大工具调用轮数 (default: 5000)',
		'  --token-limit <n>              上下文自动摘要阈值 (default: 80000)',
		'  --workspace <path>             工作目录（相对路径基准）',
		'  --log                          启用文件日志 (~/.config/minimax/logs/)',
		'  --trajectory                   启用执行轨迹记录 (~/.config/minimax/trajectories/)',
		'  --output-format <text|json|plain>  输出格式 (headless模式)',
		'  --plan                         Plan模式（AI先制定计划，确认后执行）',
		'  --debug                        显示调试日志',
		'',
		'\x1b[1m交互模式命令:\x1b[0m',
		'  exit, quit                     退出程序',
		'  clear                          清空对话历史',
		'  config                         查看当前配置',
		'  doctor / doctor desktop        检查桌面控制/截图依赖与权限',
		'  doctor help                    查看桌面联调命令',
		'  doctor test ...                显式执行截图/鼠标/键盘联调动作',
		'  tools / tools on / tools off   查看/开关AI工具调用',
		'  skills                         列出所有技能 (内置+自定义)',
		'  skills reload                  重新扫描自定义技能',
		'  skills create <name>           创建自定义技能模板',
		'  skills sync <name|all> [mode]  同步全局 skill，mode=concise|balanced|strict',
		'  skill <name>                   切换到指定技能',
		'  experience                     查看经验库命令帮助',
		'  experience add                 启动交互式经验录入向导',
		'  experience add <payload>       记录一条经验到 SQLite/JSONL/Markdown',
		'  experience list [skill]        列出最近经验记录',
		'  experience show <id>           查看单条经验详情',
		'  experience search <query>      搜索本地经验库',
		'  experience prune <...>         删除经验记录 (id/all/skill <name>)',
		'  commands / commands list       列出可用自定义命令',
		'  commands show <name>           查看命令模板详情',
		'  commands reload                重新加载命令目录',
		'  extensions list                列出已安装扩展',
		'  extensions show <name>         查看扩展详情',
		'  extensions install <path|git>  从本地目录或 Git 安装扩展',
		'  extensions enable <name>       启用扩展',
		'  extensions disable <name>      禁用扩展',
		'  extensions uninstall <name>    卸载扩展',
		'  extensions update [name]       更新一个或全部扩展',
		'  /<command> [args]              执行自定义命令模板',
		'  notes                          查看 Session Notes',
		'  notes clear                    清空 Session Notes',
		'  log / log on / log off         查看/开关文件日志',
		'  trajectory / trajectory on/off  查看/开关轨迹记录',
		'  plan / plan on / plan off       查看/开关 Plan 模式',
		'  checkpoint [label]              创建检查点',
		'  checkpoints                     列出所有检查点',
		'  restore [N]                     恢复到检查点 (默认最新)',
		'  quota                          查看 Coding Plan 剩余用量',
		'  cron ...                       本地 Cron 任务管理（建议用子命令模式）',
		'  mcp / mcp start / mcp stop     MCP服务管理',
		'',
		'\x1b[1m手动工具（# 前缀）:\x1b[0m',
		'  #read <path>                   读取文件',
		'  #write <path> <content>        写入文件',
		'  #ls <path>                     列出目录',
		'  #run <command>                 执行命令',
		'',
		'\x1b[1m快捷语法:\x1b[0m',
		'  @path/to/file                  引用文件内容 (附加到提问)',
		'  !command                       直接执行 Shell 命令',
		'',
		'\x1b[1m配置文件\x1b[0m (~/.config/minimax/config):',
		'  api_key=sk-cp-xxx              API Key（必填）',
		'  model=MiniMax-M2.5',
		'  temperature=0.7',
		'  max_tokens=102400',
		'  enable_tools=true',
		'  auto_skills=false',
		'  enable_desktop_control=false',
		'  enable_screen_capture=false',
		'  enable_logging=true',
		'  max_rounds=5000',
		'  token_limit=80000',
		'  workspace=/path/to/project',
	].join('\n')
}

fn print_help() {
	println(build_help_text())
	println('')
	println('\x1b[1m环境变量:\x1b[0m')
	println('  MINIMAX_API_KEY                API Key（优先级最高）')
	println('  MINIMAX_MODEL                  选择模型')
	println('  MINIMAX_TEMPERATURE            创意度')
	println('  MINIMAX_MAX_TOKENS             输出长度')
	println('  MINIMAX_SYSTEM_PROMPT          系统提示词')
	println('  MINIMAX_ENABLE_TOOLS           启用AI工具 (true/1)')
	println('  MINIMAX_AUTO_SKILLS            自动暴露并激活匹配的 skills (true/1)')
	println('  MINIMAX_ENABLE_DESKTOP_CONTROL 启用鼠标/键盘控制 (true/1)')
	println('  MINIMAX_ENABLE_SCREEN_CAPTURE  启用屏幕截图 (true/1)')
	println('  MINIMAX_ENABLE_LOGGING         启用文件日志 (true/1)')
	println('  MINIMAX_DEBUG                  启用调试日志 (true/1)')
	println('  MINIMAX_MAX_ROUNDS             最大工具调用轮数')
	println('  MINIMAX_TOKEN_LIMIT            上下文自动摘要阈值')
	println('  MINIMAX_WORKSPACE              工作目录')
	println('')
	println('\x1b[1m示例:\x1b[0m')
	println('  ./minimax_cli -p "Hello" --temperature 0.5')
	println('  ./minimax_cli --enable-tools -p "读取当前目录的文件列表"')
	println('  ./minimax_cli --auto-skills -p "帮我管理后台任务"')
	println('  ./minimax_cli --mcp --enable-screen-capture -p "截图并识别屏幕中的文字"')
	println('  ./minimax_cli --skill coder --enable-tools -p "重构main.v"')
	println('  ./minimax_cli --mcp -p "搜索一下V语言最新版本"')
	println('  ./minimax_cli --log -p "调试这个Bug" --enable-tools')
	println('')
	println('\x1b[1mMCP 服务:\x1b[0m')
	println('  内置: MiniMax MCP (web_search, understand_image)，--mcp 自动启用')
	println('  额外配置 (~/.config/minimax/mcp.json):')
	println('  {"servers":{"playwright":{"type":"stdio","command":"npx","args":["-y","@playwright/mcp@latest"]}}}')
}
