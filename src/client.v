module main

import net.http

const default_agent_prompt = 'You are a helpful AI assistant with access to tools.\n\nUse the `bash` tool whenever the task requires running local commands or third-party CLIs. On this Windows machine, prefer shell commands that work well in Nushell. If browser automation is needed and the user mentions v-browser or browser actions, use the `bash` tool to run `v-browser ...` commands directly. Preferred v-browser workflow: first inspect readiness with `v-browser status --json`; if not connected, run `v-browser connect`; then verify with `v-browser status --json` or light probes like `v-browser title` / `v-browser url`; only after that run page actions such as `open`, `snapshot`, `get`, or `eval`. Do not rely on pueue-based orchestration; prefer direct Nushell commands and Nushell job patterns when background work is needed. If a browser command fails because the environment is not ready, explain the concrete blocker and suggest the next command to run. When you have enough information, answer concisely in plain text.'

struct ChatMessage {
	role         string
	content      string
	content_json string
}

struct ApiClient {
mut:
	api_key       string
	api_url       string
	model         string
	temperature   f64
	max_tokens    int
	max_rounds    int
	enable_tools  bool
	system_prompt string
	messages      []ChatMessage
	executor      ToolExecutor
}

fn new_api_client(config Config, executor ToolExecutor) ApiClient {
	return ApiClient{
		api_key:       config.api_key
		api_url:       config.api_url
		model:         config.model
		temperature:   config.temperature
		max_tokens:    config.max_tokens
		max_rounds:    config.max_rounds
		enable_tools:  config.enable_tools
		system_prompt: config.system_prompt
		messages:      []ChatMessage{}
		executor:      executor
	}
}

fn (mut c ApiClient) add_message(role string, content string) {
	c.messages << ChatMessage{
		role:    role
		content: content
	}
}

fn (c ApiClient) build_request_json() string {
	mut body_json := '{"model":"${c.model}","max_tokens":${c.max_tokens},"temperature":${c.temperature}'
	if c.enable_tools {
		body_json += ',"tools":' + get_tools_schema_json()
	}
	effective_system := if c.system_prompt.len > 0 {
		c.system_prompt
	} else if c.enable_tools {
		default_agent_prompt
	} else {
		''
	}
	if effective_system.len > 0 {
		body_json += ',"system":[{"type":"text","text":"${escape_json_string(effective_system)}"}]'
	}
	body_json += ',"messages":['
	for msg in c.messages {
		content_val := if msg.content_json.len > 0 {
			msg.content_json
		} else {
			'"${escape_json_string(msg.content)}"'
		}
		body_json += '{"role":"${msg.role}","content":${content_val}},'
	}
	if body_json.ends_with(',') {
		body_json = body_json[..body_json.len - 1]
	}
	body_json += ']}'
	return body_json
}

fn (c ApiClient) send_api_request(body_json string) !string {
	mut headers := http.new_header()
	headers.add(.authorization, 'Bearer ${c.api_key}')
	headers.add(.content_type, 'application/json')
	mut req := http.Request{
		method: .post
		url: c.api_url
		header: headers
		data: body_json
	}
	resp := req.do()!
	if resp.status_code != 200 {
		return error('API Error ${resp.status_code}: ${resp.body}')
	}
	return resp.body
}

fn build_assistant_content_json(parsed ParsedResponse) string {
	mut blocks := []string{}
	if parsed.text.len > 0 {
		blocks << '{"type":"text","text":"${escape_json_string(parsed.text)}"}'
	}
	for tu in parsed.tool_uses {
		blocks << '{"type":"tool_use","id":"${escape_json_string(tu.id)}","name":"${escape_json_string(tu.name)}","input":${build_tool_input_json(tu.input)}}'
	}
	if blocks.len == 0 {
		return ''
	}
	return '[' + blocks.join(',') + ']'
}

fn tool_result_is_error(result string) bool {
	trimmed := result.trim_space()
	if trimmed.len == 0 {
		return false
	}
	return trimmed.starts_with('Error:') || trimmed.starts_with('Exit code:')
		|| trimmed.contains('\nError:') || trimmed.contains('\nExit code:')
		|| trimmed.contains('Not connected. Run `v-browser connect`')
}

fn build_tool_results_json(tools []ToolUse, results []string) string {
	mut parts := []string{}
	for i, tu in tools {
		content := if i < results.len { results[i] } else { '' }
		is_error := if tool_result_is_error(content) { 'true' } else { 'false' }
		parts << '{"type":"tool_result","tool_use_id":"${escape_json_string(tu.id)}","content":"${escape_json_string(content)}","is_error":${is_error}}'
	}
	return '[' + parts.join(',') + ']'
}

fn (mut c ApiClient) execute_tool_uses(tools []ToolUse) []string {
	mut results := []string{}
	for tu in tools {
		result := c.executor.execute_tool(tu.name, tu.input)
		results << result
	}
	return results
}

fn (mut c ApiClient) chat(prompt string) !string {
	c.add_message('user', prompt)
	if !c.enable_tools {
		response_body := c.send_api_request(c.build_request_json())!
		parsed := parse_response_full(response_body)
		c.add_message('assistant', parsed.text)
		return parsed.text
	}

	effective_max := if c.max_rounds > 0 { c.max_rounds } else { 8 }
	mut rounds := 0
	for rounds <= effective_max {
		response_body := c.send_api_request(c.build_request_json())!
		parsed := parse_response_full(response_body)
		if parsed.tool_uses.len == 0 {
			c.add_message('assistant', parsed.text)
			return parsed.text
		}

		assistant_content_json := build_assistant_content_json(parsed)
		c.messages << ChatMessage{
			role:         'assistant'
			content:      parsed.text
			content_json: assistant_content_json
		}

		tool_results := c.execute_tool_uses(parsed.tool_uses)
		c.messages << ChatMessage{
			role:         'user'
			content:      ''
			content_json: build_tool_results_json(parsed.tool_uses, tool_results)
		}
		rounds++
	}
	return error('达到最大工具调用轮数')
}
