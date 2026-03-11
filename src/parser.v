module main

fn parse_sse_response(body string) string {
	lines := body.split('\n')
	mut result := ''

	for line in lines {
		trimmed := line.trim_space()
		if trimmed.starts_with('data:') {
			json_str := trimmed[5..].trim_space()

			if json_str.contains('"type":"content_block_delta"') {
				text := extract_json_string_value(json_str, 'text')
				if text.len > 0 {
					result += decode_json_string(text)
				}
			}
		}
	}
	return result
}

fn parse_anthropic_response(body string) string {
	if body.contains('"type":"content_block_delta"') {
		return parse_sse_response(body)
	}

	pattern := '"text":"'
	if idx := body.index(pattern) {
		start := idx + pattern.len
		end := find_json_string_terminator(body, start)
		if end > start {
			return decode_json_string(body[start..end])
		}
	}
	return ''
}

// parse_cache_stats extracts cache token usage from an Anthropic API response body.
// Returns (cache_read, cache_creation) token counts; both 0 if not present.
fn parse_cache_stats(body string) (int, int) {
	mut cache_read := 0
	mut cache_creation := 0
	if idx := body.index('"cache_read_input_tokens":') {
		mut p := idx + '"cache_read_input_tokens":'.len
		for p < body.len && body[p] == ` ` {
			p++
		}
		mut e := p
		for e < body.len && body[e] >= `0` && body[e] <= `9` {
			e++
		}
		if e > p {
			cache_read = body[p..e].int()
		}
	}
	if idx := body.index('"cache_creation_input_tokens":') {
		mut p := idx + '"cache_creation_input_tokens":'.len
		for p < body.len && body[p] == ` ` {
			p++
		}
		mut e := p
		for e < body.len && body[e] >= `0` && body[e] <= `9` {
			e++
		}
		if e > p {
			cache_creation = body[p..e].int()
		}
	}
	return cache_read, cache_creation
}

// --- Full Response Parsing (with tool_use support) ---

pub struct ParsedResponse {
pub mut:
	text             string
	thinking         string
	tool_uses        []ToolUse
	stop_reason      string
	raw_content_json string
}

