module main

fn hex_digit_value(ch u8) int {
	return match ch {
		`0`...`9` { int(ch - `0`) }
		`a`...`f` { int(ch - `a`) + 10 }
		`A`...`F` { int(ch - `A`) + 10 }
		else { -1 }
	}
}

fn parse_json_hex_quad(s string, start int) int {
	if start < 0 || start + 4 > s.len {
		return -1
	}
	mut value := 0
	for i := 0; i < 4; i++ {
		digit := hex_digit_value(s[start + i])
		if digit < 0 {
			return -1
		}
		value = value * 16 + digit
	}
	return value
}

fn unicode_codepoint_to_string(codepoint int) string {
	mut chars := []rune{}
	chars << rune(codepoint)
	return chars.string()
}

pub struct ParsedResponse {
pub mut:
	text             string
	tool_uses        []ToolUse
	stop_reason      string
	raw_content_json string
}

fn decode_json_string(s string) string {
	if !s.contains('\\') {
		return s
	}
	mut result := ''
	mut segment_start := 0
	mut i := 0
	for i < s.len {
		if s[i] == `\\` && i + 1 < s.len {
			if segment_start < i {
				result += s[segment_start..i]
			}
			match s[i + 1] {
				`n` {
					result += '\n'
					i += 2
				}
				`t` {
					result += '\t'
					i += 2
				}
				`r` {
					result += '\r'
					i += 2
				}
				`"` {
					result += '"'
					i += 2
				}
				`\\` {
					result += '\\'
					i += 2
				}
				`/` {
					result += '/'
					i += 2
				}
				`u` {
					codepoint := parse_json_hex_quad(s, i + 2)
					if codepoint >= 0 {
						result += unicode_codepoint_to_string(codepoint)
						i += 6
					} else {
						result += s[i..i + 2]
						i += 2
					}
				}
				else {
					result += s[i + 1].ascii_str()
					i += 2
				}
			}
			segment_start = i
		} else {
			i++
		}
	}
	if segment_start < s.len {
		result += s[segment_start..]
	}
	return result
}

fn parse_json_string_object(json_str string) map[string]string {
	mut result := map[string]string{}
	mut pos := 1
	for pos < json_str.len - 1 {
		for pos < json_str.len && json_str[pos] in [u8(` `), `,`, `\n`, `\t`, `\r`] {
			pos++
		}
		if pos >= json_str.len - 1 {
			break
		}
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
		for pos < json_str.len && json_str[pos] in [u8(`:`), ` `, `\t`, `\n`, `\r`] {
			pos++
		}
		if pos >= json_str.len {
			break
		}
		ch := json_str[pos]
		if ch == `"` {
			pos++
			val_end := find_json_string_terminator(json_str, pos)
			if val_end < pos {
				break
			}
			result[key] = decode_json_string(json_str[pos..val_end])
			pos = val_end + 1
		} else if ch == `{` || ch == `[` {
			end := find_matching_bracket(json_str, pos)
			if end > pos {
				result[key] = json_str[pos..end + 1]
				pos = end + 1
			} else {
				break
			}
		} else {
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
				start := abs_pos + text_idx + 8
				end := find_json_string_terminator(content_json, start)
				if end > start {
					result += decode_json_string(content_json[start..end])
					search_pos = end + 1
					continue
				}
			}
			search_pos = abs_pos + 12
		} else {
			break
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
					continue
				}
			}
			search_pos = abs_pos + 17
		} else {
			break
		}
	}
	return tools
}

fn parse_response_full(body string) ParsedResponse {
	mut result := ParsedResponse{}
	result.stop_reason = extract_json_string_value(body, 'stop_reason')
	content_json := extract_content_array(body)
	if content_json.len > 0 {
		result.raw_content_json = content_json
		result.text = extract_text_blocks(content_json)
	}
	if result.stop_reason == 'tool_use' || body.contains('"type":"tool_use"') {
		result.tool_uses = extract_tool_use_blocks(body)
	}
	if result.text.len == 0 && result.tool_uses.len == 0 {
		result.text = extract_json_string_value(body, 'text')
		if result.text.len > 0 {
			result.text = decode_json_string(result.text)
		}
	}
	return result
}
