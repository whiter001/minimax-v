module main

import os

enum InteractiveLoopAction {
	not_handled
	continue_loop
	break_loop
}

fn handle_interactive_exact_command(mut client ApiClient, trimmed string) InteractiveLoopAction {
	match trimmed {
		'exit', 'quit' {
			println('👋 再见！')
			return .break_loop
		}
		'clear' {
			client.clear_messages()
			println('✨ 历史已清空')
			return .continue_loop
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
			return .continue_loop
		}
		'tools' {
			println('🔧 可用工具：')
			tools := get_available_tools()
			for tool in tools {
				println('  • ${tool.name} - ${tool.description}')
			}
			println('  AI工具调用: ${if client.enable_tools { '开启' } else { '关闭' }}')
			println('')
			return .continue_loop
		}
		'tools on' {
			client.enable_tools = true
			println('✅ AI工具调用已开启 (AI可主动调用工具)')
			return .continue_loop
		}
		'tools off' {
			client.enable_tools = false
			println('❌ AI工具调用已关闭')
			return .continue_loop
		}
		'quota' {
			print_quota(client)
			return .continue_loop
		}
		'mcp' {
			print_mcp_status(client)
			return .continue_loop
		}
		'mcp start' {
			if client.mcp_manager.servers.len == 0 {
				init_mcp(mut client)
			} else {
				println('MCP 已在运行中')
			}
			return .continue_loop
		}
		'mcp stop' {
			client.mcp_manager.stop_all()
			println('✅ MCP 服务已停止')
			return .continue_loop
		}
		'skills' {
			print_skills_list()
			return .continue_loop
		}
		'skills reload' {
			reload_skill_registry(client.workspace)
			println('✅ 技能已重新加载 (共 ${get_all_skills().len} 个)')
			return .continue_loop
		}
		'experience', 'experiences' {
			println(experience_help_text())
			return .continue_loop
		}
		'experience add' {
			println(experience_add_wizard())
			return .continue_loop
		}
		'experience list', 'experiences list' {
			println(experience_list_text(''))
			return .continue_loop
		}
		'commands', 'commands list' {
			println(list_custom_commands_text(client.workspace))
			println('')
			return .continue_loop
		}
		'commands reload' {
			reload_command_registry(client.workspace)
			println('✅ 命令已重新加载')
			println('')
			return .continue_loop
		}
		'extensions', 'extensions list' {
			println(list_extensions_text())
			println('')
			return .continue_loop
		}
		'extensions show' {
			println('用法: extensions show <name>')
			println('')
			return .continue_loop
		}
		'extensions uninstall' {
			println('用法: extensions uninstall <name>')
			println('')
			return .continue_loop
		}
		'extensions update' {
			println(update_all_extensions())
			println('')
			return .continue_loop
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
			return .continue_loop
		}
		'notes clear' {
			session_note_write('')
			println('✅ Session Notes 已清空')
			return .continue_loop
		}
		'log' {
			if client.logger.enabled {
				println('📋 日志: \x1b[32m已开启\x1b[0m')
				println('  文件: ${client.logger.log_file}')
			} else {
				println('📋 日志: \x1b[31m已关闭\x1b[0m')
				println('  启用: --log 参数 或 config 中 enable_logging=true')
			}
			return .continue_loop
		}
		'log on' {
			client.logger = new_logger(true)
			println('✅ 日志已开启: ${client.logger.log_file}')
			return .continue_loop
		}
		'log off' {
			client.logger.enabled = false
			println('❌ 日志已关闭')
			return .continue_loop
		}
		'trajectory' {
			if client.trajectory.enabled {
				println('📊 轨迹记录: \x1b[32m已开启\x1b[0m')
				println('  目录: ${client.trajectory.trajectory_dir}')
			} else {
				println('📊 轨迹记录: \x1b[31m已关闭\x1b[0m')
				println('  启用: --trajectory 参数')
			}
			return .continue_loop
		}
		'trajectory on' {
			client.trajectory = new_trajectory_recorder(true)
			println('✅ 轨迹记录已开启: ${client.trajectory.trajectory_dir}')
			return .continue_loop
		}
		'trajectory off' {
			client.trajectory.enabled = false
			println('❌ 轨迹记录已关闭')
			return .continue_loop
		}
		'plan' {
			println('📋 Plan 模式: ${if client.plan_mode {
				'\x1b[32m已开启\x1b[0m'
			} else {
				'\x1b[31m已关闭\x1b[0m'
			}}')
			println('  AI会先制定计划，需确认后才执行操作')
			return .continue_loop
		}
		'plan on' {
			client.plan_mode = true
			client.enable_tools = true
			println('✅ Plan 模式已开启 (AI会先制定计划再执行)')
			return .continue_loop
		}
		'plan off' {
			client.plan_mode = false
			println('❌ Plan 模式已关闭 (AI直接执行)')
			return .continue_loop
		}
		'checkpoint' {
			ensure_checkpoint_manager(client.workspace)
			result := checkpoint_mgr.create_checkpoint('')
			println(result)
			return .continue_loop
		}
		'checkpoints' {
			ensure_checkpoint_manager(client.workspace)
			println(checkpoint_mgr.list_checkpoints())
			return .continue_loop
		}
		'restore' {
			ensure_checkpoint_manager(client.workspace)
			result := checkpoint_mgr.restore_checkpoint(0)
			println(result)
			return .continue_loop
		}
		'todos' {
			println(todo_list_items())
			return .continue_loop
		}
		'todos clear' {
			println(todo_manager_tool('clear', '', 0, '', ''))
			return .continue_loop
		}
		else {
			return .not_handled
		}
	}
}

