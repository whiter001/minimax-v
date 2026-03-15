module main

import os
import strconv

const max_response_tokens = 1000000

fn is_valid_max_rounds(rounds int) bool {
	return rounds > 0 && rounds <= max_tool_call_rounds
}

fn is_valid_max_tokens(tokens int) bool {
	return tokens > 0 && tokens <= max_response_tokens
}

pub struct Config {
pub mut:
	api_key                string
	api_url                string
	model                  string
	temperature            f64
	max_tokens             i32
	max_rounds             int
	token_limit            int
	system_prompt          string
	enable_tools           bool
	auto_skills            bool
	enable_desktop_control bool
	enable_screen_capture  bool
	enable_logging         bool
	debug                  bool
	workspace              string
}

fn default_config() Config {
	return Config{
		api_key:                ''
		api_url:                'https://api.minimaxi.com/anthropic/v1/messages'
		model:                  'MiniMax-M2.5'
		temperature:            0.7
		max_tokens:             102400
		max_rounds:             5000
		token_limit:            80000
		system_prompt:          ''
		enable_tools:           false
		auto_skills:            false
		enable_desktop_control: false
		enable_screen_capture:  false
		enable_logging:         false
		debug:                  false
		workspace:              ''
	}
}

fn get_user_home_dir() string {
	if home := os.getenv_opt('HOME') {
		trimmed := home.trim_space()
		if trimmed.len > 0 {
			return trimmed
		}
	}
	return os.home_dir()
}

// Cross-platform home directory path expansion
fn expand_home_path(path string) string {
	if !path.starts_with('~') {
		return path
	}
	home := get_user_home_dir()
	suffix := path[1..].trim_left('\\/ ')
	if suffix.len == 0 {
		return home
	}
	return os.join_path(home, suffix)
}

fn expand_config_path(path string) string {
	return expand_home_path(path)
}

fn load_config_file() Config {
	mut config := default_config()

	// Try primary config path: ~/.config/minimax/config
	config_path := os.join_path(get_minimax_config_dir(), 'config')
	if os.exists(config_path) {
		if content := os.read_file(config_path) {
			return parse_config_content(content, config)
		}
	}

	// Fallback: try legacy path ~/.minimax_config
	legacy_path := os.join_path(get_user_home_dir(), '.minimax_config')
	if os.exists(legacy_path) {
		if content := os.read_file(legacy_path) {
			return parse_config_content(content, config)
		}
	}

	// No config file found, return default (env vars will override)
	return config
}

fn parse_config_content(content string, base Config) Config {
	mut config := base
	lines := content.split('\n')
	for line in lines {
		trimmed := line.trim_space()
		if trimmed.starts_with('#') || trimmed.len == 0 {
			continue
		}

		if trimmed.contains('=') {
			eq_idx := trimmed.index('=') or { continue }
			key := trimmed[..eq_idx].trim_space()
			val := trimmed[eq_idx + 1..].trim_space().replace('"', '')
			if key.len == 0 {
				continue
			}

			match key {
				'api_key' {
					config.api_key = val
				}
				'api_url' {
					config.api_url = val
				}
				'model' {
					config.model = val
				}
				'temperature' {
					if temp := strconv.atof64(val) {
						if temp >= 0.0 && temp <= 2.0 {
							config.temperature = temp
						}
					}
				}
				'max_tokens' {
					if tokens := strconv.atoi(val) {
						if is_valid_max_tokens(tokens) {
							config.max_tokens = i32(tokens)
						}
					}
				}
				'system_prompt' {
					config.system_prompt = val
				}
				'enable_tools' {
					config.enable_tools = val == 'true' || val == '1'
				}
				'auto_skills' {
					config.auto_skills = val == 'true' || val == '1'
					if config.auto_skills {
						config.enable_tools = true
					}
				}
				'enable_desktop_control' {
					config.enable_desktop_control = val == 'true' || val == '1'
				}
				'enable_screen_capture' {
					config.enable_screen_capture = val == 'true' || val == '1'
				}
				'enable_logging' {
					config.enable_logging = val == 'true' || val == '1'
				}
				'debug' {
					config.debug = val == 'true' || val == '1'
				}
				'max_rounds' {
					if rounds := strconv.atoi(val) {
						if is_valid_max_rounds(rounds) {
							config.max_rounds = rounds
						}
					}
				}
				'workspace' {
					config.workspace = val
				}
				'token_limit' {
					if limit := strconv.atoi(val) {
						if limit > 0 && limit <= 200000 {
							config.token_limit = limit
						}
					}
				}
				else {}
			}
		}
	}
	if config.auto_skills {
		config.enable_tools = true
	}

	return config
}

