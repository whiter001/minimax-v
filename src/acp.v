module main

import os
import time

struct AcpSession {
mut:
	id        string
	workspace string
	client    ApiClient
	cancelled bool
}

struct AcpServer {
mut:
	base_client     ApiClient
	sessions        map[string]&AcpSession
	next_session_id int
}

fn new_acp_server(base_client ApiClient) AcpServer {
	return AcpServer{
		base_client:     base_client
		sessions:        map[string]&AcpSession{}
		next_session_id: 1
	}
}

fn run_acp_server(base_client ApiClient) ! {
	mut server := new_acp_server(base_client)
	for {
		line := os.input('')
		if line.len == 0 {
			break
		}
		response := server.handle_request(line)
		if response.len > 0 {
			println(response)
		}
	}
}

fn (mut s AcpServer) handle_request(line string) string {
	trimmed := line.trim_space()
	if trimmed.len == 0 {
		return ''
	}
	req := parse_json_string_object(trimmed)
	method := req['method'] or { '' }
	params_raw := req['params'] or { '{}' }
	mut id_raw := extract_json_raw_value(trimmed, 'id')
	if id_raw.len == 0 {
		if id := req['id'] {
			id_raw = '"${escape_json_string(id)}"'
		}
	}

	match method {
		'initialize' {
			if id_raw.len == 0 {
				return ''
			}
			result := '{"protocolVersion":1,"agentCapabilities":{"streaming":true,"chatAvailability":"eager","pushNotifications":{"level":"none"},"loadSession":{"supported":false,"_convenience":false},"memory":{"supported":false}},"agentInfo":{"name":"minimax-v","title":"MiniMax V-Lang CLI","version":"${version}"}}'
			return build_acp_result(id_raw, result)
		}
		'ping' {
			if id_raw.len == 0 {
				return ''
			}
			return build_acp_result(id_raw, '{"timestamp":${time.now().unix_milli()}}')
		}
		'tools/list' {
			if id_raw.len == 0 {
				return ''
			}
			tools_json := get_tools_schema_json()
			return build_acp_result(id_raw, tools_json)
		}
		'sampling' {
			if id_raw.len == 0 {
				return ''
			}
			params := parse_json_string_object(params_raw)
			message := params['message'] or { '' }
			if message.len > 0 {
				return build_acp_error(id_raw, -32601, 'sampling not implemented: streaming not supported in stdio mode')
			}
			return build_acp_error(id_raw, -32601, 'sampling not implemented')
		}
		'logging' {
			if id_raw.len == 0 {
				return ''
			}
			return build_acp_result(id_raw, '{"received":true}')
		}
		'newSession' {
			if id_raw.len == 0 {
				return ''
			}
			params := parse_json_string_object(params_raw)
			cwd := params['cwd'] or { '' }
			session_id := s.create_session(cwd)
			result := '{"sessionId":"${escape_json_string(session_id)}"}'
			return build_acp_result(id_raw, result)
		}
		'prompt' {
			if id_raw.len == 0 {
				return ''
			}
			return s.handle_prompt(id_raw, params_raw)
		}
		'cancel' {
			params := parse_json_string_object(params_raw)
			session_id := params['sessionId'] or { '' }
			if session_id.len > 0 {
				s.cancel_session(session_id)
			}
			if id_raw.len == 0 {
				return ''
			}
			return build_acp_result(id_raw, '{}')
		}
		else {
			if id_raw.len == 0 {
				return ''
			}
			return build_acp_error(id_raw, -32601, 'Method not found')
		}
	}
}

fn (mut s AcpServer) handle_prompt(id_raw string, params_raw string) string {
	params := parse_json_string_object(params_raw)
	mut session_id := params['sessionId'] or { '' }
	if session_id.len == 0 || session_id !in s.sessions {
		session_id = s.create_session('')
	}
	mut prompt_text := extract_prompt_text_from_json(params['prompt'] or { '' })
	if prompt_text.len == 0 {
		prompt_text = params['text'] or { '' }
	}

	mut session := s.sessions[session_id] or {
		return build_acp_error(id_raw, -32602, 'Invalid params: session not found')
	}
	if session.cancelled {
		session.cancelled = false
		result := '{"sessionId":"${escape_json_string(session.id)}","stopReason":"cancelled","message":{"role":"assistant","content":[]}}'
		return build_acp_result(id_raw, result)
	}
	if prompt_text.trim_space().len == 0 {
		return build_acp_error(id_raw, -32602, 'Invalid params: prompt is required')
	}

	response := session.client.chat(prompt_text) or {
		err_msg := escape_json_string(err.msg())
		result := '{"sessionId":"${escape_json_string(session.id)}","stopReason":"refusal","message":{"role":"assistant","content":[{"type":"text","text":"Error: ${err_msg}"}]}}'
		return build_acp_result(id_raw, result)
	}

	stop_reason := if session.cancelled { 'cancelled' } else { 'end_turn' }
	session.cancelled = false
	escaped := escape_json_string(response)
	result := '{"sessionId":"${escape_json_string(session.id)}","stopReason":"${stop_reason}","message":{"role":"assistant","content":[{"type":"text","text":"${escaped}"}]}}'
	return build_acp_result(id_raw, result)
}

