module main

import os
import readline

const version = 'v0.9.0'

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
	mut parts := []string{}
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
				continue
			}
		}
		parts << word
	}
	mut result := parts.join(' ')
	if expanded.len > 0 {
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

	// Initialize skill registry with workspace
	init_skill_registry(client.workspace)
	init_command_registry(client.workspace)

	// Register signal handler for graceful shutdown
	os.signal_opt(.int, fn [mut client] (_ os.Signal) {
		// Prevent re-entrant signal handling which causes segfault
		if client.runtime_mark_shutting_down() {
			exit(130)
		}
		client.runtime_stop_all_mcp()
		if !client.runtime_is_acp_mode() {
			println('\n👋 已中断')
		}
		exit(130)
	}) or {}
	cli_state := parse_cli_args(mut client, args, prompt, is_interactive)
	prompt = cli_state.prompt
	is_interactive = cli_state.is_interactive
	current_skill := cli_state.current_skill
	output_format := cli_state.output_format
	runtime_flags := cli_state.runtime_flags
	client.current_skill = current_skill
	if cli_state.should_print_quota {
		print_quota(client)
		return
	}
	mcp_enabled := runtime_flags.mcp_enabled
	acp_mode := runtime_flags.acp_mode
	term_ui_mode := runtime_flags.term_ui_mode
	if runtime_flags.interactive_set {
		is_interactive = runtime_flags.is_interactive
	}
	show_skills := runtime_flags.show_skills
	client.acp_mode = acp_mode

	if acp_mode {
		client.runtime_set_acp_mode(true)
		run_acp_server(client) or {
			eprintln('ACP server error: ${err}')
			exit(1)
		}
		return
	}

	// Load external MCP servers (mcp.json + extensions) only when --mcp is passed
	if mcp_enabled {
		init_mcp_external(mut client)
	}

	// Re-init skill registry with final workspace (--workspace may override)
	reload_command_registry(client.workspace)

	// Handle deferred --skills flag (after workspace is set)
	if show_skills {
		print_skills_list(client.workspace, client.current_skill)
		return
	}

	client.logger.log_session_start(version, client.model)

	mut exit_code := 0
	if is_interactive {
		client.interactive_mode = true
		if term_ui_mode {
			start_term_ui(mut client, current_skill, prompt)
		} else {
			interactive_mode(mut client, current_skill, prompt)
		}
	} else if prompt.len > 0 {
		exit_code = headless_mode(mut client, prompt, output_format)
	} else {
		// -p flag was given but prompt is empty
		exit_code = headless_mode(mut client, '', output_format)
	}

	client.logger.log_session_end()

	// Cleanup MCP (always safe to call, even if only builtin was registered)
	client.runtime_stop_all_mcp()

	if exit_code != 0 {
		exit(exit_code)
	}
}

fn interactive_mode(mut client ApiClient, skill_name string, initial_prompt string) {
	println('\x1b[1;36m┌──────────────────────────────────────────┐\x1b[0m')
	println('\x1b[1;36m│\x1b[0m  🤖 \x1b[1mMiniMax CLI ${version}\x1b[0m                  \x1b[1;36m│\x1b[0m')
	println('\x1b[1;36m│\x1b[0m  Model: \x1b[33m${client.model}\x1b[0m              \x1b[1;36m│\x1b[0m')
	if skill_name.len > 0 {
		padded_skill := '\x1b[35m${skill_name}\x1b[0m'
		println('\x1b[1;36m│\x1b[0m  Skill: ${padded_skill}                          \x1b[1;36m│\x1b[0m')
	}
	println('\x1b[1;36m└──────────────────────────────────────────┘\x1b[0m')
	println('\x1b[2m命令: exit | clear | config | doctor | tools | skills | commands | extensions | notes | log | quota | mcp | speech\x1b[0m')
	println('')

	// Process initial prompt if provided (-i/--prompt-interactive)
	if initial_prompt.len > 0 {
		handle_interactive_general_input(mut client, initial_prompt)
	}

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

	builtin_result := handle_builtin_command_with_client(mut client, prompt)
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

// init_mcp_external loads additional MCP servers from mcp.json and extensions.
// Only called when --mcp flag is explicitly passed.
fn init_mcp_external(mut client ApiClient) {
	// Load additional servers from config file
	mcp_configs := load_mcp_config()
	if mcp_configs.len > 0 {
		mut loaded_config_count := 0
		for cfg in mcp_configs {
			if cfg.name.trim_space().len == 0 || cfg.command.trim_space().len == 0 {
				println('[MCP] ⚠️  跳过无效 MCP 配置: name="${cfg.name}" command="${cfg.command}"')
				continue
			}
			client.mcp_manager.add_server(cfg.name, cfg.command, cfg.args, cfg.env)
			loaded_config_count++
		}
		if loaded_config_count > 0 {
			println('[MCP] 从配置文件加载了 ${loaded_config_count} 个额外 MCP 服务')
		}
	}

	// Load extension-provided MCP servers (from extension manifest mcpServers)
	ext_mcp_count := add_extension_mcp_servers(mut client.mcp_manager)
	if ext_mcp_count > 0 {
		println('[MCP] 从扩展加载了 ${ext_mcp_count} 个 MCP 服务')
	}

	client.mcp_manager.start_eager_servers()

	// Check if any server connected successfully
	mut connected := false
	mut has_lazy_server := false
	for server in client.mcp_manager.servers {
		if server.is_connected {
			connected = true
			break
		}
		if server.lazy_start {
			has_lazy_server = true
		}
	}

	if connected {
		return
	}

	if has_lazy_server {
		println('[MCP] ⏳ MCP 服务已就绪，将在首次调用时启动')
	} else {
		println('[MCP] ⚠️  注意: MCP服务初始化失败，将使用本地工具')
		println('[MCP] 💡 对于网页分析，建议使用: curl/PowerShell下载 + read_file工具分析')
	}
}

fn print_mcp_status(client ApiClient) {
	println('🔌 MCP 服务状态:')
	if client.mcp_manager.servers.len == 0 {
		println('  (无 MCP 服务)')
		println('  启动: 使用 --mcp 参数加载外部 MCP 服务，或输入 "mcp start" 启动已加载服务')
		println('')
		return
	}

	for server in client.mcp_manager.servers {
		status := if server.is_connected {
			'✅ 已连接'
		} else if server.lazy_start {
			'⏳ 待启动'
		} else {
			'❌ 断开'
		}
		println('  ${server.name}: ${status}')
		if server.is_connected {
			for tool in server.tools {
				println('    • ${tool.name} - ${tool.description}')
			}
		} else if server.preset_tools.len > 0 {
			for tool in server.preset_tools {
				println('    • ${tool.name} - ${tool.description}')
			}
		}
	}
	println('')
}
