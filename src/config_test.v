module main

import os

// ===== parse_config_content =====

fn test_parse_config_basic() {
	content := 'api_key=sk-test-123\nmodel=MiniMax-M2.5\ntemperature=0.5'
	config := parse_config_content(content, default_config())
	assert config.api_key == 'sk-test-123'
	assert config.model == 'MiniMax-M2.5'
	assert config.temperature == 0.5
}

fn test_parse_config_with_quotes() {
	content := 'api_key="sk-test-456"'
	config := parse_config_content(content, default_config())
	assert config.api_key == 'sk-test-456'
}

fn test_parse_config_comments_and_empty() {
	content := '# This is a comment\n\napi_key=sk-test\n# Another comment'
	config := parse_config_content(content, default_config())
	assert config.api_key == 'sk-test'
}

fn test_parse_config_enable_tools() {
	content := 'enable_tools=true'
	config := parse_config_content(content, default_config())
	assert config.enable_tools == true

	content2 := 'enable_tools=1'
	config2 := parse_config_content(content2, default_config())
	assert config2.enable_tools == true

	content3 := 'enable_tools=false'
	config3 := parse_config_content(content3, default_config())
	assert config3.enable_tools == false
}

fn test_parse_config_desktop_flags() {
	content := 'enable_desktop_control=true\nenable_screen_capture=1'
	config := parse_config_content(content, default_config())
	assert config.enable_desktop_control == true
	assert config.enable_screen_capture == true
}

fn test_parse_config_debug() {
	content := 'debug=true'
	config := parse_config_content(content, default_config())
	assert config.debug == true
}

fn test_parse_config_max_tokens() {
	content := 'max_tokens=4096'
	config := parse_config_content(content, default_config())
	assert config.max_tokens == 4096
}

fn test_parse_config_max_tokens_upper_bound() {
	content := 'max_tokens=1000000'
	config := parse_config_content(content, default_config())
	assert config.max_tokens == 1000000
}

fn test_parse_config_max_tokens_out_of_range() {
	content := 'max_tokens=1000001'
	config := parse_config_content(content, default_config())
	// Out of range — should keep default
	assert config.max_tokens == 200000
}

fn test_parse_config_max_rounds() {
	content := 'max_rounds=50'
	config := parse_config_content(content, default_config())
	assert config.max_rounds == 50
}

fn test_parse_config_max_rounds_out_of_range() {
	content := 'max_rounds=5001'
	config := parse_config_content(content, default_config())
	assert config.max_rounds == 5000 // default
}

fn test_parse_config_max_rounds_upper_bound() {
	content := 'max_rounds=5000'
	config := parse_config_content(content, default_config())
	assert config.max_rounds == 5000
}

fn test_parse_config_token_limit() {
	content := 'token_limit=100000'
	config := parse_config_content(content, default_config())
	assert config.token_limit == 100000
}

fn test_parse_config_workspace() {
	content := 'workspace=/home/user/project'
	config := parse_config_content(content, default_config())
	assert config.workspace == '/home/user/project'
}

fn test_parse_config_all_fields() {
	content := 'api_key=sk-all\napi_url=https://custom.api\nmodel=Custom-Model\ntemperature=1.0\nmax_tokens=5000\nsystem_prompt=Be helpful\nenable_tools=true\nenable_desktop_control=true\nenable_screen_capture=true\ndebug=true\nmax_rounds=100\ntoken_limit=50000\nworkspace=/tmp'
	config := parse_config_content(content, default_config())
	assert config.api_key == 'sk-all'
	assert config.api_url == 'https://custom.api'
	assert config.model == 'Custom-Model'
	assert config.temperature == 1.0
	assert config.max_tokens == 5000
	assert config.system_prompt == 'Be helpful'
	assert config.enable_tools == true
	assert config.enable_desktop_control == true
	assert config.enable_screen_capture == true
	assert config.debug == true
	assert config.max_rounds == 100
	assert config.token_limit == 50000
	assert config.workspace == '/tmp'
}

