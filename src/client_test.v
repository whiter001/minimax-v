module main

import os

// ===== estimate_tokens =====

fn test_estimate_tokens_empty() {
	mut client := new_api_client(default_config())
	assert client.estimate_tokens() == 0
}

fn test_estimate_tokens_with_messages() {
	mut client := new_api_client(default_config())
	client.add_message('user', 'hello world') // 11 chars
	// 11 / 2.5 = 4.4 → 4
	assert client.estimate_tokens() == 4
}

fn test_estimate_tokens_with_system_prompt() {
	mut config := default_config()
	config.system_prompt = 'x'.repeat(250) // 250 chars → 100 tokens
	mut client := new_api_client(config)
	assert client.estimate_tokens() == 100
}

fn test_estimate_tokens_with_content_json() {
	mut client := new_api_client(default_config())
	client.messages << ChatMessage{
		role:         'assistant'
		content:      ''
		content_json: '{"type":"text","text":"hello"}'
	}
	est := client.estimate_tokens()
	// JSON is 29 chars, 29 / 2.5 ≈ 12
	assert est > 0 && est <= 15
}

// ===== add_message =====

fn test_add_message() {
	mut client := new_api_client(default_config())
	client.add_message('user', 'test')
	assert client.messages.len == 1
	assert client.messages[0].role == 'user'
	assert client.messages[0].content == 'test'
}

// ===== clear_messages =====

fn test_clear_messages() {
	mut client := new_api_client(default_config())
	client.add_message('user', 'test')
	client.add_message('assistant', 'reply')
	assert client.messages.len == 2
	client.clear_messages()
	assert client.messages.len == 0
}

// ===== build_request_json =====

fn test_build_request_json_basic() {
	mut config := default_config()
	config.api_key = 'test-key'
	mut client := new_api_client(config)
	client.add_message('user', 'hello')
	json := client.build_request_json()
	assert json.contains('"model":"MiniMax-M2.7"')
	assert json.contains('"max_tokens":102400')
	assert json.contains('"role":"user"')
	assert json.contains('"content":"hello"')
}

fn test_build_request_json_with_system_prompt() {
	mut config := default_config()
	config.api_key = 'test-key'
	config.system_prompt = 'Be helpful'
	mut client := new_api_client(config)
	client.add_message('user', 'hi')
	json := client.build_request_json()
	assert json.contains('"system":')
	assert json.contains('Be helpful')
}

fn test_build_request_json_with_streaming() {
	mut config := default_config()
	config.api_key = 'test-key'
	mut client := new_api_client(config)
	client.use_streaming = true
	client.add_message('user', 'test')
	json := client.build_request_json()
	assert json.contains('"stream":true')
}

fn test_build_request_json_with_tools() {
	mut config := default_config()
	config.api_key = 'test-key'
	config.enable_tools = true
	mut client := new_api_client(config)
	client.add_message('user', 'test')
	json := client.build_request_json()
	assert json.contains('"tools":')
	assert json.contains('"name":"read_file"')
	assert json.contains('call record_experience if you verified a stable fix')
}

fn test_build_request_json_with_lazy_mcp_tools() {
	mut config := default_config()
	config.api_key = 'test-key'
	config.enable_tools = true
	mut client := new_api_client(config)
	client.mcp_manager = new_mcp_manager()
	dummy_tool := McpTool{
		name:        'demo_tool'
		description: 'Demo preset tool.'
		params:      []McpToolParam{}
		raw_schema:  '{"type":"object","properties":{"value":{"type":"string","description":"Value."}},"required":["value"]}'
	}
	client.mcp_manager.add_lazy_server('Demo', 'uvx', ['demo-server'], {
		'MINIMAX_API_KEY': 'placeholder'
	}, [dummy_tool])
	client.add_message('user', 'test')
	json := client.build_request_json()
	assert json.contains('"name":"demo_tool"')
	assert json.contains('"description":"Demo preset tool."')
}

fn test_build_request_json_with_workspace() {
	mut config := default_config()
	config.api_key = 'test-key'
	config.workspace = '/tmp/project'
	mut client := new_api_client(config)
	client.add_message('user', 'test')
	json := client.build_request_json()
	assert json.contains('Working directory')
	assert json.contains('/tmp/project')
}

