module main

// ===== escape_json_string =====

fn test_escape_json_string_basic() {
	assert escape_json_string('hello') == 'hello'
}

fn test_escape_json_string_quotes() {
	assert escape_json_string('say "hi"') == 'say \\"hi\\"'
}

fn test_escape_json_string_newlines() {
	assert escape_json_string('line1\nline2') == 'line1\\nline2'
}

fn test_escape_json_string_tabs() {
	assert escape_json_string('col1\tcol2') == 'col1\\tcol2'
}

fn test_escape_json_string_backslash() {
	assert escape_json_string('path\\to\\file') == 'path\\\\to\\\\file'
}

fn test_escape_json_string_mixed() {
	assert escape_json_string('a"b\nc\\d') == 'a\\"b\\nc\\\\d'
}

fn test_escape_json_string_empty() {
	assert escape_json_string('') == ''
}

fn test_escape_json_string_control_chars() {
	// carriage return
	assert escape_json_string('\r') == '\\r'
}

// ===== extract_json_string_value =====

fn test_extract_json_string_value_simple() {
	json := '{"name":"hello","age":"25"}'
	assert extract_json_string_value(json, 'name') == 'hello'
	assert extract_json_string_value(json, 'age') == '25'
}

fn test_extract_json_string_value_missing() {
	json := '{"name":"hello"}'
	assert extract_json_string_value(json, 'missing') == ''
}

fn test_extract_json_string_value_escaped_quotes() {
	json := '{"text":"say \\"hi\\""}'
	assert extract_json_string_value(json, 'text') == 'say \\"hi\\"'
}

fn test_extract_json_string_value_handles_trailing_backslashes() {
	json := '{"path":"C:\\\\Users\\\\test\\\\","next":"ok"}'
	assert extract_json_string_value(json, 'path') == 'C:\\\\Users\\\\test\\\\'
}

fn test_extract_json_string_value_empty() {
	assert extract_json_string_value('', 'key') == ''
}

fn test_extract_json_string_value_stop_reason() {
	json := '{"type":"message_delta","delta":{"stop_reason":"tool_use"}}'
	assert extract_json_string_value(json, 'stop_reason') == 'tool_use'
}

// ===== find_matching_bracket =====

fn test_find_matching_bracket_simple_object() {
	s := '{"a":1}'
	assert find_matching_bracket(s, 0) == 6
}

fn test_find_matching_bracket_simple_array() {
	s := '[1,2,3]'
	assert find_matching_bracket(s, 0) == 6
}

fn test_find_matching_bracket_nested() {
	s := '{"a":{"b":1}}'
	assert find_matching_bracket(s, 0) == s.len - 1
}

fn test_find_matching_bracket_with_string() {
	s := '{"a":"}"}' // closing brace inside string
	assert find_matching_bracket(s, 0) == 8
}

fn test_find_matching_bracket_out_of_bounds() {
	assert find_matching_bracket('', 0) == -1
	assert find_matching_bracket('{', 5) == -1
}

// ===== extract_content_array =====

fn test_extract_content_array_basic() {
	body := '{"id":"msg_1","content":[{"type":"text","text":"hello"}],"stop_reason":"end_turn"}'
	result := extract_content_array(body)
	assert result == '[{"type":"text","text":"hello"}]'
}

fn test_extract_content_array_missing() {
	body := '{"id":"msg_1"}'
	result := extract_content_array(body)
	assert result == ''
}

// ===== extract_text_blocks =====

fn test_extract_text_blocks_single() {
	content := '[{"type":"text","text":"hello world"}]'
	assert extract_text_blocks(content) == 'hello world'
}

fn test_extract_text_blocks_multiple() {
	content := '[{"type":"text","text":"part1"},{"type":"text","text":"part2"}]'
	assert extract_text_blocks(content) == 'part1part2'
}

fn test_extract_text_blocks_with_tool_use() {
	content := '[{"type":"text","text":"I will help"},{"type":"tool_use","id":"tu_1","name":"read_file","input":{"path":"test.txt"}}]'
	assert extract_text_blocks(content) == 'I will help'
}

