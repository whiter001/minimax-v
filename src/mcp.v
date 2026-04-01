module main

// MCP (Model Context Protocol) Client
// Minimal implementation with McpService, JSON-RPC 2.0 over stdio, and built-in tools
import os
import time

const default_mcp_request_timeout_ms = 30000
const understand_image_timeout_ms = 60000

pub struct McpToolParam {
pub:
	name        string
	description string
	param_type  string
	required    bool
}

pub struct McpTool {
pub:
	name        string
	description string
	params      []McpToolParam
	raw_schema  string
}

@[heap]
pub struct McpServer {
pub mut:
	name         string
	command      string
	args         []string
	env          map[string]string
	process      &os.Process = unsafe { nil }
	request_id   int
	tools        []McpTool
	preset_tools []McpTool
	lazy_start   bool
	is_connected bool
}

@[heap]
pub struct McpService {
pub mut:
	servers []&McpServer
}

pub struct McpServerConfig {
pub:
	name    string
	command string
	args    []string
	env     map[string]string
}

// === McpService Methods ===

pub fn new_mcp_service() McpService {
	return McpService{
		servers: []&McpServer{}
	}
}

fn (mut m McpService) add_server(name string, command string, args []string, env map[string]string) {
	mut server := &McpServer{
		name:         name
		command:      command
		args:         args
		env:          env
		request_id:   0
		tools:        []McpTool{}
		preset_tools: []McpTool{}
		lazy_start:   false
		is_connected: false
	}
	m.servers << server
}

fn (mut m McpService) add_lazy_server(name string, command string, args []string, env map[string]string, preset_tools []McpTool) {
	mut server := &McpServer{
		name:         name
		command:      command
		args:         args
		env:          env
		request_id:   0
		tools:        []McpTool{}
		preset_tools: preset_tools
		lazy_start:   true
		is_connected: false
	}
	m.servers << server
}

fn (mut m McpService) start_all() {
	for mut server in m.servers {
		if server.is_connected {
			continue
		}
		start_mcp_server(mut server)
	}
}

fn (mut m McpService) start_eager_servers() {
	for mut server in m.servers {
		if server.is_connected || server.lazy_start {
			continue
		}
		start_mcp_server(mut server)
	}
}

fn (mut m McpService) stop_all() {
	for mut server in m.servers {
		stop_mcp_server(mut server)
	}
}

fn (mut m McpService) get_all_tools() []McpTool {
	mut all := builtin_mcp_tools()
	for server in m.servers {
		if server.is_connected {
			all << server.tools
		} else if server.preset_tools.len > 0 {
			all << server.preset_tools
		}
	}
	return all
}

fn (mut m McpService) find_connected_server_for_tool(tool_name string) ?&McpServer {
	for server in m.servers {
		if !server.is_connected {
			continue
		}
		if server_has_tool(server, tool_name, false) {
			return server
		}
	}
	return none
}

fn (mut m McpService) try_start_lazy_server_for_tool(tool_name string) bool {
	for mut server in m.servers {
		if !server.lazy_start || !server_has_tool(server, tool_name, true) {
			continue
		}
		if start_lazy_mcp_server_for_tool(mut server, tool_name) {
			return true
		}
	}
	return false
}

fn (mut m McpService) call_tool(tool_name string, arguments string) !string {
	// Try built-in tools first
	if tool_name == 'web_search' {
		return builtin_web_search(arguments)
	}
	if tool_name == 'understand_image' {
		return builtin_understand_image(arguments)
	}

	// Try connected servers
	if mut server := m.find_connected_server_for_tool(tool_name) {
		return mcp_call_tool(mut server, tool_name, arguments)
	}

	// Try lazy start
	if m.try_start_lazy_server_for_tool(tool_name) {
		if mut server := m.find_connected_server_for_tool(tool_name) {
			return mcp_call_tool(mut server, tool_name, arguments)
		}
	}

	// Check if tool exists in any lazy server
	for server in m.servers {
		if server.lazy_start && server_has_tool(server, tool_name, true) {
			return error('MCP tool "${tool_name}" was registered by ${server.name}, but it could not be started')
		}
	}

	return error('MCP tool "${tool_name}" not found')
}