fn test_build_request_json_agent_prompt_injected() {
	mut config := default_config()
	config.api_key = 'test-key'
	config.enable_tools = true
	// No custom system prompt
	mut client := new_api_client(config)
	client.add_message('user', 'test')
	json := client.build_request_json()
	assert json.contains('helpful AI assistant')
}

fn test_build_request_json_custom_prompt_overrides_agent() {
	mut config := default_config()
	config.api_key = 'test-key'
	config.enable_tools = true
	config.system_prompt = 'Custom prompt'
	mut client := new_api_client(config)
	client.add_message('user', 'test')
	json := client.build_request_json()
	assert json.contains('Custom prompt')
	assert !json.contains('helpful AI assistant')
	assert json.contains('call record_experience if you verified a stable fix')
}

fn test_build_request_json_includes_browser_wait_guidance() {
	mut config := default_config()
	config.api_key = 'test-key'
	config.enable_tools = true
	mut client := new_api_client(config)
	client.add_message('user', 'test')
	json := client.build_request_json()
	assert json.contains('prefer explicit selectors, text, or URL/state checks')
	assert json.contains('avoid long')
	assert json.contains('networkidle')
}

fn test_build_request_json_content_json_message() {
	mut config := default_config()
	config.api_key = 'test-key'
	mut client := new_api_client(config)
	client.messages << ChatMessage{
		role:         'assistant'
		content:      ''
		content_json: '[{"type":"text","text":"hello"}]'
	}
	json := client.build_request_json()
	assert json.contains('"content":[{"type":"text","text":"hello"}]')
}

fn test_normalize_tool_uses_browser_wait_for_defaults_time() {
	mut tools := [
		ToolUse{
			id:    'tu_1'
			name:  'browser_wait_for'
			input: map[string]string{}
		},
	]
	changed := normalize_tool_uses(mut tools)
	assert changed
	assert tools[0].input['time'] == '1'
}

fn test_build_assistant_content_json_with_tool_use() {
	tools := [
		ToolUse{
			id:    'tu_1'
			name:  'browser_wait_for'
			input: {
				'time': '1'
			}
		},
	]
	json := build_assistant_content_json('hello', 'thinking', tools)
	assert json.contains('"type":"thinking"')
	assert json.contains('"type":"text"')
	assert json.contains('"type":"tool_use"')
	assert json.contains('"name":"browser_wait_for"')
	assert json.contains('"time":1')
}

fn test_build_parsed_response_from_stream_result_preserves_text_and_thinking() {
	sr := StreamResult{
		text:     'final text'
		thinking: 'deep thoughts'
		raw_body: ''
	}
	parsed := build_parsed_response_from_stream_result(sr)
	assert parsed.text == 'final text'
	assert parsed.thinking == 'deep thoughts'
	assert parsed.stop_reason == ''
}

fn test_store_assistant_response_with_tool_use_builds_content_json() {
	mut client := new_api_client(default_config())
	parsed := ParsedResponse{
		text:      'hello'
		thinking:  'thinking'
		tool_uses: [
			ToolUse{
				id:    'tu_1'
				name:  'browser_wait_for'
				input: {
					'time': '1'
				}
			},
		]
	}
	client.store_assistant_response(parsed)
	assert client.messages.len == 1
	assert client.messages[0].role == 'assistant'
	assert client.messages[0].content == 'hello'
	assert client.messages[0].content_json.contains('"type":"tool_use"')
}

fn test_store_assistant_response_plain_text_falls_back_to_content() {
	mut client := new_api_client(default_config())
	parsed := ParsedResponse{
		text:             'plain reply'
		raw_content_json: ''
	}
	client.store_assistant_response(parsed)
	assert client.messages.len == 1
	assert client.messages[0].content == 'plain reply'
	assert client.messages[0].content_json == ''
}

fn test_finalize_successful_round_updates_step_and_message() {
	mut client := new_api_client(default_config())
	mut step := AgentStep{}
	parsed := ParsedResponse{
		text:     'assistant reply'
		thinking: 'analysis'
	}
	client.finalize_successful_round(mut step, parsed)
	assert step.thought == 'assistant reply'
	assert step.thinking == 'analysis'
	assert client.messages.len == 1
	assert client.messages[0].content == 'assistant reply'
}

