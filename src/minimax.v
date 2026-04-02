module minimax

import os
import net.http
import encoding.base64
import time

// =============================================================================
// Minimax API Client (using net.http for HTTP)
// =============================================================================

@[heap]
pub struct Client {
	api_key string
	host    string
}

pub fn new_client(api_key string, host string) Client {
	return Client{
		api_key: api_key
		host:    host
	}
}

// Coding Plan API host (for web_search and understand_image)
const default_coding_plan_host = 'https://api.minimax.chat'

fn get_coding_plan_client() Client {
	api_key := os.getenv('MINIMAX_API_KEY')
	mut host := os.getenv('MINIMAX_API_HOST')
	if host.len == 0 {
		host = default_coding_plan_host
	}
	return new_client(api_key, host)
}

// =============================================================================
// HTTP Request Helper (using net.http)
// =============================================================================

fn http_post(url string, api_key string, json_body string) !string {
	mut h := http.new_header()
	h.add(.authorization, 'Bearer ${api_key}')
	h.add(.content_type, 'application/json')

	mut req := http.Request{
		method: .post
		url: url
		header: h
		data: json_body
		read_timeout: 60 * time.second
		write_timeout: 30 * time.second
	}

	resp := req.do()!
	if resp.status_code < 200 || resp.status_code >= 300 {
		return error('HTTP ${resp.status_code}: ${resp.body}')
	}

	return resp.body
}

fn http_get(url string, api_key string) !string {
	mut h := http.new_header()
	h.add(.authorization, 'Bearer ${api_key}')

	mut req := http.Request{
		method: .get
		url: url
		header: h
		read_timeout: 60 * time.second
		write_timeout: 30 * time.second
	}

	resp := req.do()!
	if resp.status_code < 200 || resp.status_code >= 300 {
		return error('HTTP ${resp.status_code}: ${resp.body}')
	}

	return resp.body
}

// =============================================================================
// JSON Parsing Helpers
// =============================================================================

fn parse_json_string_field(json string, key string) string {
	pattern := '"${key}"'
	if idx := json.index(pattern) {
		mut p := idx + pattern.len
		for p < json.len && json[p] in [u8(` `), `\t`, `\n`, `\r`] {
			p++
		}
		if p >= json.len || json[p] != `:` {
			return ''
		}
		p++
		for p < json.len && json[p] in [u8(` `), `\t`, `\n`, `\r`] {
			p++
		}
		if p >= json.len || json[p] != `"` {
			return ''
		}
		p++
		start := p
		mut end := start
		for end < json.len {
			if json[end] == `"` && (end == start || json[end - 1] != `\\`) {
				break
			}
			end++
		}
		if end > start {
			return json[start..end]
		}
	}
	return ''
}

fn parse_json_int_field(json string, key string) int {
	val := parse_json_string_field(json, key)
	if val.len > 0 {
		return val.int()
	}
	return 0
}

// =============================================================================
// API Methods
// =============================================================================

pub fn (c Client) text_to_audio(req TTSRequest) !map[string]string {
	body := '{"model":"${req.model}","text":"${escape_json(req.text)}","voice_setting":{"voice_id":"${req.voice_setting.voice_id}","speed":${req.voice_setting.speed},"vol":${req.voice_setting.vol},"pitch":${req.voice_setting.pitch},"emotion":"${req.voice_setting.emotion}"},"audio_setting":{"sample_rate":${req.audio_setting.sample_rate},"bitrate":${req.audio_setting.bitrate},"format":"${req.audio_setting.format}","channel":${req.audio_setting.channel}}}'

	resp := http_post(c.host + endpoint_t2a_v2, c.api_key, body)!
	return parse_response_map(resp)
}

