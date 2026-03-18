module main

import os
import readline
import strconv

const version = 'v0.9.0'

__global g_mcp_manager = &McpManager(unsafe { nil })
__global g_shutting_down = false
__global g_acp_mode = false

fn sigint_handler(_ os.Signal) {
	// Prevent re-entrant signal handling which causes segfault
	if g_shutting_down {
		exit(130)
	}
	g_shutting_down = true
	if g_mcp_manager != unsafe { nil } {
		unsafe {
			g_mcp_manager.stop_all()
		}
	}
	if !g_acp_mode {
		println('\n👋 已中断')
	}
	exit(130)
}

// confirm_refined_prompt displays a refined prompt and asks the user for confirmation
fn confirm_refined_prompt(refined string) bool {
	println('\x1b[1;33m✨ 优化后的提示词:\x1b[0m\n${refined}\n')
	print('\x1b[1m是否使用优化后的提示词? [Y/n]: \x1b[0m')
	os.flush()
	answer := os.get_line().trim_space().to_lower()
	if answer == '' || answer == 'y' || answer == 'yes' {
		println('\x1b[32m已采用优化后的提示词。\x1b[0m\n')
		return true
	}
	println('\x1b[33m已跳过优化，使用原始提示词。\x1b[0m\n')
	return false
}

// Expand @file references in user input
// Supports: @path/to/file — reads file content and appends it to the prompt
fn expand_file_references(input string, workspace string) string {
	// Find all @path patterns (not preceded by letter/digit, followed by a valid path)
	mut result := input
	mut expanded := []string{}
	words := input.split(' ')
	for word in words {
		w := word.trim_space()
		if w.starts_with('@') && w.len > 1 {
			fpath := w[1..]
			resolved := resolve_workspace_path(fpath, workspace)
			if os.is_file(resolved) {
				content := os.read_file(resolved) or { continue }
				// Truncate large files
				display := if content.len > 50000 {
					utf8_safe_truncate(content, 50000) +
						'\n... (truncated, ${content.len} chars total)'
				} else {
					content
				}
				expanded << '--- File: ${fpath} ---\n${display}\n--- End: ${fpath} ---'
				println('\x1b[2m📎 Attached: ${fpath} (${content.len} chars)\x1b[0m')
			}
		}
	}
	if expanded.len > 0 {
		// Remove @references from text and append content
		for word in words {
			w := word.trim_space()
			if w.starts_with('@') && w.len > 1 {
				fpath := w[1..]
				resolved := resolve_workspace_path(fpath, workspace)
				if os.is_file(resolved) {
					result = result.replace(word, '')
				}
			}
		}
		result = result.trim_space()
		if result.len > 0 {
			result = '${result}\n\n${expanded.join('\n\n')}'
		} else {
			result = expanded.join('\n\n')
		}
	}
	return result
}