fn test_complete_task_done_updates_execution_and_messages() {
	mut client := new_api_client(default_config())
	mut step := AgentStep{
		step_number: 1
		state:       .calling_tool
		start_time:  1
	}
	mut execution := new_agent_execution('task')
	result := client.complete_task_done(mut step, mut execution, 'done summary', 0)
	assert result == 'done summary'
	assert step.state == .completed
	assert execution.success
	assert execution.agent_state == .completed
	assert execution.final_result == 'done summary'
	assert client.messages.len == 1
	assert client.messages[0].role == 'assistant'
	assert client.messages[0].content == 'done summary'
}

fn test_sanitize_messages_for_api_keeps_valid_tool_pair() {
	messages := [
		ChatMessage{
			role:         'assistant'
			content_json: '[{"type":"text","text":"reading"},{"type":"tool_use","id":"tu_1","name":"read_file","input":{"path":"a.txt"}}]'
		},
		ChatMessage{
			role:         'user'
			content_json: '[{"type":"tool_result","tool_use_id":"tu_1","content":"file content"}]'
		},
	]
	sanitized, changed := sanitize_messages_for_api(messages)
	assert !changed
	assert sanitized.len == 2
	assert sanitized[0].content_json.contains('"type":"tool_use"')
	assert sanitized[1].content_json.contains('"type":"tool_result"')
}

fn test_sanitize_messages_for_api_converts_orphan_tool_result() {
	messages := [
		ChatMessage{
			role:    'user'
			content: 'hello'
		},
		ChatMessage{
			role:         'user'
			content_json: '[{"type":"tool_result","tool_use_id":"tu_1","content":"file content"}]'
		},
	]
	sanitized, changed := sanitize_messages_for_api(messages)
	assert changed
	assert sanitized.len == 2
	assert sanitized[1].content_json.len == 0
	assert sanitized[1].content.contains('Historical tool result')
	assert sanitized[1].content.contains('file content')
}

fn test_sanitize_messages_for_api_converts_mismatched_tool_pair() {
	messages := [
		ChatMessage{
			role:         'assistant'
			content_json: '[{"type":"tool_use","id":"tu_1","name":"read_file","input":{"path":"a.txt"}}]'
		},
		ChatMessage{
			role:         'user'
			content_json: '[{"type":"tool_result","tool_use_id":"tu_2","content":"wrong file"}]'
		},
	]
	sanitized, changed := sanitize_messages_for_api(messages)
	assert changed
	assert sanitized.len == 2
	assert sanitized[0].content_json.len == 0
	assert sanitized[0].content.contains('Historical assistant')
		|| sanitized[0].content.contains('reading') == false
	assert sanitized[1].content_json.len == 0
	assert sanitized[1].content.contains('Historical tool result')
}

fn test_tool_pair_ids_match_requires_exact_id_set() {
	tool_use_msg := ChatMessage{
		role:         'assistant'
		content_json: '[{"type":"tool_use","id":"tu_1","name":"read_file","input":{"path":"a.txt"}},{"type":"tool_use","id":"tu_2","name":"list_dir","input":{"path":"."}}]'
	}
	matching_tool_result_msg := ChatMessage{
		role:         'user'
		content_json: '[{"type":"tool_result","tool_use_id":"tu_1","content":"ok"},{"type":"tool_result","tool_use_id":"tu_2","content":"ok"}]'
	}
	mismatched_tool_result_msg := ChatMessage{
		role:         'user'
		content_json: '[{"type":"tool_result","tool_use_id":"tu_1","content":"ok"}]'
	}
	assert tool_pair_ids_match(tool_use_msg, matching_tool_result_msg)
	assert !tool_pair_ids_match(tool_use_msg, mismatched_tool_result_msg)
}

