module main

fn test_parse_mcp_config_npx_auto_inject_yes_flag() {
	content := '{"servers":{"playwright":{"type":"stdio","command":"npx","args":["@playwright/mcp@latest"]}}}'
	configs := parse_mcp_config(content)
	assert configs.len == 1
	assert configs[0].args.len == 2
	assert configs[0].args[0] == '-y'
	assert configs[0].args[1] == '@playwright/mcp@latest'
}

fn test_parse_mcp_config_npx_preserve_existing_yes_flag() {
	content := '{"servers":{"playwright":{"type":"stdio","command":"npx","args":["--yes","@playwright/mcp@latest"]}}}'
	configs := parse_mcp_config(content)
	assert configs.len == 1
	assert configs[0].args.len == 2
	assert configs[0].args[0] == '--yes'
	assert configs[0].args[1] == '@playwright/mcp@latest'
}

fn test_mcp_tool_timeout_ms_understand_image_uses_extended_timeout() {
	assert mcp_tool_timeout_ms('understand_image') == understand_image_timeout_ms
}

fn test_mcp_tool_timeout_ms_other_tools_use_default_timeout() {
	assert mcp_tool_timeout_ms('web_search') == default_mcp_request_timeout_ms
}

fn test_mcp_timeout_poll_attempts_rounds_up_small_timeouts() {
	assert mcp_timeout_poll_attempts(1) == 1
	assert mcp_timeout_poll_attempts(101) == 2
	assert mcp_timeout_poll_attempts(250) == 3
}

fn test_lazy_mcp_server_exposes_preset_tools_before_start() {
	dummy_tool := McpTool{
		name:        'demo_tool'
		description: 'Demo preset tool.'
		params:      []McpToolParam{}
		raw_schema:  '{"type":"object","properties":{"value":{"type":"string","description":"Value."}},"required":["value"]}'
	}
	second_tool := McpTool{
		name:        'second_tool'
		description: 'Second preset tool.'
		params:      []McpToolParam{}
		raw_schema:  '{"type":"object","properties":{"flag":{"type":"boolean","description":"Flag."}},"required":["flag"]}'
	}
	mut manager := new_mcp_manager()
	manager.add_lazy_server('Demo', 'uvx', ['demo-server'], {
		'MINIMAX_API_KEY': 'placeholder'
	}, [dummy_tool, second_tool])
	tools := manager.get_all_tools()
	assert tools.len == 2
	assert tools[0].name == 'demo_tool'
	assert tools[1].name == 'second_tool'
}

fn test_build_mcp_process_enables_process_group() {
	server := McpServer{
		command: 'uvx'
		args:    ['--native-tls', 'minimax-coding-plan-mcp', '-y']
		env:     {
			'MINIMAX_API_KEY': 'placeholder'
		}
	}
	proc := build_mcp_process(server, 'uvx')
	assert proc.use_pgroup
	assert proc.use_stdio_ctl
	assert proc.args == ['--native-tls', 'minimax-coding-plan-mcp', '-y']
}
