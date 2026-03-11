module main

fn new_test_acp_server() AcpServer {
	mut cfg := default_config()
	cfg.api_key = 'test-key'
	mut client := new_api_client(cfg)
	client.enable_tools = false
	return new_acp_server(client)
}

fn test_extract_json_raw_value_id() {
	req := '{"jsonrpc":"2.0","id":"abc-1","method":"initialize","params":{}}'
	assert extract_json_raw_value(req, 'id') == '"abc-1"'
}

fn test_extract_prompt_text_from_json_array() {
	raw := '[{"type":"text","text":"hello"},{"type":"text","text":"world"}]'
	assert extract_prompt_text_from_json(raw) == 'hello\nworld'
}

fn test_acp_initialize_request() {
	mut server := new_test_acp_server()
	resp := server.handle_request('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}')
	assert resp.contains('"id":1')
	assert resp.contains('"protocolVersion":1')
	assert resp.contains('"name":"minimax-v"')
}

fn test_acp_new_session_cancel_and_prompt() {
	mut server := new_test_acp_server()
	new_resp := server.handle_request('{"jsonrpc":"2.0","id":10,"method":"newSession","params":{"cwd":"."}}')
	session_id := extract_json_string_value(new_resp, 'sessionId')
	assert session_id.len > 0

	cancel_resp := server.handle_request('{"jsonrpc":"2.0","id":11,"method":"cancel","params":{"sessionId":"${session_id}"}}')
	assert cancel_resp.contains('"id":11')

	prompt_resp := server.handle_request('{"jsonrpc":"2.0","id":12,"method":"prompt","params":{"sessionId":"${session_id}","prompt":[{"type":"text","text":"ping"}]}}')
	assert prompt_resp.contains('"id":12')
	assert prompt_resp.contains('"stopReason":"cancelled"')
}

fn test_acp_unknown_method() {
	mut server := new_test_acp_server()
	resp := server.handle_request('{"jsonrpc":"2.0","id":99,"method":"unknownMethod","params":{}}')
	assert resp.contains('"code":-32601')
}