fn test_adjust_summary_boundary_for_tool_pairs() {
	messages := [
		ChatMessage{
			role:    'user'
			content: 'older context'
		},
		ChatMessage{
			role:         'assistant'
			content_json: '[{"type":"tool_use","id":"tu_1","name":"read_file","input":{"path":"a.txt"}}]'
		},
		ChatMessage{
			role:         'user'
			content_json: '[{"type":"tool_result","tool_use_id":"tu_1","content":"file content"}]'
		},
		ChatMessage{
			role:    'assistant'
			content: 'done'
		},
		ChatMessage{
			role:    'user'
			content: 'next prompt'
		},
	]
	assert adjust_summary_boundary_for_tool_pairs(messages, 2) == 1
	assert adjust_summary_boundary_for_tool_pairs(messages, 3) == 3
}

fn test_normalize_tool_uses_playwright_defaults() {
	mut tools := [
		ToolUse{
			id:    'tu_1'
			name:  'browser_take_screenshot'
			input: map[string]string{}
		},
		ToolUse{
			id:    'tu_2'
			name:  'browser_console_messages'
			input: map[string]string{}
		},
		ToolUse{
			id:    'tu_3'
			name:  'browser_network_requests'
			input: map[string]string{}
		},
	]
	changed := normalize_tool_uses(mut tools)
	assert changed
	assert tools[0].input['type'] == 'png'
	assert tools[1].input['level'] == 'info'
	assert tools[2].input['includeStatic'] == 'false'
}

// ===== new_api_client =====

fn test_new_api_client() {
	mut config := default_config()
	config.api_key = 'sk-test'
	config.max_rounds = 50
	config.workspace = '/tmp'
	config.token_limit = 100000
	client := new_api_client(config)
	assert client.api_key == 'sk-test'
	assert client.max_rounds == 50
	assert client.workspace == '/tmp'
	assert client.token_limit == 100000
	assert client.messages.len == 0
}

fn test_normalize_tool_command_collapses_whitespace() {
	assert normalize_tool_command('  ls   -la\n /tmp  ') == 'ls -la /tmp'
}

fn test_tool_use_batch_signature_is_stable() {
	tools := [
		ToolUse{
			id:    'tu_1'
			name:  'bash'
			input: {
				'command': 'pwd'
				'restart': 'false'
			}
		},
	]
	assert tool_use_batch_signature(tools) == 'bash(command=pwd,restart=false)'
}

fn test_should_block_repeated_failed_bash_command() {
	tool := ToolUse{
		id:    'tu_1'
		name:  'bash'
		input: {
			'command': '  ls   missing-dir '
		}
	}
	assert !should_block_repeated_failed_bash_command(tool, 'ls missing-dir', 1)
	assert should_block_repeated_failed_bash_command(tool, 'ls missing-dir', 2)
}

fn test_extract_tool_command_head_handles_basic_cases() {
	assert extract_tool_command_head('bun -v') == 'bun'
	assert extract_tool_command_head('  "C:\\Program Files\\Git\\bin\\bash.exe" -lc "pwd"') == 'C:\\Program Files\\Git\\bin\\bash.exe'
}

fn test_summarize_path_entries_prefers_focus_terms() {
	summary := summarize_path_entries('C:\\Windows;C:\\Users\\white\\.bun\\bin;D:\\public', [
		'bun',
		'public',
	], 8)
	assert summary.contains('.bun\\bin')
	assert summary.contains('D:\\public')
	assert !summary.contains('C:\\Windows')
}

fn test_build_bash_tool_diagnostic_includes_command_context() {
	mut client := new_api_client(default_config())
	diag := build_bash_tool_diagnostic('bun -v', client.bash_session)
	assert diag.contains('command_head=bun')
	assert diag.contains('cwd=')
	assert diag.contains('bun_path=')
}

fn test_build_tool_error_results_json_marks_errors() {
	tools := [
		ToolUse{
			id:    'tu_1'
			name:  'read_file'
			input: {
				'path': 'a.txt'
			}
		},
	]
	json := build_tool_error_results_json(tools, 'stop now')
	assert json.contains('"is_error":true')
	assert json.contains('"tool_use_id":"tu_1"')
	assert json.contains('stop now')
}

// ===== build_request_json: skills metadata injection =====

fn test_build_request_json_skills_metadata_injected() {
	mut config := default_config()
	config.api_key = 'test-key'
	config.enable_tools = true
	mut client := new_api_client(config)
	client.add_message('user', 'test')
	json := client.build_request_json()
	// When tools are enabled, skills metadata should be injected
	assert json.contains('Available Skills')
	assert json.contains('activate_skill')
	assert json.contains('coder')
}