// === Built-in Tools ===

fn builtin_web_search_tool() McpTool {
	return new_mcp_tool('web_search', 'Search the web and return relevant results.', [
		new_mcp_tool_param('query', 'Search query string.', 'string', true),
		new_mcp_tool_param('q', 'Alias of query.', 'string', false),
		new_mcp_tool_param('prompt', 'Optional natural-language prompt.', 'string', false),
	], '{"type":"object","properties":{"query":{"type":"string","description":"Search query string."},"q":{"type":"string","description":"Alias of query."},"prompt":{"type":"string","description":"Optional natural-language prompt."}},"required":["query"]}')
}

fn builtin_understand_image_tool() McpTool {
	return new_mcp_tool('understand_image', 'Analyze an image file and answer questions about it.',
		[
		new_mcp_tool_param('image_path', 'Primary image file path.', 'string', true),
		new_mcp_tool_param('image_source', 'Compatibility alias of image_path.', 'string',
			false),
		new_mcp_tool_param('path', 'Compatibility alias of image_path.', 'string', false),
		new_mcp_tool_param('file', 'Compatibility alias of image_path.', 'string', false),
		new_mcp_tool_param('prompt', 'Primary analysis instruction or question.', 'string',
			false),
		new_mcp_tool_param('question', 'Compatibility alias of prompt.', 'string', false),
	], '{"type":"object","properties":{"image_path":{"type":"string","description":"Primary image file path."},"image_source":{"type":"string","description":"Compatibility alias of image_path."},"path":{"type":"string","description":"Compatibility alias of image_path."},"file":{"type":"string","description":"Compatibility alias of image_path."},"prompt":{"type":"string","description":"Primary analysis instruction or question."},"question":{"type":"string","description":"Compatibility alias of prompt."}},"required":["image_path"]}')
}

fn builtin_mcp_tools() []McpTool {
	return [builtin_web_search_tool(), builtin_understand_image_tool()]
}

fn builtin_web_search(arguments string) !string {
	// Parse arguments to get query
	mut query := extract_json_string_value(arguments, 'query')
	if query.len == 0 {
		query = extract_json_string_value(arguments, 'q')
	}
	if query.len == 0 {
		return error('web_search: query is required')
	}

	// Call the web_search MCP tool via mcp__MiniMax__web_search
	// This is handled externally via the tool dispatch mechanism
	return error('web_search must be called via MCP tool dispatch')
}

fn builtin_understand_image(arguments string) !string {
	// Parse arguments to get image_path
	mut image_path := extract_json_string_value(arguments, 'image_path')
	if image_path.len == 0 {
		image_path = extract_json_string_value(arguments, 'image_source')
	}
	if image_path.len == 0 {
		image_path = extract_json_string_value(arguments, 'path')
	}
	if image_path.len == 0 {
		image_path = extract_json_string_value(arguments, 'file')
	}
	if image_path.len == 0 {
		return error('understand_image: image_path is required')
	}

	mut prompt := extract_json_string_value(arguments, 'prompt')
	if prompt.len == 0 {
		prompt = extract_json_string_value(arguments, 'question')
	}
	if prompt.len == 0 {
		prompt = 'Describe this image'
	}

	// Call the understand_image MCP tool via mcp__MiniMax__understand_image
	// This is handled externally via the tool dispatch mechanism
	return error('understand_image must be called via MCP tool dispatch')
}

// === Server Management ===

fn server_has_tool(server McpServer, tool_name string, include_preset bool) bool {
	for tool in server.tools {
		if tool.name == tool_name {
			return true
		}
	}
	if include_preset {
		for tool in server.preset_tools {
			if tool.name == tool_name {
				return true
			}
		}
	}
	return false
}

