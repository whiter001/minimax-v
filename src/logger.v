module main

import os
import time
import json

const max_logged_text_len = 2000

struct Logger {
mut:
	enabled  bool
	log_dir  string
	log_file string
}

fn new_logger(enabled bool) Logger {
	log_dir := os.expand_tilde_to_home('~/.config/minimax/logs')
	if enabled && !os.is_dir(log_dir) {
		os.mkdir_all(log_dir) or {}
	}
	date := time.now().custom_format('YYYY-MM-DD')
	log_file := os.join_path(log_dir, '${date}.log')
	return Logger{
		enabled:  enabled
		log_dir:  log_dir
		log_file: log_file
	}
}

fn (l Logger) log(level string, category string, message string) {
	if !l.enabled {
		return
	}
	ts := time.now().custom_format('hh:mm:ss')
	line := '[${ts}] [${level}] [${category}] ${message}\n'
	mut f := os.open_append(l.log_file) or { return }
	f.write_string(line) or {}
	f.close()
}

fn (l Logger) log_request(model string, messages_count int, has_tools bool, is_streaming bool) {
	l.log('INFO', 'REQUEST', 'model=${model} messages=${messages_count} tools=${has_tools} stream=${is_streaming}')
}

fn (l Logger) log_user_prompt(prompt string) {
	truncated := if prompt.len > max_logged_text_len {
		'${prompt[..max_logged_text_len]}...[truncated ${prompt.len - max_logged_text_len} chars]'
	} else {
		prompt
	}
	l.log('INFO', 'USER_PROMPT', truncated.replace('\n', '\\n'))
}

fn (l Logger) log_ai_response(text string, is_truncated bool) {
	trunc_msg := if is_truncated { '[TRUNCATED]' } else { '' }
	truncated := if text.len > max_logged_text_len {
		'${text[..max_logged_text_len]}...[truncated ${text.len - max_logged_text_len} chars] ${trunc_msg}'
	} else {
		'${text} ${trunc_msg}'
	}
	l.log('INFO', 'AI_RESPONSE', truncated.replace('\n', '\\n'))
}

fn (l Logger) log_response(stop_reason string, text_len int, tool_count int, thinking_len int) {
	l.log('INFO', 'RESPONSE', 'stop_reason=${stop_reason} text_len=${text_len} tools=${tool_count} thinking_len=${thinking_len}')
}

fn (l Logger) log_tool_call(name string, input_keys string) {
	l.log('INFO', 'TOOL_CALL', 'name=${name} input_keys=[${input_keys}]')
}

fn (l Logger) log_tool_input(name string, input map[string]string) {
	input_json := json.encode(input)
	truncated := if input_json.len > max_logged_text_len {
		'${input_json[..max_logged_text_len]}...[truncated]'
	} else {
		input_json
	}
	l.log('INFO', 'TOOL_INPUT', 'name=${name} input=${truncated}')
}

fn (l Logger) log_tool_result(name string, result_len int, is_truncated bool) {
	l.log('INFO', 'TOOL_RESULT', 'name=${name} result_len=${result_len} truncated=${is_truncated}')
}

fn (l Logger) log_tool_result_detail(name string, result string) {
	truncated := if result.len > max_logged_text_len {
		'${result[..max_logged_text_len]}...[truncated ${result.len - max_logged_text_len} chars]'
	} else {
		result
	}
	l.log('INFO', 'TOOL_RESULT_DETAIL', 'name=${name} result=${truncated.replace('\n',
		'\\n')}')
}

fn (l Logger) log_mcp_request(server string, method string, params string) {
	truncated := if params.len > max_logged_text_len {
		'${params[..max_logged_text_len]}...[truncated]'
	} else {
		params
	}
	l.log('DEBUG', 'MCP_REQ', 'server=${server} method=${method} params=${truncated}')
}

fn (l Logger) log_mcp_response(server string, method string, result_len int, is_error bool) {
	status := if is_error { 'ERROR' } else { 'OK' }
	l.log('DEBUG', 'MCP_RES', 'server=${server} method=${method} result_len=${result_len} status=${status}')
}

fn (l Logger) log_browser_snapshot(action string, url string, element_count int, title string) {
	l.log('INFO', 'BROWSER', 'action=${action} url=${url} elements=${element_count} title=${title}')
}

fn (l Logger) log_error(category string, message string) {
	l.log('ERROR', category, message)
}

fn (l Logger) log_summarize(old_messages int, new_estimate int) {
	l.log('INFO', 'SUMMARIZE', 'compressed=${old_messages} messages, new_token_estimate=~${new_estimate}')
}

fn (l Logger) log_session_start(version string, model string) {
	l.log('INFO', 'SESSION', '=== Session started === version=${version} model=${model}')
}

fn (l Logger) log_session_end() {
	l.log('INFO', 'SESSION', '=== Session ended ===')
}

fn (l Logger) log_execution_duration(phase string, duration_ms int) {
	l.log('INFO', 'TIMING', 'phase=${phase} duration_ms=${duration_ms}')
}

fn (l Logger) log_phase_start(phase string, detail string) {
	l.log('INFO', 'PHASE_START', 'phase=${phase} ${detail}')
}

fn (l Logger) log_phase_end(phase string, duration_ms i64, detail string) {
	l.log('INFO', 'PHASE_END', 'phase=${phase} duration_ms=${duration_ms} ${detail}')
}
