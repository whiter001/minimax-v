module main

// MCP (Model Context Protocol) Client
// Communicates with MCP servers via stdio JSON-RPC 2.0
import os
import time

const default_mcp_request_timeout_ms = 30000
const understand_image_timeout_ms = 90000

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
	raw_schema  string // raw JSON input_schema for API forwarding
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

pub struct McpManager {
pub mut:
	servers []&McpServer
}

fn new_mcp_manager() McpManager {
	return McpManager{
		servers: []&McpServer{}
	}
}

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
		new_mcp_tool_param('image_path', 'Path to the image file.', 'string', true),
		new_mcp_tool_param('image_source', 'Alias of image_path.', 'string', false),
		new_mcp_tool_param('path', 'Alias of image_path.', 'string', false),
		new_mcp_tool_param('file', 'Alias of image_path.', 'string', false),
		new_mcp_tool_param('prompt', 'Analysis instruction or question.', 'string', false),
		new_mcp_tool_param('question', 'Alias of prompt.', 'string', false),
	], '{"type":"object","properties":{"image_path":{"type":"string","description":"Path to the image file."},"image_source":{"type":"string","description":"Alias of image_path."},"path":{"type":"string","description":"Alias of image_path."},"file":{"type":"string","description":"Alias of image_path."},"prompt":{"type":"string","description":"Analysis instruction or question."},"question":{"type":"string","description":"Alias of prompt."}},"required":["image_path"]}')
}

fn builtin_mcp_tools() []McpTool {
	return [builtin_web_search_tool(), builtin_understand_image_tool()]
}

fn manager_has_server_named(m McpManager, name string) bool {
	for server in m.servers {
		if server.name == name {
			return true
		}
	}
	return false
}