fn test_parse_config_unknown_keys_ignored() {
	content := 'api_key=sk-test\nunknown_key=some_value\nfoo=bar'
	config := parse_config_content(content, default_config())
	assert config.api_key == 'sk-test'
	// No crash, unknown keys silently ignored
}

fn test_parse_config_temperature_boundaries() {
	// Valid: 0.0
	config0 := parse_config_content('temperature=0.0', default_config())
	assert config0.temperature == 0.0

	// Valid: 2.0
	config2 := parse_config_content('temperature=2.0', default_config())
	assert config2.temperature == 2.0

	// Invalid: 3.0 — keep default
	config3 := parse_config_content('temperature=3.0', default_config())
	assert config3.temperature == 0.7
}

// ===== default_config =====

fn test_default_config() {
	config := default_config()
	assert config.api_key == ''
	assert config.api_url == 'https://api.minimaxi.com/anthropic/v1/messages'
	assert config.model == 'MiniMax-M2.5'
	assert config.temperature == 0.7
	assert config.max_tokens == 200000
	assert config.max_rounds == 5000
	assert config.token_limit == 80000
	assert config.enable_tools == false
	assert config.enable_desktop_control == false
	assert config.enable_screen_capture == false
	assert config.debug == false
	assert config.workspace == ''
}

fn test_expand_home_path_expands_tilde_to_home_dir() {
	expanded := expand_home_path('~/.config/minimax')
	expected := os.join_path(get_user_home_dir(), '.config', 'minimax')
	assert expanded == expected
	assert !expanded.starts_with('~')
}

fn test_expand_home_path_supports_bare_tilde() {
	assert expand_home_path('~') == get_user_home_dir()
}

fn test_get_minimax_config_dir_uses_minimax_config_home_override() {
	os.setenv('MINIMAX_CONFIG_HOME', 'D:\\custom\\minimax', true)
	defer {
		os.unsetenv('MINIMAX_CONFIG_HOME')
	}
	assert get_minimax_config_dir() == 'D:\\custom\\minimax'
}

fn test_apply_env_override_supports_advanced_fields() {
	mut config := default_config()
	apply_env_override(mut config, 'MINIMAX_MAX_TOKENS', '1000000')
	apply_env_override(mut config, 'MINIMAX_ENABLE_LOGGING', 'true')
	apply_env_override(mut config, 'MINIMAX_DEBUG', '1')
	apply_env_override(mut config, 'MINIMAX_MAX_ROUNDS', '150')
	apply_env_override(mut config, 'MINIMAX_TOKEN_LIMIT', '120000')
	apply_env_override(mut config, 'MINIMAX_SYSTEM_PROMPT', 'Be concise')
	apply_env_override(mut config, 'MINIMAX_WORKSPACE', '/tmp/ws')
	assert config.max_tokens == 1000000
	assert config.enable_logging
	assert config.debug
	assert config.max_rounds == 150
	assert config.token_limit == 120000
	assert config.system_prompt == 'Be concise'
	assert config.workspace == '/tmp/ws'
}

fn test_apply_env_override_rejects_invalid_numeric_values() {
	mut config := default_config()
	apply_env_override(mut config, 'MINIMAX_MAX_TOKENS', '1000001')
	apply_env_override(mut config, 'MINIMAX_MAX_ROUNDS', '5001')
	apply_env_override(mut config, 'MINIMAX_TOKEN_LIMIT', '0')
	apply_env_override(mut config, 'MINIMAX_TEMPERATURE', '3.0')
	assert config.max_tokens == 200000
	assert config.max_rounds == 5000
	assert config.token_limit == 80000
	assert config.temperature == 0.7
}

fn test_apply_env_override_accepts_max_rounds_upper_bound() {
	mut config := default_config()
	apply_env_override(mut config, 'MINIMAX_MAX_ROUNDS', '5000')
	assert config.max_rounds == 5000
}