fn apply_env_overrides(mut config Config) {
	if key := os.getenv_opt('MINIMAX_API_KEY') {
		apply_env_override(mut config, 'MINIMAX_API_KEY', key)
	}
	if url := os.getenv_opt('MINIMAX_API_URL') {
		apply_env_override(mut config, 'MINIMAX_API_URL', url)
	}
	if key := os.getenv_opt('MINIMAX_MODEL') {
		apply_env_override(mut config, 'MINIMAX_MODEL', key)
	}
	if temp := os.getenv_opt('MINIMAX_TEMPERATURE') {
		apply_env_override(mut config, 'MINIMAX_TEMPERATURE', temp)
	}
	if tokens := os.getenv_opt('MINIMAX_MAX_TOKENS') {
		apply_env_override(mut config, 'MINIMAX_MAX_TOKENS', tokens)
	}
	if val := os.getenv_opt('MINIMAX_ENABLE_TOOLS') {
		apply_env_override(mut config, 'MINIMAX_ENABLE_TOOLS', val)
	}
	if val := os.getenv_opt('MINIMAX_ENABLE_DESKTOP_CONTROL') {
		apply_env_override(mut config, 'MINIMAX_ENABLE_DESKTOP_CONTROL', val)
	}
	if val := os.getenv_opt('MINIMAX_ENABLE_SCREEN_CAPTURE') {
		apply_env_override(mut config, 'MINIMAX_ENABLE_SCREEN_CAPTURE', val)
	}
	if val := os.getenv_opt('MINIMAX_ENABLE_LOGGING') {
		apply_env_override(mut config, 'MINIMAX_ENABLE_LOGGING', val)
	}
	if val := os.getenv_opt('MINIMAX_DEBUG') {
		apply_env_override(mut config, 'MINIMAX_DEBUG', val)
	}
	if val := os.getenv_opt('MINIMAX_MAX_ROUNDS') {
		apply_env_override(mut config, 'MINIMAX_MAX_ROUNDS', val)
	}
	if val := os.getenv_opt('MINIMAX_TOKEN_LIMIT') {
		apply_env_override(mut config, 'MINIMAX_TOKEN_LIMIT', val)
	}
	if val := os.getenv_opt('MINIMAX_SYSTEM_PROMPT') {
		apply_env_override(mut config, 'MINIMAX_SYSTEM_PROMPT', val)
	}
	if val := os.getenv_opt('MINIMAX_AUTO_SKILLS') {
		apply_env_override(mut config, 'MINIMAX_AUTO_SKILLS', val)
	}
	if val := os.getenv_opt('MINIMAX_WORKSPACE') {
		apply_env_override(mut config, 'MINIMAX_WORKSPACE', val)
	}
	if config.auto_skills {
		config.enable_tools = true
	}
}

fn apply_env_override(mut config Config, key string, value string) {
	match key {
		'MINIMAX_API_KEY' {
			config.api_key = value
		}
		'MINIMAX_API_URL' {
			config.api_url = value
		}
		'MINIMAX_MODEL' {
			config.model = value
		}
		'MINIMAX_TEMPERATURE' {
			if parsed := strconv.atof64(value) {
				if parsed >= 0.0 && parsed <= 2.0 {
					config.temperature = parsed
				}
			}
		}
		'MINIMAX_MAX_TOKENS' {
			if parsed := strconv.atoi(value) {
				if is_valid_max_tokens(parsed) {
					config.max_tokens = i32(parsed)
				}
			}
		}
		'MINIMAX_ENABLE_TOOLS' {
			config.enable_tools = value == 'true' || value == '1'
		}
		'MINIMAX_AUTO_SKILLS' {
			config.auto_skills = value == 'true' || value == '1'
			if config.auto_skills {
				config.enable_tools = true
			}
		}
		'MINIMAX_ENABLE_DESKTOP_CONTROL' {
			config.enable_desktop_control = value == 'true' || value == '1'
		}
		'MINIMAX_ENABLE_SCREEN_CAPTURE' {
			config.enable_screen_capture = value == 'true' || value == '1'
		}
		'MINIMAX_ENABLE_LOGGING' {
			config.enable_logging = value == 'true' || value == '1'
		}
		'MINIMAX_DEBUG' {
			config.debug = value == 'true' || value == '1'
		}
		'MINIMAX_MAX_ROUNDS' {
			if parsed := strconv.atoi(value) {
				if is_valid_max_rounds(parsed) {
					config.max_rounds = parsed
				}
			}
		}
		'MINIMAX_TOKEN_LIMIT' {
			if parsed := strconv.atoi(value) {
				if parsed > 0 && parsed <= 200000 {
					config.token_limit = parsed
				}
			}
		}
		'MINIMAX_SYSTEM_PROMPT' {
			config.system_prompt = value
		}
		'MINIMAX_WORKSPACE' {
			config.workspace = value
		}
		else {}
	}
}