fn (mut m McpManager) add_server(name string, command string, args []string, env map[string]string) {
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

fn (mut m McpManager) add_lazy_server(name string, command string, args []string, env map[string]string, preset_tools []McpTool) {
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

fn (mut m McpManager) start_all() {
	for mut server in m.servers {
		if server.is_connected {
			continue
		}
		start_mcp_server(mut server)
	}
}

fn (mut m McpManager) start_eager_servers() {
	for mut server in m.servers {
		if server.is_connected || server.lazy_start {
			continue
		}
		start_mcp_server(mut server)
	}
}

fn (mut m McpManager) stop_all() {
	for mut server in m.servers {
		stop_mcp_server(mut server)
	}
}

fn (mut m McpManager) get_all_tools() []McpTool {
	mut all := []McpTool{}
	for server in m.servers {
		if server.is_connected {
			all << server.tools
		} else if server.preset_tools.len > 0 {
			all << server.preset_tools
		}
	}
	return all
}

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
	println('[MCP] ❌ 懒启动失败: ${server.name} 无法提供 ${tool_name}')
	return false
}

fn (mut m McpManager) find_connected_server_for_tool(tool_name string) ?&McpServer {
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

fn (mut m McpManager) try_start_lazy_server_for_tool(tool_name string) bool {
	mut started := false
	for mut server in m.servers {
		if !server.lazy_start || !server_has_tool(server, tool_name, true) {
			continue
		}
		started = start_lazy_mcp_server_for_tool(mut server, tool_name)
		if started {
			return true
		}
	}
	return false
}

fn (mut m McpManager) call_tool(tool_name string, arguments string) !string {
	if mut server := m.find_connected_server_for_tool(tool_name) {
		return mcp_call_tool(mut server, tool_name, arguments)
	}

	if m.try_start_lazy_server_for_tool(tool_name) {
		if mut server := m.find_connected_server_for_tool(tool_name) {
			return mcp_call_tool(mut server, tool_name, arguments)
		}
	}
	for server in m.servers {
		if server.lazy_start && server_has_tool(server, tool_name, true) {
			return error('MCP tool "${tool_name}" was registered by ${server.name}, but it could not be started')
		}
	}
	return error('MCP tool "${tool_name}" not found')
}

// --- Process Management ---

fn start_mcp_server(mut server McpServer) {
	println('[MCP] 启动 ${server.name}...')

	// Resolve command to absolute path
	cmd := os.find_abs_path_of_executable(server.command) or {
		println('[MCP] ❌ 找不到命令: ${server.command}')
		return
	}

	mut proc := build_mcp_process(server, cmd)

	proc.run()

	if !proc.is_alive() {
		println('[MCP] ❌ 启动失败: ${server.name}')
		return
	}

	server.process = proc
	println('[MCP] ✅ 进程已启动: ${server.name} (PID: ${proc.pid})')

	// Give process more time to warm up (2 seconds on Windows)
	time.sleep(2000 * time.millisecond)
	if !proc.is_alive() {
		println('[MCP] ❌ 进程意外退出: ${server.name}')
		return
	}

	// Try initialization with retry logic and increasing delays
	mut initialized := false
	for attempt in 0 .. 5 {
		if attempt > 0 {
			delay_secs := attempt
			println('[MCP] 初始化重试 (${attempt}/5，等待${delay_secs}秒)...')
			time.sleep(delay_secs * time.second)
		}
		initialized = mcp_initialize(mut server)
		if initialized {
			break
		}
	}

	if initialized {
		// List available tools
		mcp_list_tools(mut server)
		server.is_connected = true
		println('[MCP] 🔧 ${server.name}: ${server.tools.len} 个工具可用')
	} else {
		println('[MCP] ❌ 初始化失败: ${server.name}')
		stop_mcp_server(mut server)
	}
}

fn build_mcp_process(server McpServer, command_path string) &os.Process {
	mut proc := os.new_process(command_path)
	// uvx 会再拉起真实的 MCP 子进程，启用独立进程组后才能一次性清理整棵子树。
	proc.use_pgroup = true
	proc.set_args(server.args)
	proc.set_redirect_stdio()

	// Set environment variables: inherit current env + add custom ones
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
		println('[MCP] 停止 ${server.name}...')
		server.process.signal_pgkill()
		server.process.wait()
	}
	server.process.close()
	server.process = unsafe { nil }
	server.tools = []McpTool{}
	server.is_connected = false
}

// --- JSON-RPC Communication ---

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
	mcp_log(server.name, '→ ${method} ${params_preview}')

	// Write to stdin
	server.process.stdin_write(request)

	// Read response from stdout (with timeout)
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
		// Use non-blocking pipe_read instead of blocking stdout_read
		if server.process.is_pending(.stdout) {
			if chunk := server.process.pipe_read(.stdout) {
				line_buffer += chunk

				// Line-based JSON-RPC parsing (MCP stdio messages are newline-delimited)
				for {
					nl := line_buffer.index('\n') or { break }
					line := line_buffer[..nl].trim_space()
					line_buffer = if nl + 1 < line_buffer.len { line_buffer[nl + 1..] } else { '' }

					if line.len == 0 {
						continue
					}

					// Handle server-initiated roots/list request: respond with empty roots so
					// the MCP server doesn't block waiting for our reply before sending back
					// the response to our own pending request.
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

					// Match our expected response: must carry result/error (not a server request)
					id_match := line.contains('"id":${expected_id},')
						|| line.contains('"id":${expected_id}}')
						|| line.contains('"id": ${expected_id},')
						|| line.contains('"id": ${expected_id}}')
					is_response := line.contains('"result"') || line.contains('"error"')
					if id_match && line.contains('"jsonrpc"') && is_response {
						return line
					}
				}
				continue // Data available, keep reading without sleep
			}
		}

		time.sleep(100 * time.millisecond)
		attempts++
	}
	return error('MCP response timeout for request ${expected_id}')
}

// --- MCP Protocol ---

fn mcp_initialize(mut server McpServer) bool {
	params := '{"protocolVersion":"2024-11-05","capabilities":{"roots":{"listChanged":true}},"clientInfo":{"name":"minimax-cli","version":"${version}"}}'

	// Increase timeout significantly for initialization (60 seconds)
	response := mcp_send_request_with_timeout(mut server, 'initialize', params, 60000) or {
		// println('[MCP] 初始化请求失败: $err')
		return false
	}

	// Check for valid response - accept any response with id that's not an error
	if response.contains('"id"') && !response.contains('"error"') {
		// Send initialized notification
		mcp_send_notification(mut server, 'notifications/initialized', '{}')
		return true
	}

	return false
}

fn mcp_list_tools(mut server McpServer) {
	response := mcp_send_request_with_timeout(mut server, 'tools/list', '{}', 5000) or {
		println('[MCP] 获取工具列表失败: ${err}')
		return
	}

	// Parse tools from response
	server.tools = parse_mcp_tools(response)
}

fn mcp_call_tool(mut server McpServer, tool_name string, arguments string) !string {
	params := '{"name":"${tool_name}","arguments":${arguments}}'

	response := mcp_send_request_with_timeout(mut server, 'tools/call', params, mcp_tool_timeout_ms(tool_name)) or {
		mcp_log(server.name, '✗ ${tool_name} error: ${err}')
		return error('MCP 调用失败: ${err}')
	}

	// Extract result content
	result := parse_mcp_call_result(response)!
	mcp_log(server.name, '← ${tool_name} -> ${result.len} chars')
	return result
}

