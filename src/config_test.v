module main

import os

// ===== parse_config_content =====

fn test_parse_config_basic() {
	content := 'api_key=sk-test-123\nmodel=MiniMax-M2.7\ntemperature=0.5'
	config := parse_config_content(content, default_config())
	assert config.api_key == 'sk-test-123'
	assert config.model == 'MiniMax-M2.7'
	assert config.temperature == 0.5
}

fn test_parse_config_image_defaults() {
	content := 'image_model=image-01-live\nimage_api_url=https://api.minimaxi.com/v1/image_generation'
	config := parse_config_content(content, default_config())
	assert config.image_model == 'image-01-live'
	assert config.image_api_url == 'https://api.minimaxi.com/v1/image_generation'
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
	// Use a base config with enable_tools=false to test explicit override
	base_false := Config{
		enable_tools: false
	}
	config3 := parse_config_content(content3, base_false)
	assert config3.enable_tools == false
}

fn test_parse_config_auto_skills_enables_tools() {
	content := 'auto_skills=true'
	config := parse_config_content(content, default_config())
	assert config.auto_skills == true
	assert config.enable_tools == true
}

fn test_parse_config_experience_automation_fields() {
	content := 'auto_check_sops=false\nauto_write_skills=false\nauto_upgrade_sops=false\nknowledge_sync_mode=strict'
	config := parse_config_content(content, default_config())
	assert config.auto_check_sops == false
	assert config.auto_write_skills == false
	assert config.auto_upgrade_sops == false
	assert config.knowledge_sync_mode == 'strict'
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
	content := 'max_tokens=204800'
	config := parse_config_content(content, default_config())
	assert config.max_tokens == 204800
}