// utf8_safe_truncate truncates s to at most max_bytes bytes, ensuring the result
// ends at a valid UTF-8 character boundary (avoids splitting multi-byte chars).
fn utf8_safe_truncate(s string, max_bytes int) string {
	if s.len <= max_bytes {
		return s
	}
	// Walk back from max_bytes until we find a byte that is either ASCII (< 0x80)
	// or a UTF-8 lead byte (>= 0xC0). Continuation bytes are 0x80-0xBF.
	mut end := max_bytes
	for end > 0 {
		b := s[end - 1]
		if b < 0x80 || b >= 0xC0 {
			break
		}
		end--
	}
	return s[..end]
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
			} // backspace
			0x0C {
				result << `\\`
				result << `f`
			} // form feed
			else {
				if ch < 0x20 {
					// Other control characters: \u00XX
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
	// Find "key" then skip optional whitespace, colon, optional whitespace, then opening quote
	pattern := '"${key}"'
	if idx := json_str.index(pattern) {
		mut p := idx + pattern.len
		// Skip whitespace
		for p < json_str.len && json_str[p] in [u8(` `), `\t`, `\n`, `\r`] {
			p++
		}
		// Expect colon
		if p >= json_str.len || json_str[p] != `:` {
			return ''
		}
		p++
		// Skip whitespace
		for p < json_str.len && json_str[p] in [u8(` `), `\t`, `\n`, `\r`] {
			p++
		}
		// Expect opening quote
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

fn extract_content_array(body string) string {
	target := '"content":['
	if idx := body.index(target) {
		arr_start := idx + target.len - 1
		arr_end := find_matching_bracket(body, arr_start)
		if arr_end > arr_start {
			return body[arr_start..arr_end + 1]
		}
	}
	return ''
}

fn extract_text_blocks(content_json string) string {
	mut result := ''
	mut search_pos := 0

	for search_pos < content_json.len {
		remaining := content_json[search_pos..]

		if type_idx := remaining.index('"type":"text"') {
			abs_pos := search_pos + type_idx
			after_type := content_json[abs_pos..]

			if text_idx := after_type.index('"text":"') {
				value_start := abs_pos + text_idx + 8
				end := find_json_string_terminator(content_json, value_start)
				if end > value_start {
					result += decode_json_string(content_json[value_start..end])
				}
				search_pos = end + 1
			} else {
				search_pos = abs_pos + 13
			}
		} else {
			break
		}
	}
	return result
}

fn extract_thinking_blocks(content_json string) string {
	mut result := ''
	mut search_pos := 0

	for search_pos < content_json.len {
		remaining := content_json[search_pos..]

		if type_idx := remaining.index('"type":"thinking"') {
			abs_pos := search_pos + type_idx
			after_type := content_json[abs_pos..]

			if text_idx := after_type.index('"thinking":"') {
				value_start := abs_pos + text_idx + 12
				end := find_json_string_terminator(content_json, value_start)
				if end > value_start {
					result += decode_json_string(content_json[value_start..end])
				}
				search_pos = end + 1
			} else {
				search_pos = abs_pos + 16
			}
		} else {
			break
		}
	}
	return result
}

// decode_json_string decodes JSON string escape sequences including \uXXXX unicode escapes
fn decode_json_string(s string) string {
	if !s.contains('\\') {
		return s
	}
	mut result := []u8{}
	mut i := 0
	for i < s.len {
		if s[i] == `\\` && i + 1 < s.len {
			match s[i + 1] {
				`n` {
					result << `\n`
					i += 2
				}
				`t` {
					result << `\t`
					i += 2
				}
				`r` {
					result << `\r`
					i += 2
				}
				`"` {
					result << `"`
					i += 2
				}
				`\\` {
					result << `\\`
					i += 2
				}
				`/` {
					result << `/`
					i += 2
				}
				`u` {
					// \uXXXX unicode escape
					if i + 5 < s.len {
						hex := s[i + 2..i + 6]
						codepoint := hex.parse_uint(16, 16) or { 0 }
						if codepoint > 0 {
							// Encode as UTF-8
							if codepoint < 0x80 {
								result << u8(codepoint)
							} else if codepoint < 0x800 {
								result << u8(0xC0 | (codepoint >> 6))
								result << u8(0x80 | (codepoint & 0x3F))
							} else {
								result << u8(0xE0 | (codepoint >> 12))
								result << u8(0x80 | ((codepoint >> 6) & 0x3F))
								result << u8(0x80 | (codepoint & 0x3F))
							}
						}
						i += 6
					} else {
						result << s[i]
						i++
					}
				}
				else {
					result << s[i + 1]
					i += 2
				}
			}
		} else {
			result << s[i]
			i++
		}
	}
	return result.bytestr()
}

fn parse_json_string_object(json_str string) map[string]string {
	mut result := map[string]string{}
	mut pos := 1

	for pos < json_str.len - 1 {
		// Skip whitespace and commas
		for pos < json_str.len && json_str[pos] in [u8(` `), `,`, `\n`, `\t`, `\r`] {
			pos++
		}
		if pos >= json_str.len - 1 {
			break
		}

		// Expect "key"
		if json_str[pos] != `"` {
			break
		}
		pos++
		key_end := find_json_string_terminator(json_str, pos)
		if key_end < pos {
			break
		}
		key := decode_json_string(json_str[pos..key_end])
		pos = key_end + 1

		// Skip : and whitespace
		for pos < json_str.len && json_str[pos] in [u8(`:`), ` `, `\t`, `\n`, `\r`] {
			pos++
		}

		if pos >= json_str.len {
			break
		}

		ch := json_str[pos]
		if ch == `"` {
			// String value
			pos++
			val_end := find_json_string_terminator(json_str, pos)
			if val_end < pos {
				break
			}
			value := decode_json_string(json_str[pos..val_end])
			result[key] = value
			pos = val_end + 1
		} else if ch == `{` || ch == `[` {
			// Nested object or array — extract raw JSON
			end := find_matching_bracket(json_str, pos)
			if end > pos {
				result[key] = json_str[pos..end + 1]
				pos = end + 1
			} else {
				break
			}
		} else {
			// Number, boolean, null — read until delimiter
			mut val_end := pos
			for val_end < json_str.len
				&& json_str[val_end] !in [u8(`,`), `}`, `]`, ` `, `\n`, `\t`, `\r`] {
				val_end++
			}
			result[key] = json_str[pos..val_end]
			pos = val_end
		}
	}
	return result
}

fn extract_tool_use_blocks(body string) []ToolUse {
	mut tools := []ToolUse{}
	mut search_pos := 0

	for search_pos < body.len {
		remaining := body[search_pos..]

		if type_idx := remaining.index('"type":"tool_use"') {
			abs_pos := search_pos + type_idx

			// Find enclosing { for this tool_use block
			mut block_start := abs_pos - 1
			for block_start >= 0 && body[block_start] != `{` {
				block_start--
			}

			if block_start >= 0 {
				block_end := find_matching_bracket(body, block_start)
				if block_end > block_start {
					block := body[block_start..block_end + 1]

					mut tu := ToolUse{}
					tu.id = extract_json_string_value(block, 'id')
					tu.name = extract_json_string_value(block, 'name')

					// Extract input object
					if input_idx := block.index('"input":') {
						mut obj_start := input_idx + 8
						for obj_start < block.len && block[obj_start] in [u8(` `), `\t`, `\n`, `\r`] {
							obj_start++
						}
						if obj_start < block.len && block[obj_start] == `{` {
							input_end := find_matching_bracket(block, obj_start)
							if input_end > obj_start {
								input_json := block[obj_start..input_end + 1]
								tu.input = parse_json_string_object(input_json)
							}
						}
					}

					if tu.id.len > 0 && tu.name.len > 0 {
						tools << tu
					}
					search_pos = block_end + 1
				} else {
					search_pos = abs_pos + 17
				}
			} else {
				search_pos = abs_pos + 17
			}
		} else {
			break
		}
	}
	return tools
}

// parse_sse_full parses accumulated SSE event data for tool_use blocks, stop_reason,
// and builds raw_content_json for conversation history.
// Text/thinking content is NOT extracted here (already streamed in real-time).
fn parse_sse_full(sse_body string) ParsedResponse {
	mut result := ParsedResponse{}
	mut content_blocks := []string{}
	mut current_tool_id := ''
	mut current_tool_name := ''
	mut current_input_json := ''
	mut in_tool_block := false

	lines := sse_body.split('\n')
	for line in lines {
		trimmed := line.trim_space()
		if !trimmed.starts_with('data:') {
			continue
		}
		json_str := trimmed[5..].trim_space()
		if json_str == '[DONE]' {
			continue
		}

		// Extract stop_reason from message_delta
		if json_str.contains('"type":"message_delta"') {
			sr := extract_json_string_value(json_str, 'stop_reason')
			if sr.len > 0 {
				result.stop_reason = sr
			}
			continue
		}

		// Track content_block_start
		if json_str.contains('"type":"content_block_start"') {
			if json_str.contains('"type":"tool_use"') {
				in_tool_block = true
				current_tool_id = extract_json_string_value(json_str, 'id')
				current_tool_name = extract_json_string_value(json_str, 'name')
				current_input_json = ''
			} else if json_str.contains('"type":"text"') {
				in_tool_block = false
			} else if json_str.contains('"type":"thinking"') {
				in_tool_block = false
			}
			continue
		}

		// Accumulate tool input from input_json_delta
		if in_tool_block && json_str.contains('"type":"input_json_delta"') {
			pj := extract_json_string_value(json_str, 'partial_json')
			if pj.len > 0 {
				current_input_json += decode_json_string(pj)
			}
			continue
		}

		// content_block_stop: finalize tool_use block
		if json_str.contains('"type":"content_block_stop"') {
			if in_tool_block && current_tool_id.len > 0 {
				mut tu := ToolUse{}
				tu.id = current_tool_id
				tu.name = current_tool_name
				if current_input_json.len > 0 {
					tu.input = parse_json_string_object(current_input_json)
				}
				result.tool_uses << tu

				// Build content block JSON for conversation history
				input_str := if current_input_json.len > 0 {
					current_input_json
				} else {
					'{}'
				}
				content_blocks << '{"type":"tool_use","id":"${current_tool_id}","name":"${current_tool_name}","input":${input_str}}'
				in_tool_block = false
				current_tool_id = ''
				current_tool_name = ''
				current_input_json = ''
			}
			continue
		}

		// Accumulate text blocks for raw_content_json
		if json_str.contains('"type":"content_block_delta"') {
			if json_str.contains('"type":"text_delta"') {
				text_val := extract_json_string_value(json_str, 'text')
				if text_val.len > 0 {
					result.text += decode_json_string(text_val)
				}
			} else if json_str.contains('"type":"thinking_delta"') {
				thinking_val := extract_json_string_value(json_str, 'thinking')
				if thinking_val.len > 0 {
					result.thinking += decode_json_string(thinking_val)
				}
			}
		}
	}

	// Build raw_content_json for conversation history
	if result.text.len > 0 || content_blocks.len > 0 || result.thinking.len > 0 {
		mut parts := []string{}
		if result.thinking.len > 0 {
			escaped_thinking := escape_json_string(result.thinking)
			parts << '{"type":"thinking","thinking":"${escaped_thinking}"}'
		}
		if result.text.len > 0 {
			escaped_text := escape_json_string(result.text)
			parts << '{"type":"text","text":"${escaped_text}"}'
		}
		for block in content_blocks {
			parts << block
		}
		result.raw_content_json = '[' + parts.join(',') + ']'
	}

	return result
}

fn parse_response_full(body string) ParsedResponse {
	mut result := ParsedResponse{}

	// SSE responses: fall back to old parser
	if body.contains('"type":"content_block_delta"') {
		result.text = parse_sse_response(body)
		return result
	}

	// Extract stop_reason
	result.stop_reason = extract_json_string_value(body, 'stop_reason')

	// Extract content array
	content_json := extract_content_array(body)
	if content_json.len > 0 {
		result.raw_content_json = content_json
		result.text = extract_text_blocks(content_json)
		result.thinking = extract_thinking_blocks(content_json)
	}

	// Extract tool_use blocks
	if result.stop_reason == 'tool_use' || body.contains('"type":"tool_use"') {
		result.tool_uses = extract_tool_use_blocks(body)
	}

	// Fallback: use old parser if nothing found
	if result.text.len == 0 && result.tool_uses.len == 0 {
		result.text = parse_anthropic_response(body)
	}

	return result
}