fn test_extract_text_blocks_empty() {
	assert extract_text_blocks('[]') == ''
	assert extract_text_blocks('') == ''
}

fn test_extract_text_blocks_escaped_newline() {
	content := '[{"type":"text","text":"line1\\nline2"}]'
	assert extract_text_blocks(content) == 'line1\nline2'
}

fn test_extract_text_blocks_decodes_unicode_and_backslashes() {
	content := '[{"type":"text","text":"\\u4e2d\\u6587 C:\\\\tmp\\\\file.txt"}]'
	assert extract_text_blocks(content) == '中文 C:\\tmp\\file.txt'.replace('\\\\',
		'\\')
}

// ===== extract_thinking_blocks =====

fn test_extract_thinking_blocks_single() {
	content := '[{"type":"thinking","thinking":"let me think about this"}]'
	assert extract_thinking_blocks(content) == 'let me think about this'
}

fn test_extract_thinking_blocks_with_text() {
	content := '[{"type":"thinking","thinking":"reasoning..."},{"type":"text","text":"answer"}]'
	assert extract_thinking_blocks(content) == 'reasoning...'
}

fn test_extract_thinking_blocks_none() {
	content := '[{"type":"text","text":"just text"}]'
	assert extract_thinking_blocks(content) == ''
}

// ===== parse_json_string_object =====

fn test_parse_json_string_object_basic() {
	json := '{"path":"/tmp/test.txt","content":"hello"}'
	result := parse_json_string_object(json)
	assert result['path'] == '/tmp/test.txt'
	assert result['content'] == 'hello'
}

fn test_parse_json_string_object_empty() {
	result := parse_json_string_object('{}')
	assert result.len == 0
}

fn test_parse_json_string_object_number_value() {
	json := '{"name":"test","count":42}'
	result := parse_json_string_object(json)
	assert result['name'] == 'test'
	assert result['count'] == '42'
}

fn test_parse_json_string_object_boolean_value() {
	json := '{"name":"test","active":true}'
	result := parse_json_string_object(json)
	assert result['active'] == 'true'
}

fn test_parse_json_string_object_escaped_key_and_value() {
	json := '{"param\\"name":"C:\\\\tmp\\\\file.txt"}'
	result := parse_json_string_object(json)
	assert result['param"name'] == 'C:\\tmp\\file.txt'.replace('\\\\', '\\')
}

// ===== extract_tool_use_blocks =====

fn test_extract_tool_use_blocks_single() {
	body := '{"content":[{"type":"tool_use","id":"tu_1","name":"read_file","input":{"path":"/tmp/test.txt"}}]}'
	tools := extract_tool_use_blocks(body)
	assert tools.len == 1
	assert tools[0].id == 'tu_1'
	assert tools[0].name == 'read_file'
	assert tools[0].input['path'] == '/tmp/test.txt'
}

fn test_extract_tool_use_blocks_multiple() {
	body := '{"content":[{"type":"tool_use","id":"tu_1","name":"read_file","input":{"path":"a.txt"}},{"type":"tool_use","id":"tu_2","name":"list_dir","input":{"path":"."}}]}'
	tools := extract_tool_use_blocks(body)
	assert tools.len == 2
	assert tools[0].name == 'read_file'
	assert tools[1].name == 'list_dir'
}

fn test_extract_tool_use_blocks_none() {
	body := '{"content":[{"type":"text","text":"no tools"}]}'
	tools := extract_tool_use_blocks(body)
	assert tools.len == 0
}

// ===== parse_response_full =====

fn test_parse_response_full_text_only() {
	body := '{"id":"msg_1","content":[{"type":"text","text":"Hello!"}],"stop_reason":"end_turn"}'
	result := parse_response_full(body)
	assert result.text == 'Hello!'
	assert result.stop_reason == 'end_turn'
	assert result.tool_uses.len == 0
}

fn test_parse_response_full_with_thinking() {
	body := '{"id":"msg_1","content":[{"type":"thinking","thinking":"let me think"},{"type":"text","text":"answer"}],"stop_reason":"end_turn"}'
	result := parse_response_full(body)
	assert result.text == 'answer'
	assert result.thinking == 'let me think'
	assert result.stop_reason == 'end_turn'
}