fn main() {
	args := os.args
	if is_cron_cli_subcommand(args) {
		exit_code := handle_cron_cli_command(args[2..])
		if exit_code != 0 {
			exit(exit_code)
		}
		return
	}
	if handle_early_cli_exit(args) {
		return
	}

	mut config := load_config_file()
	apply_env_overrides(mut config)

	mut prompt := ''
	mut is_interactive := true
	prompt, is_interactive = detect_prompt_mode(args) or {
		println('❌ 错误: -p/--prompt 参数需要提供内容')
		println('用法: minimax_cli -p "你的问题"')
		exit(42)
	}

	// Validate API key
	if config.api_key.len == 0 {
		println('❌ 未配置 API Key')
		println('')
		println('请通过以下方式之一设置：')
		println('  1. 配置文件 ~/.config/minimax/config:')
		println('     api_key=sk-cp-xxx')
		println('  2. 环境变量:')
		println('     export MINIMAX_API_KEY=sk-cp-xxx')
		exit(1)
	}

	mut client := new_api_client(config)
	if client.auto_skills {
		enable_auto_skills(mut client)
	}
	mut mcp_enabled := false
	mut acp_mode := false
	mut term_ui_mode := false
	mut current_skill := ''
	mut output_format := 'text' // text, json, plain
	mut show_skills := false
	mut runtime_flags := CliRuntimeFlags{}

	// Initialize skill registry with workspace
	init_skill_registry(client.workspace)
	init_command_registry(client.workspace)

	// Register signal handler for graceful shutdown
	os.signal_opt(.int, sigint_handler) or {}

	mut k := 1
	for k < args.len {
		arg := args[k]
		if apply_cli_runtime_flag(mut client, arg, mut runtime_flags) {
			k++
			continue
		}
		if apply_cli_boolean_flag(mut client, arg) {
			k++
			continue
		}
		match arg {
			'-p', '--prompt' {
				// Handled in pre-scan
			}
			'--system' {
				if k + 1 < args.len {
					k++
					client.system_prompt = args[k]
				}
			}
			'--model' {
				if k + 1 < args.len {
					k++
					client.model = args[k]
				}
			}
			'--temperature' {
				if k + 1 < args.len {
					k++
					if temp := strconv.atof64(args[k]) {
						if temp > 0.0 && temp <= 1.0 {
							client.temperature = temp
						} else {
							println('⚠️  temperature 应在 (0.0, 1.0] 之间，已忽略')
						}
					}
				}
			}
			'--max-tokens' {
				if k + 1 < args.len {
					k++
					if tokens := strconv.atoi(args[k]) {
						if is_valid_max_tokens(tokens) {
							client.max_tokens = i32(tokens)
						} else {
							println('⚠️  max-tokens 应在 1-${max_response_tokens} 之间，已忽略')
						}
					}
				}
			}
			'--max-rounds' {
				if k + 1 < args.len {
					k++
					if rounds := strconv.atoi(args[k]) {
						if is_valid_max_rounds(rounds) {
							client.max_rounds = rounds
						} else {
							println('⚠️  max-rounds 应在 1-${max_tool_call_rounds} 之间，已忽略')
						}
					}
				}
			}
			'--workspace' {
				if k + 1 < args.len {
					k++
					client.workspace = args[k]
				}
			}
			'--skill' {
				if k + 1 < args.len {
					k++
					if skill := find_skill(args[k]) {
						client.auto_skills = false
						client.system_prompt = skill.prompt
						client.enable_tools = true
						current_skill = skill.name
						skill_registry.active_skill = skill.name
					} else {
						println('⚠️  未知技能: ${args[k]}')
						print_skills_list()
						return
					}
				}
			}
			'--output-format' {
				if k + 1 < args.len {
					k++
					output_format = args[k]
				}
			}
			'--token-limit' {
				if k + 1 < args.len {
					k++
					if limit := strconv.atoi(args[k]) {
						if limit > 0 && limit <= 200000 {
							client.token_limit = limit
						} else {
							println('⚠️  token-limit 应在 1-200000 之间，已忽略')
						}
					}
				}
			}
			'--quota' {
				print_quota(client)
				return
			}
			else {
				if !arg.starts_with('-') {
					prompt = arg
					is_interactive = false
				}
			}
		}
		k++
	}
	mcp_enabled = runtime_flags.mcp_enabled
	acp_mode = runtime_flags.acp_mode
	term_ui_mode = runtime_flags.term_ui_mode
	if runtime_flags.interactive_set {
		is_interactive = runtime_flags.is_interactive
	}
	show_skills = runtime_flags.show_skills

	if acp_mode {
		g_acp_mode = true
		set_tool_capabilities(client.enable_desktop_control, client.enable_screen_capture)
		run_acp_server(client) or {
			eprintln('ACP server error: ${err}')
			exit(1)
		}
		return
	}

	// Load MCP servers if enabled
	if mcp_enabled {
		init_mcp(mut client)
	}

	set_tool_capabilities(client.enable_desktop_control, client.enable_screen_capture)
	bash_session = new_bash_session(client.workspace)

	// Re-init skill registry with final workspace (--workspace may override)
	reload_skill_registry(client.workspace)
	reload_command_registry(client.workspace)

	// Handle deferred --skills flag (after workspace is set)
	if show_skills {
		print_skills_list()
		return
	}

	client.logger.log_session_start(version, client.model)

	mut exit_code := 0
	if is_interactive {
		client.interactive_mode = true
		if term_ui_mode {
			start_term_ui(mut client, current_skill, prompt)
		} else {
			interactive_mode(mut client, current_skill)
		}
	} else if prompt.len > 0 {
		exit_code = headless_mode(mut client, prompt, output_format)
	} else {
		// -p flag was given but prompt is empty
		exit_code = headless_mode(mut client, '', output_format)
	}

	client.logger.log_session_end()

	// Cleanup MCP
	if mcp_enabled {
		client.mcp_manager.stop_all()
	}

	if exit_code != 0 {
		exit(exit_code)
	}
}

fn interactive_mode(mut client ApiClient, skill_name string) {
	println('\x1b[1;36m┌──────────────────────────────────────────┐\x1b[0m')
	println('\x1b[1;36m│\x1b[0m  🤖 \x1b[1mMiniMax CLI ${version}\x1b[0m                  \x1b[1;36m│\x1b[0m')
	println('\x1b[1;36m│\x1b[0m  Model: \x1b[33m${client.model}\x1b[0m              \x1b[1;36m│\x1b[0m')
	if skill_name.len > 0 {
		padded_skill := '\x1b[35m${skill_name}\x1b[0m'
		println('\x1b[1;36m│\x1b[0m  Skill: ${padded_skill}                          \x1b[1;36m│\x1b[0m')
	}
	println('\x1b[1;36m└──────────────────────────────────────────┘\x1b[0m')
	println('\x1b[2m命令: exit | clear | config | doctor | tools | skills | commands | extensions | notes | log | quota | mcp\x1b[0m')
	println('')

	mut rl := readline.Readline{}
	for {
		input := read_interactive_input(mut rl, '\x1b[1;34myou >\x1b[0m ') or { break }
		trimmed := input.trim_space()

		if trimmed.len == 0 {
			continue
		}

		mut action := handle_interactive_exact_command(mut client, trimmed)
		if action == .break_loop {
			break
		}
		if action == .continue_loop {
			continue
		}

		action = handle_interactive_prefixed_command(mut client, trimmed)
		if action == .continue_loop {
			continue
		}

		handle_interactive_general_input(mut client, trimmed)
	}
}

