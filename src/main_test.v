module main

import os

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
	assert help.contains('--auto-skills')
	assert help.contains('auto_check_sops=true')
	assert help.contains('--term-ui                      使用 term.ui 终端界面（交互模式）')
	assert help.contains('minimax_cli cron ...')
}

fn test_is_headless_plain_output() {
	assert is_headless_plain_output('plain')
	assert !is_headless_plain_output('json')
	assert !is_headless_plain_output('text')
}

fn test_is_headless_json_output() {
	assert is_headless_json_output('json')
	assert !is_headless_json_output('plain')
	assert !is_headless_json_output('text')
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
	prompt, is_interactive := detect_prompt_mode(['minimax_cli', '--model', 'MiniMax-M2.7',
		'--workspace', '/tmp/project']) or { panic(err) }
	assert prompt == ''
	assert is_interactive
}

fn test_detect_prompt_mode_interactive_prompt_is_interactive() {
	prompt, is_interactive := detect_prompt_mode(['minimax_cli', '-i', '1+1=?']) or { panic(err) }
	assert prompt == '1+1=?'
	assert is_interactive
}

fn test_runtime_scan_does_not_demote_interactive_when_i_has_prompt() {
	mut args := ['minimax_cli', '-i', '1+1=?']
	mut prompt := ''
	mut is_interactive := true
	prompt, is_interactive = detect_prompt_mode(args) or { panic(err) }
	mut k := 1
	for k < args.len {
		arg := args[k]
		match arg {
			'-p', '--prompt' {
				if k + 1 < args.len {
					k++
				}
			}
			'-i', '--prompt-interactive' {
				if k + 1 < args.len && !args[k + 1].starts_with('-') {
					k++
				}
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
	assert prompt == '1+1=?'
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

fn test_apply_cli_boolean_flag_enables_auto_skills_and_workspace() {
	mut client := new_api_client(default_config())
	assert apply_cli_boolean_flag(mut client, '--auto-skills')
	assert client.auto_skills
	assert client.enable_tools
	assert client.workspace == os.getwd()
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

fn test_handle_interactive_exact_command_exit_breaks_loop() {
	mut client := new_api_client(default_config())
	action := handle_interactive_exact_command(mut client, 'exit')
	assert action == .break_loop
}

fn test_handle_interactive_exact_command_clear_empties_history() {
	mut client := new_api_client(default_config())
	client.add_message('user', 'hello')
	client.add_message('assistant', 'world')
	action := handle_interactive_exact_command(mut client, 'clear')
	assert action == .continue_loop
	assert client.messages.len == 0
}

fn test_handle_interactive_exact_command_tools_toggle() {
	mut client := new_api_client(default_config())
	client.enable_tools = false
	action_on := handle_interactive_exact_command(mut client, 'tools on')
	assert action_on == .continue_loop
	assert client.enable_tools
	action_off := handle_interactive_exact_command(mut client, 'tools off')
	assert action_off == .continue_loop
	assert !client.enable_tools
}

fn test_handle_interactive_exact_command_plan_toggle() {
	mut client := new_api_client(default_config())
	client.enable_tools = false
	client.plan_mode = false
	action_on := handle_interactive_exact_command(mut client, 'plan on')
	assert action_on == .continue_loop
	assert client.plan_mode
	assert client.enable_tools
	action_off := handle_interactive_exact_command(mut client, 'plan off')
	assert action_off == .continue_loop
	assert !client.plan_mode
}

fn test_handle_interactive_exact_command_log_toggle() {
	mut client := new_api_client(default_config())
	client.logger.enabled = false
	action_on := handle_interactive_exact_command(mut client, 'log on')
	assert action_on == .continue_loop
	assert client.logger.enabled
	action_off := handle_interactive_exact_command(mut client, 'log off')
	assert action_off == .continue_loop
	assert !client.logger.enabled
}

fn test_handle_interactive_exact_command_trajectory_toggle() {
	mut client := new_api_client(default_config())
	client.trajectory.enabled = false
	action_on := handle_interactive_exact_command(mut client, 'trajectory on')
	assert action_on == .continue_loop
	assert client.trajectory.enabled
	action_off := handle_interactive_exact_command(mut client, 'trajectory off')
	assert action_off == .continue_loop
	assert !client.trajectory.enabled
}

fn test_handle_interactive_exact_command_unknown_is_not_handled() {
	mut client := new_api_client(default_config())
	action := handle_interactive_exact_command(mut client, 'definitely-not-a-command')
	assert action == .not_handled
}

fn test_init_mcp_builtin_is_idempotent() {
	mut client := new_api_client(default_config())
	init_mcp_builtin(mut client)
	first_server_count := client.mcp_manager.servers.len
	first_tool_count := client.mcp_manager.get_all_tools().len

	init_mcp_builtin(mut client)
	assert client.mcp_manager.servers.len == first_server_count
	assert client.mcp_manager.get_all_tools().len == first_tool_count
	assert first_server_count == 1
	assert first_tool_count == 2
}

fn test_mcp_start_does_not_load_external_mcp_config() {
	mut client := new_api_client(default_config())
	config_home := os.join_path(os.temp_dir(), 'minimax-mcp-start-regression')
	os.mkdir_all(config_home) or { panic(err) }
	old_config_home := os.getenv('MINIMAX_CONFIG_HOME')
	os.setenv('MINIMAX_CONFIG_HOME', config_home, true)
	defer {
		if old_config_home.len > 0 {
			os.setenv('MINIMAX_CONFIG_HOME', old_config_home, true)
		} else {
			os.unsetenv('MINIMAX_CONFIG_HOME')
		}
	}

	mcp_json := '{"servers":{"external":{"type":"stdio","command":"definitely-not-a-real-command","args":[]}}}'
	os.write_file(os.join_path(config_home, 'mcp.json'), mcp_json) or { panic(err) }

	init_mcp_builtin(mut client)
	action := handle_interactive_exact_command(mut client, 'mcp start')
	assert action == .continue_loop
	assert client.mcp_manager.servers.len == 1
	assert client.mcp_manager.servers[0].name == 'MiniMax'
	client.mcp_manager.stop_all()
}

fn test_handle_interactive_prefixed_command_skill_switches_prompt() {
	workspace := os.join_path(os.temp_dir(), '__minimax_skill_switch__')
	os.rmdir_all(workspace) or {}
	os.mkdir_all(os.join_path(workspace, '.agents', 'skills', 'test-skill')) or {}
	os.write_file(os.join_path(workspace, '.agents', 'skills', 'test-skill', 'SKILL.md'),
		'---\nname: test-skill\ndescription: test description\n---\n\nfollow the test prompt') or {
		assert false
		return
	}
	defer { os.rmdir_all(workspace) or {} }
	mut config := default_config()
	config.workspace = workspace
	mut client := new_api_client(config)
	client.enable_tools = false
	action := handle_interactive_prefixed_command(mut client, 'skill test-skill')
	assert action == .continue_loop
	assert client.system_prompt == 'follow the test prompt'
	assert client.enable_tools
	assert client.current_skill == 'test-skill'
}

fn test_handle_interactive_prefixed_command_unknown_is_not_handled() {
	mut client := new_api_client(default_config())
	action := handle_interactive_prefixed_command(mut client, 'totally unknown prefix')
	assert action == .not_handled
}