pub fn (c Client) list_voices(voice_type string) !VoiceList {
	body := '{"voice_type":"${voice_type}"}'

	resp := http_post(c.host + endpoint_get_voice, c.api_key, body)!

	mut voice_list := VoiceList{}

	// Parse system_voice array - simple approach
	system_start := resp.index('"system_voice":[') or { return voice_list }
	arr_start := system_start + 15
	arr_end := find_matching_bracket(resp, arr_start - 1)
	if arr_end > arr_start {
		arr_content := resp[arr_start..arr_end]
		mut pos := 0
		for pos < arr_content.len {
			brace_idx := index_from(arr_content, '{', pos)
			if brace_idx < 0 {
				break
			}
			obj_end := find_matching_bracket(arr_content, brace_idx)
			if obj_end <= brace_idx {
				break
			}
			obj := arr_content[brace_idx..obj_end + 1]
			voice_id := parse_json_string_field(obj, 'voice_id')
			voice_name := parse_json_string_field(obj, 'voice_name')
			if voice_id.len > 0 {
				voice_list.system_voice << Voice{voice_id, voice_name}
			}
			pos = obj_end + 1
		}
	}

	// Parse voice_cloning array
	clone_start := resp.index('"voice_cloning":[') or { return voice_list }
	arr_start2 := clone_start + 17
	arr_end2 := find_matching_bracket(resp, arr_start2 - 1)
	if arr_end2 > arr_start2 {
		arr_content := resp[arr_start2..arr_end2]
		mut pos := 0
		for pos < arr_content.len {
			brace_idx := index_from(arr_content, '{', pos)
			if brace_idx < 0 {
				break
			}
			obj_end := find_matching_bracket(arr_content, brace_idx)
			if obj_end <= brace_idx {
				break
			}
			obj := arr_content[brace_idx..obj_end + 1]
			voice_id := parse_json_string_field(obj, 'voice_id')
			voice_name := parse_json_string_field(obj, 'voice_name')
			if voice_id.len > 0 {
				voice_list.voice_cloning << Voice{voice_id, voice_name}
			}
			pos = obj_end + 1
		}
	}

	return voice_list
}

fn find_matching_bracket(s string, start int) int {
	if start >= s.len {
		return -1
	}
	open_ch := s[start]
	close_ch := if open_ch == `[` { u8(`]`) } else { u8(`}`) }
	mut depth := 1
	mut i := start + 1
	for i < s.len {
		ch := s[i]
		if ch == `"` {
			i++
			for i < s.len && s[i] != `"` {
				if s[i] == `\\` {
					i++
				}
				i++
			}
		} else if ch == open_ch {
			depth++
		} else if ch == close_ch {
			depth--
			if depth == 0 {
				return i
			}
		}
		i++
	}
	return -1
}

pub fn (c Client) voice_clone(req VoiceCloneRequest) !map[string]string {
	body := '{"file_id":"${req.file_id}","voice_id":"${req.voice_id}","text":"${escape_json(req.text)}"}'

	resp := http_post(c.host + endpoint_voice_clone, c.api_key, body)!
	return parse_response_map(resp)
}

pub struct FileUpload {
pub:
	filename string
	data     string
	mimetype string
}

pub fn (c Client) upload_file(file_data string, filename string, mimetype string) !map[string]string {
	// Use net.http multipart form upload
	boundary := '----WebKitFormBoundary7MA4YWxkTrZu0gW'

	// 构建 multipart body
	mut body := '--${boundary}\r\n'
	body += 'Content-Disposition: form-data; name="file"; filename="${filename}"\r\n'
	body += 'Content-Type: ${mimetype}\r\n\r\n'
	body += file_data
	body += '\r\n'
	body += '--${boundary}\r\n'
	body += 'Content-Disposition: form-data; name="purpose"\r\n\r\n'
	body += 'voice_clone\r\n'
	body += '--${boundary}--\r\n'

	mut h := http.new_header()
	h.add(.authorization, 'Bearer ${c.api_key}')
	h.add(.content_type, 'multipart/form-data; boundary=${boundary}')

	mut req := http.Request{
		method: .post
		url: c.host + endpoint_files_upload
		header: h
		data: body
		read_timeout: 60 * time.second
		write_timeout: 30 * time.second
	}

	resp := req.do()!
	if resp.status_code < 200 || resp.status_code >= 300 {
		return error('Upload failed: ${resp.status_code}')
	}

	return parse_response_map(resp.body)
}

pub fn (c Client) generate_video(req VideoGenerationRequest) !map[string]string {
	mut body := '{"model":"${req.model}","prompt":"${escape_json(req.prompt)}"'
	if req.first_frame_image.len > 0 {
		body += ',"first_frame_image":"${escape_json(req.first_frame_image)}"'
	}
	if req.duration > 0 {
		body += ',"duration":${req.duration}'
	}
	if req.resolution.len > 0 {
		body += ',"resolution":"${escape_json(req.resolution)}"'
	}
	body += '}'

	resp := http_post(c.host + endpoint_video_generation, c.api_key, body)!
	return parse_response_map(resp)
}

pub fn (c Client) query_video(task_id string) !map[string]string {
	resp := http_get(c.host + endpoint_video_generation + '?task_id=' + task_id, c.api_key)!
	return parse_response_map(resp)
}

pub fn (c Client) retrieve_file(file_id string) !map[string]string {
	resp := http_get(c.host + endpoint_files_retrieve + '?file_id=' + file_id, c.api_key)!
	return parse_response_map(resp)
}

