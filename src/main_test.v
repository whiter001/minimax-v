module main

fn test_strip_ansi_escape_sequences_removes_color_codes() {
	input := '\x1b[1;34myou >\x1b[0m '
	assert strip_ansi_escape_sequences(input) == 'you > '
}

fn test_strip_ansi_escape_sequences_keeps_plain_text() {
	assert strip_ansi_escape_sequences('你好, minimax') == '你好, minimax'
}

fn test_should_use_basic_interactive_input_for_macos() {
	assert should_use_basic_interactive_input('macos')
}

fn test_should_use_basic_interactive_input_for_windows() {
	assert should_use_basic_interactive_input('windows')
}

fn test_should_use_basic_interactive_input_for_linux() {
	assert !should_use_basic_interactive_input('linux')
}

fn test_delete_last_rune_empty() {
	assert delete_last_rune('') == ''
}

fn test_delete_last_rune_ascii() {
	assert delete_last_rune('hello') == 'hell'
}

fn test_delete_last_rune_chinese() {
	assert delete_last_rune('你好') == '你'
}

fn test_delete_last_rune_emoji() {
	assert delete_last_rune('A🙂') == 'A'
}

fn test_insert_rune_at_cursor_middle() {
	buffer, cursor := insert_rune_at_cursor('你好'.runes(), 1, '们'.runes()[0])
	assert buffer.string() == '你们好'
	assert cursor == 2
}

fn test_backspace_rune_at_cursor_middle() {
	buffer, cursor := backspace_rune_at_cursor('你们好'.runes(), 2)
	assert buffer.string() == '你好'
	assert cursor == 1
}

fn test_delete_rune_at_cursor_middle() {
	buffer, cursor := delete_rune_at_cursor('你们好'.runes(), 1)
	assert buffer.string() == '你好'
	assert cursor == 1
}

fn test_delete_rune_at_cursor_end_noop() {
	buffer, cursor := delete_rune_at_cursor('你好'.runes(), 2)
	assert buffer.string() == '你好'
	assert cursor == 2
}

fn test_build_help_text_mentions_term_ui() {
	help := build_help_text()
	assert help.contains('minimax_cli --term-ui')
	assert help.contains('--term-ui                      使用 term.ui 终端界面（交互模式）')
	assert help.contains('minimax_cli cron ...')
}

fn test_is_cron_cli_subcommand() {
	assert is_cron_cli_subcommand(['minimax_cli', 'cron', 'list'])
	assert !is_cron_cli_subcommand(['minimax_cli', '--mcp', '-p', 'hello'])
}

fn test_detect_prompt_mode_keeps_interactive_for_system_only() {
	prompt, is_interactive := detect_prompt_mode(['minimax_cli', '--system',
		'你是一个专业助手']) or { panic(err) }
	assert prompt == ''
	assert is_interactive
}

fn test_detect_prompt_mode_prefers_explicit_prompt_flag() {
	prompt, is_interactive := detect_prompt_mode(['minimax_cli', '--system', '系统提示词',
		'-p', '用户问题']) or { panic(err) }
	assert prompt == '用户问题'
	assert !is_interactive
}

fn test_detect_prompt_mode_skips_other_option_values() {
	prompt, is_interactive := detect_prompt_mode(['minimax_cli', '--model', 'MiniMax-M2.5',
		'--workspace', '/tmp/project']) or { panic(err) }
	assert prompt == ''
	assert is_interactive
}

fn test_apply_cli_boolean_flag_enables_streaming() {
	mut client := new_api_client(default_config())
	assert apply_cli_boolean_flag(mut client, '--stream')
	assert client.use_streaming
}

fn test_apply_cli_boolean_flag_enables_tools() {
	mut client := new_api_client(default_config())
	assert apply_cli_boolean_flag(mut client, '--enable-tools')
	assert client.enable_tools
}

fn test_apply_cli_boolean_flag_enables_desktop_control_and_tools() {
	mut client := new_api_client(default_config())
	assert apply_cli_boolean_flag(mut client, '--enable-desktop-control')
	assert client.enable_desktop_control
	assert client.enable_tools
}

fn test_apply_cli_boolean_flag_enables_screen_capture_and_tools() {
	mut client := new_api_client(default_config())
	assert apply_cli_boolean_flag(mut client, '--enable-screen-capture')
	assert client.enable_screen_capture
	assert client.enable_tools
}

fn test_apply_cli_boolean_flag_rejects_unknown_flag() {
	mut client := new_api_client(default_config())
	assert !apply_cli_boolean_flag(mut client, '--not-a-real-flag')
}

fn test_apply_cli_runtime_flag_enables_mcp_and_tools() {
	mut client := new_api_client(default_config())
	mut runtime_flags := CliRuntimeFlags{}
	assert apply_cli_runtime_flag(mut client, '--mcp', mut runtime_flags)
	assert runtime_flags.mcp_enabled
	assert client.enable_tools
	assert !runtime_flags.acp_mode
	assert !runtime_flags.interactive_set
	assert runtime_flags.is_interactive
}

fn test_apply_cli_runtime_flag_sets_acp_mode_non_interactive() {
	mut client := new_api_client(default_config())
	mut runtime_flags := CliRuntimeFlags{}
	assert apply_cli_runtime_flag(mut client, '--acp', mut runtime_flags)
	assert runtime_flags.acp_mode
	assert client.enable_tools
	assert runtime_flags.interactive_set
	assert !runtime_flags.is_interactive
	assert !runtime_flags.mcp_enabled
}

fn test_runtime_flags_do_not_override_prompt_mode_without_explicit_interactive_flag() {
	mut runtime_flags := CliRuntimeFlags{}
	mut is_interactive := false
	if runtime_flags.interactive_set {
		is_interactive = runtime_flags.is_interactive
	}
	assert !is_interactive
}

fn test_apply_cli_runtime_flag_sets_term_ui_interactive_override() {
	mut client := new_api_client(default_config())
	mut runtime_flags := CliRuntimeFlags{}
	assert apply_cli_runtime_flag(mut client, '--term-ui', mut runtime_flags)
	assert runtime_flags.term_ui_mode
	assert runtime_flags.interactive_set
	assert runtime_flags.is_interactive
}
