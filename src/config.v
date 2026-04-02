module main

import os
import strconv

const max_response_tokens = 204800

fn is_valid_max_tokens(tokens int) bool {
	return tokens > 0 && tokens <= max_response_tokens
}

pub struct Config {
pub mut:
	api_key       string
	api_url       string
	model         string
	temperature   f64
	max_tokens    int
	max_rounds    int
	token_limit   int
	enable_tools  bool
	workspace     string
	system_prompt string
}

fn default_config() Config {
	return Config{
		api_key:       ''
		api_url:       'https://api.minimaxi.com/anthropic/v1/messages'
		model:         'MiniMax-M2'
		temperature:   0.4
		max_tokens:    102400
		max_rounds:    5000
		token_limit:   80000
		enable_tools:  true
		workspace:     ''
		system_prompt: ''
	}
}

fn get_user_home_dir() string {
	$if windows {
		if profile := os.getenv_opt('USERPROFILE') {
			trimmed := profile.trim_space()
			if trimmed.len > 0 {
				return trimmed
			}
		}
		return os.home_dir()
	}
	if home := os.getenv_opt('HOME') {
		trimmed := home.trim_space()
		if trimmed.len > 0 {
			return trimmed
		}
	}
	return os.home_dir()
}

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

fn get_minimax_config_dir() string {
	if custom := os.getenv_opt('MINIMAX_CONFIG_HOME') {
		trimmed := custom.trim_space()
		if trimmed.len > 0 {
			return trimmed
		}
	}
	$if windows {
		if appdata := os.getenv_opt('APPDATA') {
			trimmed := appdata.trim_space()
			if trimmed.len > 0 {
				return os.join_path(trimmed, 'minimax')
			}
		}
		return os.join_path(get_user_home_dir(), 'AppData', 'Roaming', 'minimax')
	}
	return os.join_path(get_user_home_dir(), '.config', 'minimax')
}

fn get_config_path() string {
	return os.join_path(get_minimax_config_dir(), 'config')
}

pub fn load_config() Config {
	mut config := default_config()

	config_path := get_config_path()
	if os.exists(config_path) {
		if content := os.read_file(config_path) {
			config = parse_config_content(content, config)
		}
	}

	apply_env_overrides(mut config)
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
						if temp > 0.0 && temp <= 1.0 {
							config.temperature = temp
						}
					}
				}
				'max_tokens' {
					if tokens := strconv.atoi(val) {
						if is_valid_max_tokens(tokens) {
							config.max_tokens = tokens
						}
					}
				}
				'max_rounds' {
					if rounds := strconv.atoi(val) {
						if rounds > 0 && rounds <= 5000 {
							config.max_rounds = rounds
						}
					}
				}
				'token_limit' {
					if limit := strconv.atoi(val) {
						if limit > 0 && limit <= 200000 {
							config.token_limit = limit
						}
					}
				}
				'enable_tools' {
					config.enable_tools = val == 'true' || val == '1'
				}
				'workspace' {
					config.workspace = val
				}
				else {}
			}
		}
	}
	return config
}

fn apply_env_overrides(mut config Config) {
	if val := os.getenv_opt('MINIMAX_API_KEY') {
		config.api_key = val
	}
	if val := os.getenv_opt('MINIMAX_API_URL') {
		config.api_url = val
	}
	if val := os.getenv_opt('MINIMAX_MODEL') {
		config.model = val
	}
	if val := os.getenv_opt('MINIMAX_TEMPERATURE') {
		if parsed := strconv.atof64(val) {
			if parsed > 0.0 && parsed <= 1.0 {
				config.temperature = parsed
			}
		}
	}
	if val := os.getenv_opt('MINIMAX_MAX_TOKENS') {
		if parsed := strconv.atoi(val) {
			if is_valid_max_tokens(parsed) {
				config.max_tokens = parsed
			}
		}
	}
	if val := os.getenv_opt('MINIMAX_MAX_ROUNDS') {
		if parsed := strconv.atoi(val) {
			if parsed > 0 && parsed <= 5000 {
				config.max_rounds = parsed
			}
		}
	}
	if val := os.getenv_opt('MINIMAX_TOKEN_LIMIT') {
		if parsed := strconv.atoi(val) {
			if parsed > 0 && parsed <= 200000 {
				config.token_limit = parsed
			}
		}
	}
	if val := os.getenv_opt('MINIMAX_ENABLE_TOOLS') {
		config.enable_tools = val == 'true' || val == '1'
	}
	if val := os.getenv_opt('MINIMAX_WORKSPACE') {
		config.workspace = val
	}
}