fn (mut s AcpServer) cancel_session(session_id string) {
	mut session := s.sessions[session_id] or { return }
	session.cancelled = true
}

fn (mut s AcpServer) create_session(cwd string) string {
	workspace := resolve_acp_workspace(cwd, s.base_client.workspace)
	if workspace.len > 0 && !os.is_dir(workspace) {
		os.mkdir_all(workspace) or {}
	}
	session_id := 'sess-${time.now().unix_milli()}-${s.next_session_id}'
	s.next_session_id++
	mut client := clone_acp_client(s.base_client, workspace)
	mut session := &AcpSession{
		id:        session_id
		workspace: workspace
		client:    client
		cancelled: false
	}
	s.sessions[session_id] = session
	return session_id
}

fn clone_acp_client(template ApiClient, workspace string) ApiClient {
	mut client := template
	client.messages = []ChatMessage{}
	client.workspace = workspace
	client.use_streaming = false
	client.silent_mode = true
	client.plan_mode = false
	client.trajectory = new_trajectory_recorder(false)
	client.logger = new_logger(false)
	client.mcp_manager = new_mcp_manager()
	client.bash_session = new_bash_session(workspace)
	return client
}

fn resolve_acp_workspace(cwd string, fallback string) string {
	mut ws := cwd.trim_space()
	if ws.len == 0 {
		ws = fallback.trim_space()
	}
	if ws.len == 0 {
		return os.getwd()
	}
	if ws.starts_with('~') {
		ws = expand_home_path(ws)
	}
	if !is_abs_path(ws) {
		base := os.getwd()
		ws = os.join_path(base, ws)
	}
	return ws
}

fn is_abs_path(path string) bool {
	if path.len >= 2 && path[1] == `:` {
		return true
	}
	if path.len >= 2 && path[0] == `\\` {
		return true
	}
	return path.starts_with('/') || path.starts_with('~')
}

fn build_acp_result(id_raw string, result_json string) string {
	return '{"jsonrpc":"2.0","id":${id_raw},"result":${result_json}}'
}

fn build_acp_error(id_raw string, code int, message string) string {
	escaped := escape_json_string(message)
	return '{"jsonrpc":"2.0","id":${id_raw},"error":{"code":${code},"message":"${escaped}"}}'
}

fn extract_json_raw_value(json_str string, key string) string {
	pattern := '"${key}"'
	if idx := json_str.index(pattern) {
		mut pos := idx + pattern.len
		for pos < json_str.len && json_str[pos] in [u8(` `), `\t`, `\n`, `\r`] {
			pos++
		}
		if pos >= json_str.len || json_str[pos] != `:` {
			return ''
		}
		pos++
		for pos < json_str.len && json_str[pos] in [u8(` `), `\t`, `\n`, `\r`] {
			pos++
		}
		if pos >= json_str.len {
			return ''
		}

		start := pos
		ch := json_str[pos]
		if ch == `"` {
			pos++
			for pos < json_str.len {
				if json_str[pos] == `"` && json_str[pos - 1] != `\\` {
					break
				}
				pos++
			}
			if pos < json_str.len {
				return json_str[start..pos + 1]
			}
			return ''
		}
		if ch == `{` || ch == `[` {
			end := find_matching_bracket(json_str, pos)
			if end > pos {
				return json_str[start..end + 1]
			}
			return ''
		}
		mut end := pos
		for end < json_str.len && json_str[end] !in [u8(`,`), `}`, `]`, ` `, `\n`, `\t`, `\r`] {
			end++
		}
		return json_str[start..end]
	}
	return ''
}

fn extract_prompt_text_from_json(prompt_json string) string {
	raw := prompt_json.trim_space()
	if raw.len == 0 {
		return ''
	}
	if raw.starts_with('"') && raw.ends_with('"') && raw.len >= 2 {
		return decode_json_string(raw[1..raw.len - 1])
	}
	if raw.starts_with('{') {
		obj := parse_json_string_object(raw)
		return obj['text'] or { '' }
	}

	mut texts := []string{}
	mut search_pos := 0
	for search_pos < raw.len {
		remaining := raw[search_pos..]
		if text_key := remaining.index('"text"') {
			mut pos := search_pos + text_key + '"text"'.len
			for pos < raw.len && raw[pos] in [u8(` `), `\t`, `\n`, `\r`] {
				pos++
			}
			if pos >= raw.len || raw[pos] != `:` {
				search_pos = pos + 1
				continue
			}
			pos++
			for pos < raw.len && raw[pos] in [u8(` `), `\t`, `\n`, `\r`] {
				pos++
			}
			if pos >= raw.len || raw[pos] != `"` {
				search_pos = pos + 1
				continue
			}
			start := pos + 1
			mut end := start
			for end < raw.len {
				if raw[end] == `"` && raw[end - 1] != `\\` {
					break
				}
				end++
			}
			if end < raw.len {
				texts << decode_json_string(raw[start..end])
				search_pos = end + 1
				continue
			}
		}
		break
	}
	return texts.join('\n').trim_space()
}