fn start_lazy_mcp_server_for_tool(mut server McpServer, tool_name string) bool {
	start_mcp_server(mut server)
	if server.is_connected && server_has_tool(server, tool_name, false) {
		return true
	}
	println('[MCP] lazy start failed: ${server.name} cannot provide ${tool_name}')
	return false
}

fn start_mcp_server(mut server McpServer) {
	println('[MCP] starting ${server.name}...')

	cmd := os.find_abs_path_of_executable(server.command) or {
		println('[MCP] command not found: ${server.command}')
		return
	}

	mut proc := build_mcp_process(server, cmd)
	proc.run()

	if !proc.is_alive() {
		println('[MCP] start failed: ${server.name}')
		return
	}

	server.process = proc
	println('[MCP] process started: ${server.name} (PID: ${proc.pid})')

	time.sleep(2000 * time.millisecond)
	if !proc.is_alive() {
		println('[MCP] process exited unexpectedly: ${server.name}')
		return
	}

	// Initialize with retry
	mut initialized := false
	for attempt in 0 .. 5 {
		if attempt > 0 {
			delay_secs := attempt
			println('[MCP] init retry (${attempt}/5, waiting ${delay_secs}s)...')
			time.sleep(delay_secs * time.second)
		}
		initialized = mcp_initialize(mut server)
		if initialized {
			break
		}
	}

	if initialized {
		mcp_list_tools(mut server)
		server.is_connected = true
		println('[MCP] ${server.name}: ${server.tools.len} tools available')
	} else {
		println('[MCP] init failed: ${server.name}')
		stop_mcp_server(mut server)
	}
}

fn build_mcp_process(server McpServer, command_path string) &os.Process {
	mut proc := os.new_process(command_path)
	proc.use_pgroup = true
	proc.set_args(server.args)
	proc.set_redirect_stdio()

	if server.env.len > 0 {
		mut full_env := os.environ()
		for key, val in server.env {
			full_env[key] = val
		}
		proc.set_environment(full_env)
	}
	return proc
}

fn stop_mcp_server(mut server McpServer) {
	if server.process == unsafe { nil } {
		server.is_connected = false
		return
	}
	if server.is_connected || server.process.is_alive() {
		println('[MCP] stopping ${server.name}...')
		server.process.signal_pgkill()
		server.process.wait()
	}
	server.process.close()
	server.process = unsafe { nil }
	server.tools = []McpTool{}
	server.is_connected = false
}

// === JSON-RPC Communication ===

fn mcp_log(server_name string, msg string) {
	println('[MCP:${server_name}] ${msg}')
}

fn mcp_tool_timeout_ms(tool_name string) int {
	return if tool_name == 'understand_image' {
		understand_image_timeout_ms
	} else {
		default_mcp_request_timeout_ms
	}
}

fn mcp_send_request(mut server McpServer, method string, params string) !string {
	return mcp_send_request_with_timeout(mut server, method, params, default_mcp_request_timeout_ms)
}

fn mcp_send_request_with_timeout(mut server McpServer, method string, params string, timeout_ms int) !string {
	server.request_id++
	id := server.request_id

	mut request := '{"jsonrpc":"2.0","id":${id},"method":"${method}"'
	if params.len > 0 {
		request += ',"params":${params}'
	}
	request += '}\n'

	params_preview := if params.len > 200 { params[..200] + '...' } else { params }
	mcp_log(server.name, '-> ${method} ${params_preview}')

	server.process.stdin_write(request)

	return mcp_read_response(mut server, id, timeout_ms)
}

fn mcp_send_notification(mut server McpServer, method string, params string) {
	mut request := '{"jsonrpc":"2.0","method":"${method}"'
	if params.len > 0 {
		request += ',"params":${params}'
	}
	request += '}\n'

	server.process.stdin_write(request)
}

fn mcp_timeout_poll_attempts(timeout_ms int) int {
	if timeout_ms <= 0 {
		return 1
	}
	return (timeout_ms + 99) / 100
}