pub fn (c Client) generate_image(req ImageGenerationRequest) !map[string]string {
	body := '{"model":"${req.model}","prompt":"${escape_json(req.prompt)}","aspect_ratio":"${req.aspect_ratio}","n":${req.n},"prompt_optimizer":${req.prompt_optimizer}}'

	resp := http_post(c.host + endpoint_image_generation, c.api_key, body)!
	return parse_response_map(resp)
}

pub fn (c Client) generate_music(req MusicGenerationRequest) !map[string]string {
	body := '{"model":"${req.model}","prompt":"${escape_json(req.prompt)}","lyrics":"${escape_json(req.lyrics)}","audio_setting":{"sample_rate":${req.audio_setting.sample_rate},"bitrate":${req.audio_setting.bitrate},"format":"${req.audio_setting.format}"}}'

	resp := http_post(c.host + endpoint_music_generation, c.api_key, body)!
	return parse_response_map(resp)
}

pub fn (c Client) design_voice(req VoiceDesignRequest) !map[string]string {
	mut body := '{"prompt":"${escape_json(req.prompt)}","preview_text":"${escape_json(req.preview_text)}"'
	if req.voice_id.len > 0 {
		body += ',"voice_id":"${escape_json(req.voice_id)}"'
	}
	body += '}'

	resp := http_post(c.host + endpoint_voice_design, c.api_key, body)!
	return parse_response_map(resp)
}

pub fn (c Client) search(req SearchRequest) !map[string]string {
	client := get_coding_plan_client()
	body := '{"q":"${escape_json(req.query)}"}'

	resp := http_post(client.host + endpoint_search, client.api_key, body)!

	// Check for error in response
	base_resp_start := resp.index('"base_resp":{') or { return error('Invalid response: no base_resp') }
	base_resp_end := find_matching_bracket(resp, base_resp_start + 11)
	if base_resp_end > base_resp_start {
		base_resp := resp[base_resp_start..base_resp_end + 1]
		status_code := parse_json_int_field(base_resp, 'status_code')
		if status_code != 0 {
			status_msg := parse_json_string_field(base_resp, 'status_msg')
			return error('MiniMax API error ${status_code}: ${status_msg}')
		}
	}

	// Parse organic results
	mut result := map[string]string{}
	organic_start := resp.index('"organic":[') or {
		return result
	}
	organic_end := find_matching_bracket(resp, organic_start + 10)
	if organic_end > organic_start {
		organic_content := resp[organic_start + 10..organic_end]
		// Extract top 3 results
		mut count := 0
		mut pos := 0
		for count < 3 {
			if obj_start := organic_content.index_after('{', pos) {
				obj_end := find_matching_bracket(organic_content, obj_start)
				if obj_end <= obj_start {
					break
				}
				obj := organic_content[obj_start..obj_end + 1]
				title := parse_json_string_field(obj, 'title')
				snippet := parse_json_string_field(obj, 'snippet')
				link := parse_json_string_field(obj, 'link')
				if title.len > 0 {
					result['result_${count + 1}_title'] = title
				}
				if snippet.len > 0 {
					result['result_${count + 1}_snippet'] = snippet
				}
				if link.len > 0 {
					result['result_${count + 1}_link'] = link
				}
				pos = obj_end + 1
				count++
			} else {
				break
			}
		}
	}
	return result
}

pub fn (c Client) vlm(req VLMRequest) !map[string]string {
	client := get_coding_plan_client()
	body := '{"prompt":"${escape_json(req.prompt)}","image_url":"${escape_json(req.image_url)}"}'

	resp := http_post(client.host + endpoint_vlm, client.api_key, body)!
	return parse_response_map(resp)
}

// =============================================================================
// Image Processing
// =============================================================================