fn handle_interactive_prefixed_command(mut client ApiClient, trimmed string) InteractiveLoopAction {
	if trimmed.starts_with('checkpoint ') {
		ensure_checkpoint_manager(client.workspace)
		lbl := trimmed['checkpoint '.len..].trim_space()
		result := checkpoint_mgr.create_checkpoint(lbl)
		println(result)
		return .continue_loop
	}
	if trimmed.starts_with('restore ') {
		ensure_checkpoint_manager(client.workspace)
		id_str := trimmed['restore '.len..].trim_space()
		result := checkpoint_mgr.restore_checkpoint(id_str.int())
		println(result)
		return .continue_loop
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
		return .continue_loop
	}
	if trimmed.starts_with('skills create ') {
		sk_name := trimmed['skills create '.len..].trim_space()
		if sk_name.len > 0 {
			target_dir := if client.workspace.len > 0 {
				os.join_path(client.workspace, '.agents', 'skills')
			} else {
				os.expand_tilde_to_home('~/.config/minimax/skills')
			}
			println(create_skill_template(sk_name, target_dir))
		} else {
			println('用法: skills create <name>')
		}
		return .continue_loop
	}
	if trimmed.starts_with('skills sync ') {
		sync_target := trimmed['skills sync '.len..].trim_space()
		println(sync_skill_from_knowledge(sync_target))
		return .continue_loop
	}
	if trimmed.starts_with('experience add ') {
		payload := trimmed['experience add '.len..].trim_space()
		println(record_experience_payload(payload))
		return .continue_loop
	}
	if trimmed.starts_with('experience list ') {
		filter := trimmed['experience list '.len..].trim_space()
		println(experience_list_text(filter))
		return .continue_loop
	}
	if trimmed.starts_with('experience show ') {
		id_text := trimmed['experience show '.len..].trim_space()
		println(experience_show_text(id_text))
		return .continue_loop
	}
	if trimmed.starts_with('experience search ') {
		query := trimmed['experience search '.len..].trim_space()
		println(experience_search_text(query))
		return .continue_loop
	}
	if trimmed.starts_with('experience prune ') {
		target := trimmed['experience prune '.len..].trim_space()
		println(experience_prune_text(target))
		return .continue_loop
	}
	if trimmed.starts_with('commands show ') {
		cmd_name := trimmed['commands show '.len..].trim_space()
		println(show_custom_command_text(client.workspace, cmd_name))
		println('')
		return .continue_loop
	}
	if trimmed.starts_with('extensions install ') {
		src := trimmed['extensions install '.len..].trim_space()
		println(install_extension_from_path(src))
		println('')
		return .continue_loop
	}
	if trimmed.starts_with('extensions show ') {
		ext_name := trimmed['extensions show '.len..].trim_space()
		println(show_extension_text(ext_name))
		println('')
		return .continue_loop
	}
	if trimmed.starts_with('extensions enable ') {
		ext_name := trimmed['extensions enable '.len..].trim_space()
		println(set_extension_enabled(ext_name, true))
		println('')
		return .continue_loop
	}
	if trimmed.starts_with('extensions disable ') {
		ext_name := trimmed['extensions disable '.len..].trim_space()
		println(set_extension_enabled(ext_name, false))
		println('')
		return .continue_loop
	}
	if trimmed.starts_with('extensions update ') {
		ext_name := trimmed['extensions update '.len..].trim_space()
		println(update_extension(ext_name))
		println('')
		return .continue_loop
	}
	if trimmed.starts_with('extensions uninstall ') {
		ext_name := trimmed['extensions uninstall '.len..].trim_space()
		println(uninstall_extension(ext_name))
		println('')
		return .continue_loop
	}
	return .not_handled
}

fn handle_interactive_general_input(mut client ApiClient, trimmed string) {
	if trimmed.starts_with('/') {
		response := execute_custom_command(mut client, trimmed, true) or {
			println('\x1b[31m❌ 命令执行失败: ${err}\x1b[0m')
			println('')
			return
		}
		if !client.use_streaming {
			println('\x1b[32mbot >\x1b[0m ${response}')
		}
		println('')
		return
	}

	builtin_result := handle_builtin_command(trimmed)
	if builtin_result.len > 0 {
		println('tool > ${builtin_result}')
	} else if trimmed.starts_with('!') {
		shell_cmd := trimmed[1..].trim_space()
		if shell_cmd.len > 0 {
			println('\x1b[2m\$ ${shell_cmd}\x1b[0m')
			shell_result := bash_session.execute(shell_cmd)
			println(shell_result)
		}
	} else {
		final_input := expand_file_references(trimmed, client.workspace)
		response := client.chat(final_input) or {
			println('\x1b[31m❌ 错误: ${err}\x1b[0m')
			client.logger.log_error('CHAT', err.str())
			println('')
			return
		}
		if !client.use_streaming {
			println('\x1b[32mbot >\x1b[0m ${response}')
		}
	}
	println('')
}