fn mcp_read_response(mut server McpServer, expected_id int, timeout_ms int) !string {
	mut line_buffer := ''
	mut attempts := 0
	max_attempts := mcp_timeout_poll_attempts(timeout_ms)

	for attempts < max_attempts {
		if server.process.is_pending(.stdout) {
			if chunk := server.process.pipe_read(.stdout) {
				line_buffer += chunk

				for {
					nl := line_buffer.index('\n') or { break }
					line := line_buffer[..nl].trim_space()
					line_buffer = if nl + 1 < line_buffer.len { line_buffer[nl + 1..] } else { '' }

					if line.len == 0 {
						continue
					}

					// Handle server-initiated roots/list request
					if line.contains('"method":"roots/list"') {
						if id_pos := line.index('"id":') {
							mut p := id_pos + 5
							for p < line.len && line[p] in [u8(` `), `\t`] {
								p++
							}
							mut e := p
							for e < line.len && line[e] >= `0` && line[e] <= `9` {
								e++
							}
							if e > p {
								req_id := line[p..e]
								server.process.stdin_write('{"jsonrpc":"2.0","id":${req_id},"result":{"roots":[]}}\n')
							}
						}
						continue
					}

					// Match expected response
					id_match := line.contains('"id":${expected_id},')
						|| line.contains('"id":${expected_id}}')
						|| line.contains('"id": ${expected_id},')
						|| line.contains('"id": ${expected_id}}')
					is_response := line.contains('"result"') || line.contains('"error"')
					if id_match && line.contains('"jsonrpc"') && is_response {
						return line
					}
				}
				continue
			}
		}

		time.sleep(100 * time.millisecond)
		attempts++
	}
	return error('MCP response timeout for request ${expected_id}')
}

// === MCP Protocol ===

fn mcp_initialize(mut server McpServer) bool {
	params := '{"protocolVersion":"2024-11-05","capabilities":{"roots":{"listChanged":true}},"clientInfo":{"name":"minimax-cli","version":"${version}"}}'

	response := mcp_send_request_with_timeout(mut server, 'initialize', params, 60000) or {
		return false
	}

	if response.contains('"id"') && !response.contains('"error"') {
		mcp_send_notification(mut server, 'notifications/initialized', '{}')
		return true
	}

	return false
}

fn mcp_list_tools(mut server McpServer) {
	response := mcp_send_request_with_timeout(mut server, 'tools/list', '{}', 5000) or {
		println('[MCP] list tools failed: ${err}')
		return
	}

	server.tools = parse_mcp_tools(response)
}

fn mcp_call_tool(mut server McpServer, tool_name string, arguments string) !string {
	params := '{"name":"${tool_name}","arguments":${arguments}}'

	response := mcp_send_request_with_timeout(mut server, 'tools/call', params, mcp_tool_timeout_ms(tool_name)) or {
		mcp_log(server.name, 'error ${tool_name}: ${err}')
		return error('MCP call failed: ${err}')
	}

	result := parse_mcp_call_result(response)!
	mcp_log(server.name, '<- ${tool_name} -> ${result.len} chars')
	return result
}

// === Response Parsing ===

fn parse_mcp_tools(response string) []McpTool {
	mut tools := []McpTool{}

	result_key := '"tools":['
	result_idx := response.index(result_key) or { return tools }
	arr_start := result_idx + result_key.len - 1
	arr_end := find_matching_bracket(response, arr_start)
	if arr_end <= arr_start {
		return tools
	}
	arr_content := response[arr_start..arr_end + 1]

	mut search_pos := 1
	for search_pos < arr_content.len {
		remaining := arr_content[search_pos..]
		obj_start := remaining.index('{') or { break }
		abs_start := search_pos + obj_start
		obj_end := find_matching_bracket(arr_content, abs_start)
		if obj_end <= abs_start {
			break
		}

		block := arr_content[abs_start..obj_end + 1]
		name := extract_json_string_value(block, 'name')
		description := extract_json_string_value(block, 'description')

		mut raw_schema := '{}'
		if schema_idx := block.index('"inputSchema":') {
			mut schema_start := schema_idx + 14
			for schema_start < block.len && block[schema_start] in [u8(` `), `\t`, `\n`, `\r`] {
				schema_start++
			}
			if schema_start < block.len && block[schema_start] == `{` {
				schema_end := find_matching_bracket(block, schema_start)
				if schema_end > schema_start {
					raw_schema = block[schema_start..schema_end + 1]
				}
			}
		}

		params := parse_mcp_tool_params(raw_schema)

		if name.len > 0 {
			tools << McpTool{
				name:        name
				description: description
				params:      params
				raw_schema:  raw_schema
			}
		}

		search_pos = obj_end + 1
	}

	return tools
}