fn test_parse_response_full_tool_use() {
	body := '{"id":"msg_1","content":[{"type":"text","text":"I will read the file"},{"type":"tool_use","id":"tu_1","name":"read_file","input":{"path":"test.txt"}}],"stop_reason":"tool_use"}'
	result := parse_response_full(body)
	assert result.text == 'I will read the file'
	assert result.stop_reason == 'tool_use'
	assert result.tool_uses.len == 1
	assert result.tool_uses[0].name == 'read_file'
}

// ===== parse_sse_full =====

fn test_parse_sse_full_text_only() {
	sse :=
		'data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}\n' +
		'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}\n' +
		'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" world"}}\n' +
		'data: {"type":"content_block_stop","index":0}\n' +
		'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}\n' + 'data: [DONE]\n'
	result := parse_sse_full(sse)
	assert result.text == 'Hello world'
	assert result.stop_reason == 'end_turn'
	assert result.tool_uses.len == 0
}

fn test_parse_sse_full_with_thinking() {
	sse :=
		'data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}\n' +
		'data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"I should"}}\n' +
		'data: {"type":"content_block_stop","index":0}\n' +
		'data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}\n' +
		'data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Answer"}}\n' +
		'data: {"type":"content_block_stop","index":1}\n' +
		'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}\n'
	result := parse_sse_full(sse)
	assert result.thinking == 'I should'
	assert result.text == 'Answer'
	assert result.stop_reason == 'end_turn'
}

fn test_parse_sse_full_tool_use() {
	sse :=
		'data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}\n' +
		'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Reading file"}}\n' +
		'data: {"type":"content_block_stop","index":0}\n' +
		'data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"tu_1","name":"read_file","input":{}}}\n' +
		'data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"path\\":\\"test.txt\\"}"}}\n' +
		'data: {"type":"content_block_stop","index":1}\n' +
		'data: {"type":"message_delta","delta":{"stop_reason":"tool_use"}}\n'
	result := parse_sse_full(sse)
	assert result.text == 'Reading file'
	assert result.stop_reason == 'tool_use'
	assert result.tool_uses.len == 1
	assert result.tool_uses[0].id == 'tu_1'
	assert result.tool_uses[0].name == 'read_file'
	assert result.tool_uses[0].input['path'] == 'test.txt'
}

fn test_parse_sse_full_tool_use_decodes_unicode_partial_json() {
	sse :=
		'data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"tu_1","name":"write_file","input":{}}}\n' +
		'data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"path\\":\\"\\u4e2d.txt\\",\\"note\\":\\"line1\\\\nline2\\"}"}}\n' +
		'data: {"type":"content_block_stop","index":0}\n' +
		'data: {"type":"message_delta","delta":{"stop_reason":"tool_use"}}\n'
	result := parse_sse_full(sse)
	assert result.tool_uses.len == 1
	assert result.tool_uses[0].input['path'] == '中.txt'
	assert result.tool_uses[0].input['note'] == 'line1\nline2'
}

fn test_parse_sse_full_builds_raw_content_json() {
	sse :=
		'data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}\n' +
		'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hi"}}\n' +
		'data: {"type":"content_block_stop","index":0}\n' +
		'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}\n'
	result := parse_sse_full(sse)
	assert result.raw_content_json.len > 0
	assert result.raw_content_json.contains('"type":"text"')
}

// ===== parse_sse_response (legacy) =====

fn test_parse_sse_response_basic() {
	body :=
		'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}\n' +
		'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" there"}}\n'
	assert parse_sse_response(body) == 'Hello there'
}

fn test_parse_sse_response_done() {
	body := 'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}\ndata: [DONE]\n'
	assert parse_sse_response(body) == 'ok'
}

// ===== parse_anthropic_response =====

fn test_parse_anthropic_response_json() {
	body := '{"content":[{"type":"text","text":"Hello!"}]}'
	assert parse_anthropic_response(body) == 'Hello!'
}

fn test_parse_anthropic_response_decodes_unicode() {
	body := '{"content":[{"type":"text","text":"\\u4e2d\\u6587"}]}'
	assert parse_anthropic_response(body) == '中文'
}