// process_image_url converts image URL or local path to base64 data URL
pub fn process_image_url(image_url string) !string {
	mut img_url := image_url

	// Remove @ prefix if present
	if img_url.starts_with('@') {
		img_url = img_url[1..]
	}

	// If already in base64 data URL format, pass through
	if img_url.starts_with('data:') {
		return img_url
	}

	// Handle HTTP/HTTPS URLs - download and convert to base64
	if img_url.starts_with('http://') || img_url.starts_with('https://') {
		tmpfile := os.temp_dir() + '/minimax_img.tmp'

		result := os.execute('curl -s -L "${img_url}" -o "${tmpfile}"')
		if result.exit_code != 0 {
			return error('Failed to download image from URL: ${result.output}')
		}

		defer {
			os.rm(tmpfile) or {}
		}

		// Detect image format from file extension
		image_format := if img_url.to_lower().ends_with('.png') {
			'png'
		} else if img_url.to_lower().ends_with('.webp') {
			'webp'
		} else {
			'jpeg'
		}

		image_data := os.read_file(tmpfile)!
		base64_data := base64.encode(image_data.bytes())
		return 'data:image/${image_format};base64,${base64_data}'
	}

	// Handle local file paths
	if !os.exists(img_url) {
		return error('Local image file does not exist: ${img_url}')
	}

	image_data := os.read_file(img_url)!

	// Detect image format from file extension
	image_format := if img_url.to_lower().ends_with('.png') {
		'png'
	} else if img_url.to_lower().ends_with('.webp') {
		'webp'
	} else {
		'jpeg'
	}

	base64_data := base64.encode(image_data.bytes())
	return 'data:image/${image_format};base64,${base64_data}'
}

// =============================================================================
// Helper Functions
// =============================================================================

fn index_from(s string, ch string, start int) int {
	for i := start; i < s.len; i++ {
		if s[i] == ch[0] {
			return i
		}
	}
	return -1
}

fn escape_json(s string) string {
	mut result := ''
	for ch in s {
		match ch {
			`\\` { result += '\\\\' }
			`"` { result += '\\"' }
			`\n` { result += '\\n' }
			`\r` { result += '\\r' }
			`\t` { result += '\\t' }
			else { result += ch.ascii_str() }
		}
	}
	return result
}

fn parse_response_map(json_resp string) !map[string]string {
	// Check for error in response
	base_resp_start := json_resp.index('"base_resp":{') or { return map[string]string{} }
	base_resp_end := find_matching_bracket(json_resp, base_resp_start + 11)
	if base_resp_end > base_resp_start {
		base_resp := json_resp[base_resp_start..base_resp_end + 1]
		status_code := parse_json_int_field(base_resp, 'status_code')
		if status_code != 0 {
			status_msg := parse_json_string_field(base_resp, 'status_msg')
			return error('MiniMax API error ${status_code}: ${status_msg}')
		}
	}

	mut result := map[string]string{}

	// Extract data object if present
	data_start := json_resp.index('"data":{') or {
		// No data object, extract common fields directly
		for key in ['task_id', 'file_id', 'voice_id', 'demo_audio', 'trial_audio', 'audio', 'status', 'file'] {
			val := parse_json_string_field(json_resp, key)
			if val.len > 0 {
				result[key] = val
			}
		}
		return result
	}
	data_end := find_matching_bracket(json_resp, data_start + 7)
	if data_end > data_start {
		data_content := json_resp[data_start..data_end + 1]
		// Extract fields from data object
		mut i := 0
		for i < data_content.len {
			if data_content[i] == `"` {
				i++
				mut key_start := i
				for i < data_content.len && data_content[i] != `"` {
					i++
				}
				key := data_content[key_start..i]
				i++ // skip closing quote

				// Find colon
				for i < data_content.len && data_content[i] != `:` {
					i++
				}
				i++ // skip colon

				// Skip whitespace
				for i < data_content.len && data_content[i] in [u8(` `), `\t`, `\n`, `\r`] {
					i++
				}

				if i < data_content.len {
					if data_content[i] == `"` {
						// String value
						i++
						mut val_start := i
						for i < data_content.len && data_content[i] != `"` {
							i++
						}
						result['data.' + key] = data_content[val_start..i]
					} else if data_content[i] == `[` {
						// Array
						mut depth := 1
						mut arr_start := i
						i++
						for i < data_content.len && depth > 0 {
							if data_content[i] == `[` || data_content[i] == `{` {
								depth++
							} else if data_content[i] == `]` || data_content[i] == `}` {
								depth--
							}
							i++
						}
						result['data.' + key] = data_content[arr_start..i]
					} else {
						// Number or boolean
						mut val_start := i
						for i < data_content.len && data_content[i] !in [u8(` `), `\t`, `\n`, `\r`, `,`, `}`] {
							i++
						}
						val := data_content[val_start..i].trim_space()
						if val.len > 0 {
							result['data.' + key] = val
						}
					}
				}
			}
			i++
		}
	}

	// Also extract top-level fields
	for key in ['task_id', 'file_id', 'voice_id', 'demo_audio', 'trial_audio', 'audio', 'status', 'file'] {
		val := parse_json_string_field(json_resp, key)
		if val.len > 0 && key !in result {
			result[key] = val
		}
	}

	return result
}