fn parse_mcp_tool_params(schema_json string) []McpToolParam {
	mut params := []McpToolParam{}

	props_key := '"properties":{'
	props_idx := schema_json.index(props_key) or { return params }
	props_start := props_idx + props_key.len - 1
	props_end := find_matching_bracket(schema_json, props_start)
	if props_end <= props_start {
		return params
	}
	props_content := schema_json[props_start..props_end + 1]

	mut required_params := []string{}
	if req_idx := schema_json.index('"required":[') {
		req_start := req_idx + 12
		req_end := find_matching_bracket(schema_json, req_start - 1)
		if req_end > req_start {
			req_content := schema_json[req_start..req_end]
			mut pos := 0
			for pos < req_content.len {
				if req_content[pos] == `"` {
					pos++
					mut end := pos
					for end < req_content.len && req_content[end] != `"` {
						end++
					}
					if end > pos {
						required_params << req_content[pos..end]
					}
					pos = end + 1
				} else {
					pos++
				}
			}
		}
	}

	mut search_pos := 1
	for search_pos < props_content.len {
		remaining := props_content[search_pos..]

		key_start := remaining.index('"') or { break }
		abs_key_start := search_pos + key_start + 1
		mut key_end := abs_key_start
		for key_end < props_content.len && props_content[key_end] != `"` {
			key_end++
		}
		if key_end >= props_content.len {
			break
		}
		param_name := props_content[abs_key_start..key_end]

		after_key := props_content[key_end + 1..]
		obj_rel_start := after_key.index('{') or {
			search_pos = key_end + 1
			continue
		}
		abs_obj_start := key_end + 1 + obj_rel_start
		obj_end := find_matching_bracket(props_content, abs_obj_start)
		if obj_end <= abs_obj_start {
			search_pos = abs_obj_start + 1
			continue
		}

		prop_block := props_content[abs_obj_start..obj_end + 1]
		param_type := extract_json_string_value(prop_block, 'type')
		param_desc := extract_json_string_value(prop_block, 'description')

		is_required := param_name in required_params

		params << McpToolParam{
			name:        param_name
			description: param_desc
			param_type:  param_type
			required:    is_required
		}

		search_pos = obj_end + 1
	}

	return params
}

fn parse_mcp_call_result(response string) !string {
	if !response.contains('"result"') {
		if response.contains('"error"') {
			err_msg := extract_json_string_value(response, 'message')
			if err_msg.len > 0 {
				return error('MCP Error: ${err_msg}')
			}
			return error('MCP Error response: ${response}')
		}
		return error('MCP response invalid: ${response}')
	}

	mut text_result := ''
	content_key := '"content":['
	if content_idx := response.index(content_key) {
		arr_start := content_idx + content_key.len - 1
		arr_end := find_matching_bracket(response, arr_start)
		if arr_end > arr_start {
			content_arr := response[arr_start..arr_end + 1]
			mut pos := 0
			for pos < content_arr.len {
				remaining := content_arr[pos..]
				if type_idx := remaining.index('"type":"text"') {
					abs_pos := pos + type_idx
					after_type := content_arr[abs_pos..]
					if text_idx := after_type.index('"text":"') {
						value_start := abs_pos + text_idx + 8
						mut end := value_start
						for end < content_arr.len {
							if content_arr[end] == `"`
								&& (end == value_start || content_arr[end - 1] != `\\`) {
								break
							}
							end++
						}
						if end > value_start {
							text := content_arr[value_start..end]
							text_result += text.replace('\\n', '\n').replace('\\t', '\t').replace('\\"',
								'"')
						}
						pos = end + 1
					} else {
						pos = abs_pos + 13
					}
				} else {
					break
				}
			}
		}
	}

	if text_result.len > 0 {
		return text_result
	}

	text_val := extract_json_string_value(response, 'text')
	if text_val.len > 0 {
		return text_val.replace('\\n', '\n').replace('\\t', '\t').replace('\\"', '"')
	}

	return '(empty result)'
}