fn test_build_request_json_no_skills_without_tools() {
	mut config := default_config()
	config.api_key = 'test-key'
	config.enable_tools = false
	mut client := new_api_client(config)
	client.add_message('user', 'test')
	json := client.build_request_json()
	// Without tools, skills metadata should NOT be injected
	assert !json.contains('Available Skills')
}

// ===== build_request_json: plan mode =====

fn test_build_request_json_plan_mode() {
	mut config := default_config()
	config.api_key = 'test-key'
	config.enable_tools = true
	mut client := new_api_client(config)
	client.plan_mode = true
	client.add_message('user', 'test')
	json := client.build_request_json()
	assert json.contains('PLAN MODE')
	assert json.contains('sequentialthinking')
}

fn test_build_request_json_no_plan_mode() {
	mut config := default_config()
	config.api_key = 'test-key'
	mut client := new_api_client(config)
	client.plan_mode = false
	client.add_message('user', 'test')
	json := client.build_request_json()
	assert !json.contains('PLAN MODE')
}

// ===== build_request_json: tools schema contains activate_skill =====

fn test_build_request_json_activate_skill_in_tools() {
	mut config := default_config()
	config.api_key = 'test-key'
	config.enable_tools = true
	mut client := new_api_client(config)
	client.add_message('user', 'test')
	json := client.build_request_json()
	assert json.contains('"name":"activate_skill"')
}

fn test_build_request_json_auto_skills_adds_instruction() {
	mut config := default_config()
	config.api_key = 'test-key'
	config.enable_tools = true
	config.auto_skills = true
	mut client := new_api_client(config)
	client.add_message('user', '请帮我管理后台任务')
	json := client.build_request_json()
	assert json.contains('proactively call the activate_skill tool yourself')
	assert json.contains('call record_experience if you verified a stable fix')
}

fn test_build_request_json_auto_check_sops_adds_metadata_and_instruction() {
	tmp_root := os.join_path(os.temp_dir(), 'minimax_client_test_sops_${os.getpid()}')
	sop_dir := os.join_path(tmp_root, 'sops', 'wechat-mp-draft-publisher')
	os.mkdir_all(sop_dir) or { panic(err) }
	os.write_file(os.join_path(sop_dir, 'SOP.md'), '# SOP\n\n先检查草稿箱状态') or {
		panic(err)
	}
	os.setenv('MINIMAX_CONFIG_HOME', tmp_root, true)
	defer {
		os.unsetenv('MINIMAX_CONFIG_HOME')
		os.rmdir_all(tmp_root) or {}
	}
	mut config := default_config()
	config.api_key = 'test-key'
	config.enable_tools = true
	config.auto_check_sops = true
	mut client := new_api_client(config)
	client.add_message('user', '请帮我处理微信公众号草稿')
	json := client.build_request_json()
	assert json.contains('Available SOPs')
	assert json.contains('wechat-mp-draft-publisher')
	assert json.contains('proactively call the match_sop tool')
	assert json.contains('follow the suggested_read_order')
	assert json.contains('read the recommended SOP files with the read_file tool')
	assert json.contains('"name":"match_sop"')
}

fn test_build_request_json_includes_working_checkpoint() {
	tmp_root := os.join_path(os.temp_dir(), 'minimax-checkpoint-test')
	os.mkdir_all(tmp_root) or { panic(err) }
	os.setenv('MINIMAX_CONFIG_HOME', tmp_root, true)
	defer {
		os.unsetenv('MINIMAX_CONFIG_HOME')
		os.rmdir_all(tmp_root) or {}
	}
	checkpoint_path := get_working_checkpoint_path()
	os.write_file(checkpoint_path, serialize_working_checkpoint(WorkingCheckpoint{
		key_info:    'Remember constraints'
		related_sop: 'memory/plan_sop.md'
	})) or { panic(err) }
	mut config := default_config()
	config.api_key = 'test-key'
	config.enable_tools = true
	mut client := new_api_client(config)
	client.add_message('user', 'test')
	json := client.build_request_json()
	assert json.contains('Working checkpoint')
	assert json.contains('Remember constraints')
}