// Headless mode: non-interactive single prompt execution
// Returns exit code: 0=success, 1=error, 42=input error
fn headless_mode(mut client ApiClient, prompt string, output_format string) int {
	trimmed_prompt := prompt.trim_space()
	if trimmed_prompt.len == 0 {
		print_headless_error(output_format, 'empty prompt', 42)
		return 42
	}

	print_headless_banner(client, prompt, output_format)

	builtin_result := handle_builtin_command(prompt)
	if builtin_result.len > 0 {
		print_headless_basic_response(output_format, builtin_result)
		return 0
	}

	if trimmed_prompt.starts_with('/') {
		response := execute_custom_command(mut client, trimmed_prompt, false) or {
			print_headless_error(output_format, err.str(), 1)
			client.logger.log_error('COMMAND', err.str())
			return 1
		}
		print_headless_chat_response(client, output_format, response)
		return 0
	}

	// Expand @file references in headless mode too
	mut final_prompt := expand_file_references(prompt, client.workspace)

	if client.auto_refine {
		refined := client.refine_prompt(final_prompt) or { final_prompt }
		if refined != final_prompt {
			if client.auto_confirm_refine {
				final_prompt = refined
			} else if confirm_refined_prompt(refined) {
				final_prompt = refined
			}
		}
	}

	response := client.chat(final_prompt) or {
		print_headless_error(output_format, err.str(), 1)
		client.logger.log_error('CHAT', err.str())
		return 1
	}

	print_headless_chat_response(client, output_format, response)
	return 0
}

fn print_quota(client ApiClient) {
	println('📊 查询 Coding Plan 用量...')
	result := client.check_quota() or {
		println('❌ 查询失败: ${err}')
		return
	}
	println(result)
	println('')
}

fn init_mcp(mut client ApiClient) {
	client.mcp_manager = new_mcp_manager()
	g_mcp_manager = &client.mcp_manager

	// Built-in: MiniMax Coding Plan MCP (web_search + understand_image)
	minimax_mcp_env := {
		'MINIMAX_API_KEY':  client.api_key
		'MINIMAX_API_HOST': 'https://api.minimaxi.com'
	}
	client.mcp_manager.add_server('MiniMax', 'uvx', ['--native-tls', 'minimax-coding-plan-mcp',
		'-y'], minimax_mcp_env)
	println('[MCP] 已添加内置 MiniMax MCP (web_search, understand_image)')

	// Load additional servers from config file
	mcp_configs := load_mcp_config()
	if mcp_configs.len > 0 {
		for cfg in mcp_configs {
			client.mcp_manager.add_server(cfg.name, cfg.command, cfg.args, cfg.env)
		}
		println('[MCP] 从配置文件加载了 ${mcp_configs.len} 个额外 MCP 服务')
	}

	// Load extension-provided MCP servers (from extension manifest mcpServers)
	ext_mcp_count := add_extension_mcp_servers(mut client.mcp_manager)
	if ext_mcp_count > 0 {
		println('[MCP] 从扩展加载了 ${ext_mcp_count} 个 MCP 服务')
	}

	client.mcp_manager.start_all()
	client.enable_tools = true

	// Check if any server connected successfully
	mut connected := false
	for server in client.mcp_manager.servers {
		if server.is_connected {
			connected = true
			break
		}
	}

	if !connected {
		println('[MCP] ⚠️  注意: MCP服务初始化失败，将使用本地工具')
		println('[MCP] 💡 对于网页分析，建议使用: curl/PowerShell下载 + read_file工具分析')
	}
}

fn print_mcp_status(client ApiClient) {
	println('🔌 MCP 服务状态:')
	if client.mcp_manager.servers.len == 0 {
		println('  (无 MCP 服务)')
		println('  启动: 输入 "mcp start" 或使用 --mcp 参数')
		println('')
		return
	}

	for server in client.mcp_manager.servers {
		status := if server.is_connected { '✅ 已连接' } else { '❌ 断开' }
		println('  ${server.name}: ${status}')
		if server.is_connected {
			for tool in server.tools {
				println('    • ${tool.name} - ${tool.description}')
			}
		}
	}
	println('')
}