// === Helper Functions ===

fn new_mcp_tool_param(name string, description string, param_type string, required bool) McpToolParam {
	return McpToolParam{
		name:        name
		description: description
		param_type:  param_type
		required:    required
	}
}

fn new_mcp_tool(name string, description string, params []McpToolParam, raw_schema string) McpTool {
	return McpTool{
		name:        name
		description: description
		params:      params
		raw_schema:  raw_schema
	}
}

fn find_matching_bracket(s string, start int) int {
	if start >= s.len {
		return -1
	}
	open_ch := s[start]
	close_ch := if open_ch == `[` { u8(`]`) } else { u8(`}`) }
	mut depth := 1
	mut i := start + 1
	mut in_string := false
	for i < s.len {
		ch := s[i]
		if in_string {
			if ch == `"` && !is_json_quote_escaped(s, i) {
				in_string = false
			}
		} else {
			if ch == `"` {
				in_string = true
			} else if ch == open_ch {
				depth++
			} else if ch == close_ch {
				depth--
				if depth == 0 {
					return i
				}
			}
		}
		i++
	}
	return -1
}

fn is_json_quote_escaped(s string, quote_idx int) bool {
	if quote_idx <= 0 || quote_idx >= s.len {
		return false
	}
	mut slash_count := 0
	mut i := quote_idx - 1
	for i >= 0 && s[i] == `\\` {
		slash_count++
		if i == 0 {
			break
		}
		i--
	}
	return slash_count % 2 == 1
}

fn find_json_string_terminator(s string, start int) int {
	mut end := start
	for end < s.len {
		if s[end] == `"` && !is_json_quote_escaped(s, end) {
			return end
		}
		end++
	}
	return -1
}

fn extract_json_string_value(json_str string, key string) string {
	pattern := '"${key}"'
	if idx := json_str.index(pattern) {
		mut p := idx + pattern.len
		for p < json_str.len && json_str[p] in [u8(` `), `\t`, `\n`, `\r`] {
			p++
		}
		if p >= json_str.len || json_str[p] != `:` {
			return ''
		}
		p++
		for p < json_str.len && json_str[p] in [u8(` `), `\t`, `\n`, `\r`] {
			p++
		}
		if p >= json_str.len || json_str[p] != `"` {
			return ''
		}
		p++
		start := p
		end := find_json_string_terminator(json_str, start)
		if end > start {
			return json_str[start..end]
		}
	}
	return ''
}

fn escape_json_string(s string) string {
	mut result := []u8{cap: s.len}
	for ch in s.bytes() {
		match ch {
			`\\` {
				result << `\\`
				result << `\\`
			}
			`"` {
				result << `\\`
				result << `"`
			}
			`\n` {
				result << `\\`
				result << `n`
			}
			`\t` {
				result << `\\`
				result << `t`
			}
			`\r` {
				result << `\\`
				result << `r`
			}
			0x08 {
				result << `\\`
				result << `b`
			}
			0x0C {
				result << `\\`
				result << `f`
			}
			else {
				if ch < 0x20 {
					hex_chars := '0123456789abcdef'
					result << `\\`
					result << `u`
					result << `0`
					result << `0`
					result << hex_chars[ch >> 4]
					result << hex_chars[ch & 0x0F]
				} else {
					result << ch
				}
			}
		}
	}
	return result.bytestr()
}
