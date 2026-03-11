module main

import os
import readline
import strconv
import term
import term.termios

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

	mut config := load_config_file()
	apply_env_overrides(mut config)

	mut prompt := ''
	mut is_interactive := true

	// Handle --help and --version before API key check
	for j := 0; j < args.len; j++ {
		arg := args[j]
		match arg {
			'--help', '-h' {
				print_help()
				return
			}
			'--version' {
				println('minimax-cli ${version}')
				return
			}
			'-p', '--prompt' {
				if j + 1 < args.len {
					prompt = args[j + 1]
					is_interactive = false
				} else {
					println('❌ 错误: -p/--prompt 参数需要提供内容')
					println('用法: minimax_cli -p "你的问题"')
					exit(42)
				}
			}
			else {}
		}
	}

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
						if temp >= 0.0 && temp <= 2.0 {
							client.temperature = temp
						} else {
							println('⚠️  temperature 应在 0.0-2.0 之间，已忽略')
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
			'--help', '-h' {
				print_help()
				return
			}
			'--version' {
				println('minimax-cli ${version}')
				return
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

fn apply_cli_boolean_flag(mut client ApiClient, arg string) bool {
	match arg {
		'--stream' {
			client.use_streaming = true
		}
		'--enable-tools' {
			client.enable_tools = true
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

fn should_use_basic_interactive_input(user_os string) bool {
	return match user_os {
		'windows', 'macos' { true }
		else { false }
	}
}

fn delete_last_rune(input string) string {
	runes := input.runes()
	if runes.len == 0 {
		return ''
	}
	return runes[..runes.len - 1].string()
}

fn basic_input_visual_width_char(r rune) int {
	return if r > 127 { 2 } else { 1 }
}

fn basic_input_visual_width_runes(runes []rune) int {
	mut width := 0
	for r in runes {
		width += basic_input_visual_width_char(r)
	}
	return width
}

fn insert_rune_at_cursor(buffer []rune, cursor int, ch rune) ([]rune, int) {
	mut updated := buffer.clone()
	mut safe_cursor := cursor
	if safe_cursor < 0 {
		safe_cursor = 0
	} else if safe_cursor > updated.len {
		safe_cursor = updated.len
	}
	updated.insert(safe_cursor, ch)
	return updated, safe_cursor + 1
}

fn backspace_rune_at_cursor(buffer []rune, cursor int) ([]rune, int) {
	if cursor <= 0 || buffer.len == 0 {
		return buffer.clone(), if cursor < 0 {
			0
		} else {
			cursor
		}
	}
	mut updated := buffer.clone()
	updated.delete(cursor - 1)
	return updated, cursor - 1
}

fn delete_rune_at_cursor(buffer []rune, cursor int) ([]rune, int) {
	if cursor < 0 || cursor >= buffer.len || buffer.len == 0 {
		return buffer.clone(), if cursor < 0 {
			0
		} else {
			cursor
		}
	}
	mut updated := buffer.clone()
	updated.delete(cursor)
	return updated, cursor
}

fn redraw_basic_input_line(prompt string, buffer []rune, cursor int) {
	print('\r\x1b[2K${prompt}${buffer.string()}')
	suffix_width := if cursor >= 0 && cursor <= buffer.len {
		basic_input_visual_width_runes(buffer[cursor..])
	} else {
		0
	}
	if suffix_width > 0 {
		print('\x1b[${suffix_width}D')
	}
	flush_stdout()
}

fn handle_macos_escape_sequence(mut buffer []rune, cursor int, prompt string) int {
	mut next_cursor := cursor
	lead := input_character()
	if lead != `[` {
		return next_cursor
	}
	code := input_character()
	if code < 0 {
		return next_cursor
	}
	match u8(code) {
		`D` {
			if next_cursor > 0 {
				next_cursor--
				redraw_basic_input_line(prompt, buffer, next_cursor)
			}
		}
		`C` {
			if next_cursor < buffer.len {
				next_cursor++
				redraw_basic_input_line(prompt, buffer, next_cursor)
			}
		}
		`3` {
			tail := input_character()
			if u8(tail) == `~` {
				buffer, next_cursor = delete_rune_at_cursor(buffer, next_cursor)
				redraw_basic_input_line(prompt, buffer, next_cursor)
			}
		}
		else {}
	}
	return next_cursor
}

fn read_macos_interactive_input(prompt string) ?string {
	$if !macos && !linux {
		return os.input(prompt)
	}

	$if macos || linux {
		mut old_state := termios.Termios{}
		if termios.tcgetattr(0, mut old_state) != 0 {
			return os.input(prompt)
		}
		defer {
			termios.tcsetattr(0, C.TCSANOW, mut old_state)
		}

		mut state := old_state
		state.c_lflag &= termios.invert(termios.flag(C.ICANON) | termios.flag(C.ECHO))
		if termios.tcsetattr(0, C.TCSANOW, mut state) != 0 {
			return os.input(prompt)
		}

		mut buffer := []rune{}
		mut cursor := 0
		print(prompt)
		flush_stdout()

		for {
			ch := term.utf8_getchar() or {
				print('\n')
				return none
			}
			match ch {
				`\r`, `\n` {
					print('\n')
					return buffer.string()
				}
				27 {
					cursor = handle_macos_escape_sequence(mut buffer, cursor, prompt)
				}
				127, 8 {
					if cursor > 0 {
						buffer, cursor = backspace_rune_at_cursor(buffer, cursor)
						redraw_basic_input_line(prompt, buffer, cursor)
					}
				}
				4 {
					if buffer.len == 0 {
						print('\n')
						return none
					}
				}
				else {
					if ch >= 32 {
						buffer, cursor = insert_rune_at_cursor(buffer, cursor, ch)
						redraw_basic_input_line(prompt, buffer, cursor)
					}
				}
			}
		}
	}
	return none
}

fn read_interactive_input(mut rl readline.Readline, prompt string) ?string {
	// readline 在 Windows/macOS 终端下对中文输入法和部分宽字符光标定位不稳定，回退到 os.input 提升兼容性
	if should_use_basic_interactive_input(os.user_os()) {
		if os.user_os() == 'macos' {
			return read_macos_interactive_input(prompt)
		}
		return os.input(prompt)
	}
	return rl.read_line(strip_ansi_escape_sequences(prompt)) or { return none }
}

fn strip_ansi_escape_sequences(input string) string {
	mut out := []u8{cap: input.len}
	mut idx := 0
	for idx < input.len {
		if input[idx] == `\x1b` && idx + 1 < input.len && input[idx + 1] == `[` {
			idx += 2
			for idx < input.len {
				ch := input[idx]
				if (ch >= `A` && ch <= `Z`) || (ch >= `a` && ch <= `z`) {
					idx++
					break
				}
				idx++
			}
			continue
		}
		out << input[idx]
		idx++
	}
	return out.bytestr()
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

		match trimmed {
			'exit', 'quit' {
				println('👋 再见！')
				break
			}
			'clear' {
				client.clear_messages()
				println('✨ 历史已清空')
				continue
			}
			'config' {
				println('⚙️  当前配置:')
				println('  model: ${client.model}')
				println('  temperature: ${client.temperature}')
				println('  max_tokens: ${client.max_tokens}')
				println('  streaming: ${client.use_streaming}')
				println('  enable_tools: ${client.enable_tools}')
				println('  enable_desktop_control: ${client.enable_desktop_control}')
				println('  enable_screen_capture: ${client.enable_screen_capture}')
				effective_max := if client.max_rounds > 0 {
					client.max_rounds
				} else {
					max_tool_call_rounds
				}
				println('  max_rounds: ${effective_max}')
				effective_limit := if client.token_limit > 0 { client.token_limit } else { 80000 }
				println('  token_limit: ${effective_limit}')
				if client.workspace.len > 0 {
					println('  workspace: ${client.workspace}')
				}
				if client.system_prompt.len > 0 {
					display_prompt := if client.system_prompt.len > 80 {
						utf8_safe_truncate(client.system_prompt, 80) + '...'
					} else {
						client.system_prompt
					}
					println('  system_prompt: ${display_prompt}')
				}
				println('  logging: ${client.logger.enabled}')
				println('  messages: ${client.messages.len}')
				println('  est. tokens: ~${client.estimate_tokens()}')
				println('')
				continue
			}
			'tools' {
				println('🔧 可用工具：')
				tools := get_available_tools()
				for tool in tools {
					println('  • ${tool.name} - ${tool.description}')
				}
				println('  AI工具调用: ${if client.enable_tools { '开启' } else { '关闭' }}')
				println('')
				continue
			}
			'tools on' {
				client.enable_tools = true
				println('✅ AI工具调用已开启 (AI可主动调用工具)')
				continue
			}
			'tools off' {
				client.enable_tools = false
				println('❌ AI工具调用已关闭')
				continue
			}
			'quota' {
				print_quota(client)
				continue
			}
			'mcp' {
				print_mcp_status(client)
				continue
			}
			'mcp start' {
				if client.mcp_manager.servers.len == 0 {
					init_mcp(mut client)
				} else {
					println('MCP 已在运行中')
				}
				continue
			}
			'mcp stop' {
				client.mcp_manager.stop_all()
				println('✅ MCP 服务已停止')
				continue
			}
			'skills' {
				print_skills_list()
				continue
			}
			'skills reload' {
				reload_skill_registry(client.workspace)
				println('✅ 技能已重新加载 (共 ${get_all_skills().len} 个)')
				continue
			}
			'experience', 'experiences' {
				println(experience_help_text())
				continue
			}
			'experience add' {
				println(experience_add_wizard())
				continue
			}
			'experience list', 'experiences list' {
				println(experience_list_text(''))
				continue
			}
			'commands', 'commands list' {
				println(list_custom_commands_text(client.workspace))
				println('')
				continue
			}
			'commands reload' {
				reload_command_registry(client.workspace)
				println('✅ 命令已重新加载')
				println('')
				continue
			}
			'extensions', 'extensions list' {
				println(list_extensions_text())
				println('')
				continue
			}
			'extensions show' {
				println('用法: extensions show <name>')
				println('')
				continue
			}
			'extensions uninstall' {
				println('用法: extensions uninstall <name>')
				println('')
				continue
			}
			'extensions update' {
				println(update_all_extensions())
				println('')
				continue
			}
			'notes' {
				result := session_note_read()
				if result.starts_with('[empty]') {
					println('📝 Session Notes: (空)')
				} else {
					println('📝 Session Notes:')
					println('─'.repeat(40))
					println(result)
					println('─'.repeat(40))
				}
				continue
			}
			'notes clear' {
				session_note_write('')
				println('✅ Session Notes 已清空')
				continue
			}
			'log' {
				if client.logger.enabled {
					println('📋 日志: \x1b[32m已开启\x1b[0m')
					println('  文件: ${client.logger.log_file}')
				} else {
					println('📋 日志: \x1b[31m已关闭\x1b[0m')
					println('  启用: --log 参数 或 config 中 enable_logging=true')
				}
				continue
			}
			'log on' {
				client.logger = new_logger(true)
				println('✅ 日志已开启: ${client.logger.log_file}')
				continue
			}
			'log off' {
				client.logger.enabled = false
				println('❌ 日志已关闭')
				continue
			}
			'trajectory' {
				if client.trajectory.enabled {
					println('📊 轨迹记录: \x1b[32m已开启\x1b[0m')
					println('  目录: ${client.trajectory.trajectory_dir}')
				} else {
					println('📊 轨迹记录: \x1b[31m已关闭\x1b[0m')
					println('  启用: --trajectory 参数')
				}
				continue
			}
			'trajectory on' {
				client.trajectory = new_trajectory_recorder(true)
				println('✅ 轨迹记录已开启: ${client.trajectory.trajectory_dir}')
				continue
			}
			'trajectory off' {
				client.trajectory.enabled = false
				println('❌ 轨迹记录已关闭')
				continue
			}
			'plan' {
				println('📋 Plan 模式: ${if client.plan_mode {
					'\x1b[32m已开启\x1b[0m'
				} else {
					'\x1b[31m已关闭\x1b[0m'
				}}')
				println('  AI会先制定计划，需确认后才执行操作')
				continue
			}
			'plan on' {
				client.plan_mode = true
				client.enable_tools = true
				println('✅ Plan 模式已开启 (AI会先制定计划再执行)')
				continue
			}
			'plan off' {
				client.plan_mode = false
				println('❌ Plan 模式已关闭 (AI直接执行)')
				continue
			}
			'checkpoint' {
				ensure_checkpoint_manager(client.workspace)
				result := checkpoint_mgr.create_checkpoint('')
				println(result)
				continue
			}
			'checkpoints' {
				ensure_checkpoint_manager(client.workspace)
				println(checkpoint_mgr.list_checkpoints())
				continue
			}
			'restore' {
				ensure_checkpoint_manager(client.workspace)
				result := checkpoint_mgr.restore_checkpoint(0)
				println(result)
				continue
			}
			'todos' {
				println(todo_list_items())
				continue
			}
			'todos clear' {
				println(todo_manager_tool('clear', '', 0, '', ''))
				continue
			}
			else {
				if trimmed.starts_with('checkpoint ') {
					ensure_checkpoint_manager(client.workspace)
					lbl := trimmed['checkpoint '.len..].trim_space()
					result := checkpoint_mgr.create_checkpoint(lbl)
					println(result)
					continue
				}
				if trimmed.starts_with('restore ') {
					ensure_checkpoint_manager(client.workspace)
					id_str := trimmed['restore '.len..].trim_space()
					result := checkpoint_mgr.restore_checkpoint(id_str.int())
					println(result)
					continue
				}
				if trimmed.starts_with('skill ') {
					sname := trimmed['skill '.len..].trim_space()
					if skill := find_skill(sname) {
						client.system_prompt = skill.prompt
						client.enable_tools = true
						skill_registry.active_skill = skill.name
						println('\x1b[35m🎯 已切换技能: ${skill.name} — ${skill.description} [${skill.source}]\x1b[0m')
					} else {
						println('⚠️  未知技能: ${sname}')
						print_skills_list()
					}
					continue
				}
				if trimmed.starts_with('skills create ') {
					sk_name := trimmed['skills create '.len..].trim_space()
					if sk_name.len > 0 {
						// Create in project .agents/skills/ by default
						target_dir := if client.workspace.len > 0 {
							os.join_path(client.workspace, '.agents', 'skills')
						} else {
							os.expand_tilde_to_home('~/.config/minimax/skills')
						}
						println(create_skill_template(sk_name, target_dir))
					} else {
						println('用法: skills create <name>')
					}
					continue
				}
				if trimmed.starts_with('skills sync ') {
					sync_target := trimmed['skills sync '.len..].trim_space()
					println(sync_skill_from_knowledge(sync_target))
					continue
				}
				if trimmed.starts_with('experience add ') {
					payload := trimmed['experience add '.len..].trim_space()
					println(record_experience_payload(payload))
					continue
				}
				if trimmed.starts_with('experience list ') {
					filter := trimmed['experience list '.len..].trim_space()
					println(experience_list_text(filter))
					continue
				}
				if trimmed.starts_with('experience show ') {
					id_text := trimmed['experience show '.len..].trim_space()
					println(experience_show_text(id_text))
					continue
				}
				if trimmed.starts_with('experience search ') {
					query := trimmed['experience search '.len..].trim_space()
					println(experience_search_text(query))
					continue
				}
				if trimmed.starts_with('experience prune ') {
					target := trimmed['experience prune '.len..].trim_space()
					println(experience_prune_text(target))
					continue
				}
				if trimmed.starts_with('commands show ') {
					cmd_name := trimmed['commands show '.len..].trim_space()
					println(show_custom_command_text(client.workspace, cmd_name))
					println('')
					continue
				}
				if trimmed.starts_with('extensions install ') {
					src := trimmed['extensions install '.len..].trim_space()
					println(install_extension_from_path(src))
					println('')
					continue
				}
				if trimmed.starts_with('extensions show ') {
					ext_name := trimmed['extensions show '.len..].trim_space()
					println(show_extension_text(ext_name))
					println('')
					continue
				}
				if trimmed.starts_with('extensions enable ') {
					ext_name := trimmed['extensions enable '.len..].trim_space()
					println(set_extension_enabled(ext_name, true))
					println('')
					continue
				}
				if trimmed.starts_with('extensions disable ') {
					ext_name := trimmed['extensions disable '.len..].trim_space()
					println(set_extension_enabled(ext_name, false))
					println('')
					continue
				}
				if trimmed.starts_with('extensions update ') {
					ext_name := trimmed['extensions update '.len..].trim_space()
					println(update_extension(ext_name))
					println('')
					continue
				}
				if trimmed.starts_with('extensions uninstall ') {
					ext_name := trimmed['extensions uninstall '.len..].trim_space()
					println(uninstall_extension(ext_name))
					println('')
					continue
				}
				if trimmed.starts_with('/') {
					response := execute_custom_command(mut client, trimmed, true) or {
						println('\x1b[31m❌ 命令执行失败: ${err}\x1b[0m')
						continue
					}
					if !client.use_streaming {
						println('\x1b[32mbot >\x1b[0m ${response}')
					}
					println('')
					continue
				}
				builtin_result := handle_builtin_command(trimmed)
				if builtin_result.len > 0 {
					println('tool > ${builtin_result}')
				} else if trimmed.starts_with('!') {
					// ! Shell shortcut: execute shell command directly
					shell_cmd := trimmed[1..].trim_space()
					if shell_cmd.len > 0 {
						println('\x1b[2m\$ ${shell_cmd}\x1b[0m')
						shell_result := bash_session.execute(shell_cmd)
						println(shell_result)
					}
				} else {
					// Expand @file references
					final_input := expand_file_references(trimmed, client.workspace)
					response := client.chat(final_input) or {
						println('\x1b[31m❌ 错误: ${err}\x1b[0m')
						client.logger.log_error('CHAT', err.str())
						continue
					}
					if !client.use_streaming {
						println('\x1b[32mbot >\x1b[0m ${response}')
					}
				}
				println('')
			}
		}
	}
}

// Headless mode: non-interactive single prompt execution
// Returns exit code: 0=success, 1=error, 42=input error
fn headless_mode(mut client ApiClient, prompt string, output_format string) int {
	if prompt.trim_space().len == 0 {
		if output_format == 'json' {
			println('{"error":"empty prompt","exit_code":42}')
		} else {
			eprintln('Error: empty prompt')
		}
		return 42
	}

	is_plain := output_format == 'plain'
	is_json := output_format == 'json'

	// Plain mode: suppress all decorations, only output the response
	if !is_plain && !is_json {
		println('\x1b[1;36m🤖 MiniMax CLI ${version}\x1b[0m — Headless')
		if client.enable_tools {
			println('\x1b[2m🔧 AI工具调用: 开启\x1b[0m')
		}
		println('\x1b[1;34m提问:\x1b[0m ${prompt}')
		println('')
	}

	builtin_result := handle_builtin_command(prompt)
	if builtin_result.len > 0 {
		if is_json {
			escaped := escape_json_string(builtin_result)
			println('{"response":"${escaped}","exit_code":0}')
		} else if is_plain {
			println(builtin_result)
		} else {
			println('\x1b[32m回答:\x1b[0m ${builtin_result}')
		}
		return 0
	}

	if prompt.trim_space().starts_with('/') {
		response := execute_custom_command(mut client, prompt.trim_space(), false) or {
			if is_json {
				escaped := escape_json_string(err.str())
				println('{"error":"${escaped}","exit_code":1}')
			} else if is_plain {
				eprintln('Error: ${err}')
			} else {
				println('\x1b[31m❌ 错误: ${err}\x1b[0m')
			}
			client.logger.log_error('COMMAND', err.str())
			return 1
		}
		if is_json {
			escaped := escape_json_string(response)
			println('{"response":"${escaped}","model":"${client.model}","messages":${client.messages.len},"exit_code":0}')
		} else if is_plain {
			println(response)
		} else if !client.use_streaming {
			println('\x1b[32m回答:\x1b[0m ${response}')
		}
		return 0
	}

	// Expand @file references in headless mode too
	final_prompt := expand_file_references(prompt, client.workspace)

	response := client.chat(final_prompt) or {
		if is_json {
			escaped := escape_json_string(err.str())
			println('{"error":"${escaped}","exit_code":1}')
		} else if is_plain {
			eprintln('Error: ${err}')
		} else {
			println('\x1b[31m❌ 错误: ${err}\x1b[0m')
		}
		client.logger.log_error('CHAT', err.str())
		return 1
	}

	if is_json {
		escaped := escape_json_string(response)
		println('{"response":"${escaped}","model":"${client.model}","messages":${client.messages.len},"exit_code":0}')
	} else if is_plain {
		println(response)
	} else {
		if !client.use_streaming {
			println('\x1b[32m回答:\x1b[0m ${response}')
		}
	}
	return 0
}

fn single_prompt_mode(mut client ApiClient, prompt string) {
	headless_mode(mut client, prompt, 'text')
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
		'  max_tokens=200000',
		'  enable_tools=true',
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