fn test_parse_config_max_tokens_out_of_range() {
	content := 'max_tokens=204801'
	config := parse_config_content(content, default_config())
	// Out of range — should keep default
	assert config.max_tokens == 102400
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

fn test_parse_config_smtp_fields() {
	content := 'smtp_server=smtp.example.com\nsmtp_port=2525\nsmtp_username=user@example.com\nsmtp_password=secret\nsmtp_from=sender@example.com'
	config := parse_config_content(content, default_config())
	assert config.smtp_server == 'smtp.example.com'
	assert config.smtp_port == 2525
	assert config.smtp_username == 'user@example.com'
	assert config.smtp_password == 'secret'
	assert config.smtp_from == 'sender@example.com'
}

fn test_parse_config_all_fields() {
	content := 'api_key=sk-all\napi_url=https://custom.api\nimage_api_url=https://image.api\nmodel=Custom-Model\nimage_model=image-01-live\ntemperature=1.0\nmax_tokens=5000\nsystem_prompt=Be helpful\nenable_tools=true\nauto_skills=true\nauto_check_sops=false\nauto_write_skills=false\nauto_upgrade_sops=false\nknowledge_sync_mode=concise\nenable_desktop_control=true\nenable_screen_capture=true\ndebug=true\nmax_rounds=100\ntoken_limit=50000\nworkspace=/tmp'
	config := parse_config_content(content, default_config())
	assert config.api_key == 'sk-all'
	assert config.api_url == 'https://custom.api'
	assert config.image_api_url == 'https://image.api'
	assert config.model == 'Custom-Model'
	assert config.image_model == 'image-01-live'
	assert config.temperature == 1.0
	assert config.max_tokens == 5000
	assert config.system_prompt == 'Be helpful'
	assert config.enable_tools == true
	assert config.auto_skills == true
	assert config.auto_check_sops == false
	assert config.auto_write_skills == false
	assert config.auto_upgrade_sops == false
	assert config.knowledge_sync_mode == 'concise'
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
	// Valid: 1.0 (recommended)
	config1 := parse_config_content('temperature=1.0', default_config())
	assert config1.temperature == 1.0

	// Invalid: 0.0 — outside range (0.0, 1.0]
	config0 := parse_config_content('temperature=0.0', default_config())
	assert config0.temperature == 0.7 // keeps default

	// Invalid: 3.0 — outside range, keeps default
	config3 := parse_config_content('temperature=3.0', default_config())
	assert config3.temperature == 0.7
}

// ===== default_config =====

fn test_default_config() {
	config := default_config()
	assert config.api_key == ''
	assert config.api_url == 'https://api.minimaxi.com/anthropic/v1/messages'
	assert config.image_api_url == 'https://api.minimaxi.com/v1/image_generation'
	assert config.model == 'MiniMax-M2.7'
	assert config.image_model == 'image-01'
	assert config.temperature == 0.7
	assert config.max_tokens == 102400
	assert config.max_rounds == 5000
	assert config.token_limit == 80000
	assert config.enable_tools == true
	assert config.auto_skills == true
	assert config.auto_check_sops == true
	assert config.auto_write_skills == true
	assert config.auto_upgrade_sops == true
	assert config.knowledge_sync_mode == 'balanced'
	assert config.enable_desktop_control == false
	assert config.enable_screen_capture == true
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
	apply_env_override(mut config, 'MINIMAX_MAX_TOKENS', '204800')
	apply_env_override(mut config, 'MINIMAX_IMAGE_API_URL', 'https://image.example/api')
	apply_env_override(mut config, 'MINIMAX_IMAGE_MODEL', 'image-01-live')
	apply_env_override(mut config, 'MINIMAX_ENABLE_LOGGING', 'true')
	apply_env_override(mut config, 'MINIMAX_DEBUG', '1')
	apply_env_override(mut config, 'MINIMAX_MAX_ROUNDS', '150')
	apply_env_override(mut config, 'MINIMAX_TOKEN_LIMIT', '120000')
	apply_env_override(mut config, 'MINIMAX_SYSTEM_PROMPT', 'Be concise')
	apply_env_override(mut config, 'MINIMAX_AUTO_SKILLS', '1')
	apply_env_override(mut config, 'MINIMAX_AUTO_CHECK_SOPS', '0')
	apply_env_override(mut config, 'MINIMAX_AUTO_WRITE_SKILLS', '0')
	apply_env_override(mut config, 'MINIMAX_AUTO_UPGRADE_SOPS', '0')
	apply_env_override(mut config, 'MINIMAX_KNOWLEDGE_SYNC_MODE', 'strict')
	apply_env_override(mut config, 'MINIMAX_WORKSPACE', '/tmp/ws')
	assert config.max_tokens == 204800
	assert config.image_api_url == 'https://image.example/api'
	assert config.image_model == 'image-01-live'
	assert config.enable_logging
	assert config.debug
	assert config.max_rounds == 150
	assert config.token_limit == 120000
	assert config.system_prompt == 'Be concise'
	assert config.auto_skills
	assert !config.auto_check_sops
	assert !config.auto_write_skills
	assert !config.auto_upgrade_sops
	assert config.knowledge_sync_mode == 'strict'
	assert config.enable_tools
	assert config.workspace == '/tmp/ws'
}

fn test_apply_env_override_rejects_invalid_numeric_values() {
	mut config := default_config()
	apply_env_override(mut config, 'MINIMAX_MAX_TOKENS', '1000001')
	apply_env_override(mut config, 'MINIMAX_MAX_ROUNDS', '5001')
	apply_env_override(mut config, 'MINIMAX_TOKEN_LIMIT', '0')
	apply_env_override(mut config, 'MINIMAX_TEMPERATURE', '3.0')
	assert config.max_tokens == 102400
	assert config.max_rounds == 5000
	assert config.token_limit == 80000
	assert config.temperature == 0.7
}

fn test_apply_env_override_accepts_max_rounds_upper_bound() {
	mut config := default_config()
	apply_env_override(mut config, 'MINIMAX_MAX_ROUNDS', '5000')
	assert config.max_rounds == 5000
}

fn test_apply_env_override_supports_smtp_fields() {
	mut config := default_config()
	apply_env_override(mut config, 'MINIMAX_SMTP_SERVER', 'smtp.example.com')
	apply_env_override(mut config, 'MINIMAX_SMTP_PORT', '465')
	apply_env_override(mut config, 'MINIMAX_SMTP_USERNAME', 'user@example.com')
	apply_env_override(mut config, 'MINIMAX_SMTP_PASSWORD', 'secret')
	apply_env_override(mut config, 'MINIMAX_SMTP_FROM', 'sender@example.com')
	assert config.smtp_server == 'smtp.example.com'
	assert config.smtp_port == 465
	assert config.smtp_username == 'user@example.com'
	assert config.smtp_password == 'secret'
	assert config.smtp_from == 'sender@example.com'
}