// --- Response Parsing ---

fn parse_mcp_tools(response string) []McpTool {
	mut tools := []McpTool{}

	// Find "tools":[ array in result
	result_key := '"tools":['
	result_idx := response.index(result_key) or { return tools }
	arr_start := result_idx + result_key.len - 1
	arr_end := find_matching_bracket(response, arr_start)
	if arr_end <= arr_start {
		return tools
	}
	arr_content := response[arr_start..arr_end + 1]

	// Parse each tool object
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

		// Extract inputSchema as raw JSON
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

		// Parse parameters from inputSchema
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

	// Find "properties":{
	props_key := '"properties":{'
	props_idx := schema_json.index(props_key) or { return params }
	props_start := props_idx + props_key.len - 1
	props_end := find_matching_bracket(schema_json, props_start)
	if props_end <= props_start {
		return params
	}
	props_content := schema_json[props_start..props_end + 1]

	// Find required array
	mut required_params := []string{}
	if req_idx := schema_json.index('"required":[') {
		req_start := req_idx + 12
		req_end := find_matching_bracket(schema_json, req_start - 1)
		if req_end > req_start {
			req_content := schema_json[req_start..req_end]
			// Parse simple string array
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

	// Parse each property
	mut search_pos := 1
	for search_pos < props_content.len {
		// Find "name":{...}
		remaining := props_content[search_pos..]

		// Find next key
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

		// Find value object
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
	// Look for "result":{"content":[...]}
	if !response.contains('"result"') {
		// Check for error
		if response.contains('"error"') {
			err_msg := extract_json_string_value(response, 'message')
			if err_msg.len > 0 {
				return error('MCP Error: ${err_msg}')
			}
			return error('MCP Error response: ${response}')
		}
		return error('MCP 响应无效: ${response}')
	}

	// Extract content array from result
	mut text_result := ''
	content_key := '"content":['
	if content_idx := response.index(content_key) {
		arr_start := content_idx + content_key.len - 1
		arr_end := find_matching_bracket(response, arr_start)
		if arr_end > arr_start {
			content_arr := response[arr_start..arr_end + 1]
			// Extract text from content blocks
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

	// Fallback: try to extract any text value
	text_val := extract_json_string_value(response, 'text')
	if text_val.len > 0 {
		return text_val.replace('\\n', '\n').replace('\\t', '\t').replace('\\"', '"')
	}

	return '(empty result)'
}

// --- Schema Generation for API ---

fn get_mcp_tools_schema_json(tools []McpTool) string {
	if tools.len == 0 {
		return ''
	}

	mut result := ''
	for tool in tools {
		escaped_desc := escape_json_string(tool.description)
		result += '{"name":"${tool.name}","description":"${escaped_desc}","input_schema":${tool.raw_schema}},'
	}

	if result.ends_with(',') {
		result = result[..result.len - 1]
	}
	return result
}

// --- MCP Config Loading ---

pub struct McpServerConfig {
pub:
	name    string
	command string
	args    []string
	env     map[string]string
}

fn load_mcp_config() []McpServerConfig {
	config_path := os.join_path(get_minimax_config_dir(), 'mcp.json')
	if !os.exists(config_path) {
		// Fallback: try legacy path
		legacy_path := os.join_path(get_user_home_dir(), '.minimax_mcp.json')
		if os.exists(legacy_path) {
			content := os.read_file(legacy_path) or { return [] }
			return parse_mcp_config(content)
		}
		return []
	}

	content := os.read_file(config_path) or { return [] }
	return parse_mcp_config(content)
}

// Find opening bracket '[' after a JSON key like "args", skipping whitespace and colon
fn find_json_array(block string, key string) ?int {
	key_idx := block.index(key) or { return none }
	mut p := key_idx + key.len
	for p < block.len && block[p] in [u8(` `), `\t`, `\n`, `\r`] {
		p++
	}
	if p >= block.len || block[p] != `:` {
		return none
	}
	p++
	for p < block.len && block[p] in [u8(` `), `\t`, `\n`, `\r`] {
		p++
	}
	if p >= block.len || block[p] != `[` {
		return none
	}
	return p
}

// Find opening brace '{' after a JSON key like "env", skipping whitespace and colon
fn find_json_object(block string, key string) ?int {
	key_idx := block.index(key) or { return none }
	mut p := key_idx + key.len
	for p < block.len && block[p] in [u8(` `), `\t`, `\n`, `\r`] {
		p++
	}
	if p >= block.len || block[p] != `:` {
		return none
	}
	p++
	for p < block.len && block[p] in [u8(` `), `\t`, `\n`, `\r`] {
		p++
	}
	if p >= block.len || block[p] != `{` {
		return none
	}
	return p
}

fn parse_mcp_config(content string) []McpServerConfig {
	mut configs := []McpServerConfig{}

	// Find "servers" key and its opening brace (handles optional whitespace)
	servers_key_idx := content.index('"servers"') or { return configs }
	mut brace_pos := servers_key_idx + '"servers"'.len
	// Skip whitespace, colon, whitespace
	for brace_pos < content.len && content[brace_pos] in [u8(` `), `\t`, `\n`, `\r`] {
		brace_pos++
	}
	if brace_pos >= content.len || content[brace_pos] != `:` {
		return configs
	}
	brace_pos++
	for brace_pos < content.len && content[brace_pos] in [u8(` `), `\t`, `\n`, `\r`] {
		brace_pos++
	}
	if brace_pos >= content.len || content[brace_pos] != `{` {
		return configs
	}
	servers_start := brace_pos
	servers_end := find_matching_bracket(content, servers_start)
	if servers_end <= servers_start {
		return configs
	}
	servers_content := content[servers_start..servers_end + 1]

	// Parse each server entry
	mut pos := 1
	for pos < servers_content.len {
		// Skip whitespace and commas
		for pos < servers_content.len && servers_content[pos] in [u8(` `), `,`, `\n`, `\t`, `\r`] {
			pos++
		}
		if pos >= servers_content.len || servers_content[pos] == `}` {
			break
		}

		// Skip comments
		if pos + 1 < servers_content.len && servers_content[pos] == `/`
			&& servers_content[pos + 1] == `/` {
			for pos < servers_content.len && servers_content[pos] != `\n` {
				pos++
			}
			continue
		}

		// Find "name":
		if servers_content[pos] != `"` {
			pos++
			continue
		}
		pos++
		mut name_end := pos
		for name_end < servers_content.len && servers_content[name_end] != `"` {
			name_end++
		}
		server_name := servers_content[pos..name_end]
		pos = name_end + 1

		// Skip : and whitespace
		for pos < servers_content.len && servers_content[pos] in [u8(`:`), ` `, `\t`, `\n`, `\r`] {
			pos++
		}

		// Find server config object
		if pos >= servers_content.len || servers_content[pos] != `{` {
			continue
		}
		obj_end := find_matching_bracket(servers_content, pos)
		if obj_end <= pos {
			break
		}
		block := servers_content[pos..obj_end + 1]

		// Extract fields
		command := extract_json_string_value(block, 'command')
		server_type := extract_json_string_value(block, 'type')

		// Only support stdio servers
		if server_type != 'stdio' || command.len == 0 {
			pos = obj_end + 1
			continue
		}

		// Extract args array
		mut args := []string{}
		if args_start := find_json_array(block, '"args"') {
			arr_end := find_matching_bracket(block, args_start)
			if arr_end > args_start {
				args_content := block[args_start + 1..arr_end]
				mut apos := 0
				for apos < args_content.len {
					if args_content[apos] == `"` {
						apos++
						mut aend := apos
						for aend < args_content.len && args_content[aend] != `"` {
							aend++
						}
						if aend > apos {
							args << args_content[apos..aend]
						}
						apos = aend + 1
					} else {
						apos++
					}
				}
			}
		}

		// npx may prompt for package installation confirmation on first run.
		command_base := os.base(command).to_lower()
		is_npx_command := command_base == 'npx' || command_base == 'npx.cmd'
		if is_npx_command {
			mut has_yes_flag := false
			for arg in args {
				if arg == '-y' || arg == '--yes' {
					has_yes_flag = true
					break
				}
			}
			if !has_yes_flag {
				args.insert(0, '-y')
			}
		}

		// Extract env map
		mut env := map[string]string{}
		if env_start := find_json_object(block, '"env"') {
			env_end := find_matching_bracket(block, env_start)
			if env_end > env_start {
				env_block := block[env_start..env_end + 1]
				env = parse_json_string_object(env_block)
			}
		}

		if command.len > 0 {
			configs << McpServerConfig{
				name:    server_name
				command: command
				args:    args
				env:     env
			}
		}

		pos = obj_end + 1
	}

	return configs
}
