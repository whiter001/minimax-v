module main

import net.http

// ChatMessage represents a single chat message.
pub struct ChatMessage {
pub mut:
	role         string
	content      string
	content_json string
}

// ToolUse represents a tool call request.
pub struct ToolUse {
pub mut:
	id    string
	name  string
	input map[string]string
}

// ParsedResponse represents a parsed API response.
pub struct ParsedResponse {
pub mut:
	text        string
	thinking    string
	tool_uses   []ToolUse
	stop_reason string
}

// StreamResult represents streaming API response result.
pub struct StreamResult {
	text     string
	thinking string
}

// ApiClient handles API communication with MiniMax.
@[heap]
pub struct ApiClient {
pub mut:
	api_key      string
	api_url      string
	model        string
	temperature  f64
	max_tokens   int
	token_limit  int
	enable_tools bool
	workspace    string
	messages     []ChatMessage
	mcp_service  &McpService
}

pub fn new_api_client(config Config, mcp &McpService) ApiClient {
	return ApiClient{
		api_key:      config.api_key
		api_url:      config.api_url
		model:        config.model
		temperature:  config.temperature
		max_tokens:   config.max_tokens
		token_limit:  config.token_limit
		enable_tools: config.enable_tools
		workspace:    config.workspace
		messages:     []ChatMessage{}
		mcp_service:  mcp
	}
}

fn (mut c ApiClient) add_message(role string, content string) {
	c.messages << ChatMessage{
		role:    role
		content: content
	}
}

fn (mut c ApiClient) clear_messages() {
	c.messages.clear()
}

// chat sends a message and returns the response text.
pub fn (mut c ApiClient) chat(message string) string {
	c.add_message('user', message)

	// Simple HTTP POST request
	req := http.post_json(c.api_url, '{"model":"${c.model}","max_tokens":${c.max_tokens}}') or {
		c.add_message('assistant', 'Error: ${err.msg()}')
		return 'Error: ${err.msg()}'
	}

	// Parse simple response
	text := c.parse_simple_response(req.body)
	c.add_message('assistant', text)
	return text
}

fn (c &ApiClient) parse_simple_response(body string) string {
	// Simple JSON parsing - look for content field
	if idx := body.index('"content":"') {
		start := idx + 11
		mut end := start
		for end < body.len && body[end] != `"` {
			end++
		}
		return body[start..end].replace('\\n', '\n').replace('\\"', '"')
	}
	if idx := body.index('"text":"') {
		start := idx + 8
		mut end := start
		for end < body.len && body[end] != `"` {
			end++
		}
		return body[start..end].replace('\\n', '\n').replace('\\"', '"')
	}
	return 'No response content'
}
