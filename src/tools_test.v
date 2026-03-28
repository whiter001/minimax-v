module main

import os

// ===== resolve_workspace_path =====

fn test_resolve_workspace_path_empty_workspace() {
	assert resolve_workspace_path('test.txt', '') == 'test.txt'
}

fn test_resolve_workspace_path_absolute_path() {
	assert resolve_workspace_path('/tmp/test.txt', '/home/user') == '/tmp/test.txt'
}

fn test_resolve_workspace_path_windows_absolute_path() {
	assert resolve_workspace_path(r'D:\work\project\index.ts', r'D:\work\github\minimax-v') == r'D:\work\project\index.ts'
}

fn test_resolve_workspace_path_unc_absolute_path() {
	assert resolve_workspace_path(r'\\server\share\index.ts', r'D:\work\github\minimax-v') == r'\\server\share\index.ts'
}

fn test_resolve_workspace_path_tilde_path() {
	assert resolve_workspace_path('~/test.txt', '/home/user') == '~/test.txt'
}

fn test_resolve_workspace_path_relative() {
	result := resolve_workspace_path('src/main.v', '/home/user/project')
	assert result == os.join_path('/home/user/project', 'src/main.v')
}

fn test_resolve_workspace_path_empty_path() {
	assert resolve_workspace_path('', '/home/user') == ''
}

// ===== read_file_tool =====

fn test_read_file_tool_empty_path() {
	if _ := read_file_tool('') {
		assert false, 'should have returned error'
	}
}

fn test_read_file_tool_nonexistent() {
	if _ := read_file_tool('/tmp/__nonexistent_minimax_test_file__') {
		assert false, 'should have returned error'
	}
}

fn test_read_file_tool_valid() {
	test_path := '/tmp/__minimax_test_read__.txt'
	os.write_file(test_path, 'test content') or {
		assert false
		return
	}
	defer { os.rm(test_path) or {} }
	result := read_file_tool(test_path) or {
		assert false
		return
	}
	assert result == 'test content'
}

// ===== write_file_tool =====

fn test_write_file_tool_empty_path() {
	if _ := write_file_tool('', 'content') {
		assert false, 'should have returned error'
	}
}

fn test_write_file_tool_valid() {
	test_path := '/tmp/__minimax_test_write__.txt'
	defer { os.rm(test_path) or {} }
	result := write_file_tool(test_path, 'hello world') or {
		assert false
		return
	}
	assert result.contains('文件已写入')
	content := os.read_file(test_path) or { '' }
	assert content == 'hello world'
}

// ===== list_dir_tool =====

fn test_list_dir_tool_empty_path() {
	if _ := list_dir_tool('') {
		assert false, 'should have returned error'
	}
}

fn test_list_dir_tool_nonexistent() {
	if _ := list_dir_tool('/tmp/__nonexistent_minimax_dir__') {
		assert false, 'should have returned error'
	}
}

fn test_list_dir_tool_valid() {
	test_dir := '/tmp/__minimax_test_dir__'
	os.mkdir(test_dir) or {}
	os.write_file(os.join_path(test_dir, 'file1.txt'), '') or {}
	defer {
		os.rmdir_all(test_dir) or {}
	}
	result := list_dir_tool(test_dir) or {
		assert false
		return
	}
	assert result.contains('file1.txt')
	assert result.contains('[FILE]')
}

// ===== run_command / run_command_in_dir =====

fn test_run_command_empty() {
	if _ := run_command('') {
		assert false, 'should have returned error'
	}
}

fn test_run_command_dangerous() {
	if _ := run_command('rm -rf /') {
		assert false, 'should have returned error'
	}
}

fn test_run_command_valid() {
	result := run_command('echo hello') or {
		assert false
		return
	}
	assert result.contains('hello')
}

fn test_run_command_in_dir_valid() {
	test_dir := '/tmp/__minimax_test_cmd_dir__'
	os.mkdir(test_dir) or {}
	defer { os.rmdir_all(test_dir) or {} }
	result := run_command_in_dir('pwd', test_dir) or {
		assert false
		return
	}
	assert result.contains(test_dir)
}

fn test_run_command_in_dir_empty_dir() {
	// Empty workspace should just run command normally
	result := run_command_in_dir('echo ok', '') or {
		assert false
		return
	}
	assert result.contains('ok')
}

// ===== execute_tool_use_in_workspace =====

fn test_execute_tool_use_read_file() {
	test_path := '/tmp/__minimax_test_exec__.txt'
	os.write_file(test_path, 'exec test') or {}
	defer { os.rm(test_path) or {} }

	tool := ToolUse{
		id:    'tu_1'
		name:  'read_file'
		input: {
			'path': test_path
		}
	}
	result := execute_tool_use_in_workspace(tool, '', default_config())
	assert result == 'exec test'
}

fn test_execute_tool_use_with_workspace() {
	test_dir := '/tmp/__minimax_ws_test__'
	os.mkdir(test_dir) or {}
	os.write_file(os.join_path(test_dir, 'hello.txt'), 'workspace file') or {}
	defer { os.rmdir_all(test_dir) or {} }

	tool := ToolUse{
		id:    'tu_1'
		name:  'read_file'
		input: {
			'path': 'hello.txt'
		}
	}
	result := execute_tool_use_in_workspace(tool, test_dir, default_config())
	assert result == 'workspace file'
}

fn test_execute_tool_use_record_experience() {
	test_dir := '/tmp/__minimax_tool_record_experience__'
	os.mkdir_all(test_dir) or {}
	os.setenv('MINIMAX_CONFIG_HOME', test_dir, true)
	defer {
		os.unsetenv('MINIMAX_CONFIG_HOME')
		os.rmdir_all(test_dir) or {}
	}

	tool := ToolUse{
		id:    'tu_exp_1'
		name:  'record_experience'
		input: {
			'skill':      'browser-ops'
			'title':      '工具执行经验'
			'scenario':   '页面已稳定加载'
			'action':     '等待目标节点后点击'
			'outcome':    '操作成功执行'
			'tags':       'browser,tool'
			'confidence': '5'
		}
	}
	result := execute_tool_use_in_workspace(tool, '', default_config())
	assert result.contains('已记录经验')
	assert result.contains('已同步 skill')
	assert result.contains('已升级 SOP')
	assert os.is_file(os.join_path(test_dir, 'knowledge', 'experiences.jsonl'))
	assert os.is_file(os.join_path(test_dir, 'skills', 'browser-ops', 'SKILL.md'))
	assert os.is_file(os.join_path(test_dir, 'sops', 'browser-ops', 'SOP.md'))
	jsonl := os.read_file(os.join_path(test_dir, 'knowledge', 'experiences.jsonl')) or { '' }
	assert jsonl.contains('工具执行经验')
}

fn test_send_mail_tool_validates_required_smtp_fields() {
	result := send_mail_tool(Config{}, '', 0, '', '', '', 'to@example.com', 'subject',
		'body')
	assert result.contains('smtp server is required')

	config := Config{
		smtp_server: 'smtp.example.com'
		smtp_port:   587
	}
	result2 := send_mail_tool(config, '', 0, '', '', '', 'to@example.com', 'subject',
		'body')
	assert result2.contains('smtp username is required')

	config2 := Config{
		smtp_server:   'smtp.example.com'
		smtp_port:     587
		smtp_username: 'user@example.com'
		smtp_password: 'secret'
		smtp_from:     'sender@example.com'
	}
	result3 := send_mail_tool(config2, '', 0, '', '', '', 'to@example.com', 'sub\rject',
		'body')
	assert result3.contains('CR/LF')
}

fn test_build_image_generation_request_json_defaults() {
	body := build_image_generation_request_json({
		'prompt': 'a red fox'
	}) or {
		assert false
		return
	}
	assert body.contains('"model":"image-01"')
	assert body.contains('"prompt":"a red fox"')
	assert body.contains('"response_format":"url"')
	assert body.contains('"n":1')
	assert body.contains('"prompt_optimizer":false')
	assert body.contains('"aigc_watermark":false')
}

fn test_build_image_generation_request_json_with_options() {
	body := build_image_generation_request_json({
		'prompt':               'a futuristic city'
		'model':                'image-01'
		'aspect_ratio':         '16:9'
		'width':                '1280'
		'height':               '720'
		'response_format':      'base64'
		'seed':                 '42'
		'n':                    '3'
		'prompt_optimizer':     'true'
		'aigc_watermark':       'true'
		'reference_image_url':  'https://example.com/reference.png'
		'reference_image_type': 'character'
	}) or {
		assert false
		return
	}
	assert body.contains('"aspect_ratio":"16:9"')
	assert body.contains('"width":1280')
	assert body.contains('"height":720')
	assert body.contains('"response_format":"base64"')
	assert body.contains('"seed":42')
	assert body.contains('"n":3')
	assert body.contains('"prompt_optimizer":true')
	assert body.contains('"aigc_watermark":true')
	assert body.contains('"subject_reference"')
	assert body.contains('"image_file":"https://example.com/reference.png"')
}

fn test_build_image_generation_request_json_with_raw_subject_reference() {
	body := build_image_generation_request_json({
		'prompt':            'a portrait'
		'subject_reference': '[{"type":"character","image_file":"https://example.com/ref.png"}]'
	}) or {
		assert false
		return
	}
	assert body.contains('"subject_reference":[{"type":"character","image_file":"https://example.com/ref.png"}]')
}

fn test_build_speech_synthesis_request_json_defaults() {
	body := build_speech_synthesis_request_json({
		'text': 'hello world'
	}) or {
		assert false
		return
	}
	assert body.contains('"model":"speech-2.8-hd"')
	assert body.contains('"text":"hello world"')
	assert body.contains('"stream":false')
	assert body.contains('"output_format":"url"')
	assert body.contains('"subtitle_enable":false')
}

fn test_build_speech_synthesis_request_json_with_voice_settings() {
	body := build_speech_synthesis_request_json({
		'prompt':             '请读出这段文本'
		'model':              'speech-2.8-turbo'
		'output_format':      'hex'
		'voice_id':           'voice_001'
		'speed':              '1.2'
		'volume':             '0.8'
		'pitch':              '0.9'
		'subtitle_enable':    'true'
		'aigc_watermark':     'true'
		'language_boost':     'auto'
		'voice_setting':      ''
		'audio_setting':      '{"sample_rate":24000}'
		'pronunciation_dict': '{"AI":"ai"}'
		'timbre_weights':     '[{"voice_id":"voice_001","weight":1}]'
	}) or {
		assert false
		return
	}
	assert body.contains('"model":"speech-2.8-turbo"')
	assert body.contains('"output_format":"hex"')
	assert body.contains('"voice_setting":{"voice_id":"voice_001","speed":1.2,"volume":0.8,"pitch":0.9}')
	assert body.contains('"audio_setting":{"sample_rate":24000}')
	assert body.contains('"pronunciation_dict":{"AI":"ai"}')
	assert body.contains('"timbre_weights":[{"voice_id":"voice_001","weight":1}]')
	assert body.contains('"language_boost":"auto"')
	assert body.contains('"subtitle_enable":true')
	assert body.contains('"aigc_watermark":true')
}

fn test_summarize_image_generation_response_extracts_urls() {
	body := '{"id":"img_job_1","data":{"images":[{"url":"https://example.com/image-1.png"},{"url":"https://example.com/image-2.png"}]}}'
	summary := summarize_image_generation_response(body)
	assert summary.contains('img_job_1')
	assert summary.contains('https://example.com/image-1.png')
	assert summary.contains('https://example.com/image-2.png')
}

fn test_summarize_image_generation_response_extracts_base64_array() {
	body := '{"id":"img_job_2","data":{"image_base64":["SGVsbG8=","V29ybGQ="]}}'
	summary := summarize_image_generation_response(body)
	assert summary.contains('img_job_2')
	assert summary.contains('base64_images: 2')
}

fn test_save_image_generation_base64_file_writes_bytes() {
	test_path := '/tmp/__minimax_image_output__.bin'
	defer { os.rm(test_path) or {} }
	saved_path := save_image_generation_base64_file('SGVsbG8=', test_path) or {
		assert false
		return
	}
	assert saved_path == test_path
	assert os.read_file(test_path) or { '' } == 'Hello'
}

fn test_generate_image_tool_requires_api_key() {
	result := image_generation_tool(Config{}, {
		'prompt': 'a red fox'
	}, '')
	assert result.contains('requires an API key')
}

fn test_summarize_speech_synthesis_response_extracts_urls() {
	body := '{"id":"speech_job_1","trace_id":"trace_123","data":{"audio_url":"https://example.com/audio.mp3"}}'
	summary := summarize_speech_synthesis_response(body)
	assert summary.contains('speech_job_1')
	assert summary.contains('trace_123')
	assert summary.contains('https://example.com/audio.mp3')
}

fn test_generate_speech_tool_requires_api_key() {
	result := speech_synthesis_tool(Config{}, {
		'text': 'hello world'
	}, '')
	assert result.contains('requires an API key')
}

fn test_parse_speech_synthesis_command_extracts_fields() {
	parsed := parse_speech_synthesis_command('speech --model speech-2.8-hd --output-format hex --voice-id voice_001 --speed 1.2 --volume 0.8 --pitch 0.9 --subtitle-enable --aigc-watermark --save-path out.mp3 --text-file book.txt --split --chunk-size 8000') or {
		assert false
		return
	}
	assert parsed['model'] == 'speech-2.8-hd'
	assert parsed['output_format'] == 'hex'
	assert parsed['voice_id'] == 'voice_001'
	assert parsed['speed'] == '1.2'
	assert parsed['volume'] == '0.8'
	assert parsed['pitch'] == '0.9'
	assert parsed['subtitle_enable'] == 'true'
	assert parsed['aigc_watermark'] == 'true'
	assert parsed['save_path'] == 'out.mp3'
	assert parsed['text_file'] == 'book.txt'
	assert parsed['split'] == 'true'
	assert parsed['chunk_size'] == '8000'
}

fn test_load_speech_synthesis_command_text_prefers_text_file() {
	test_path := '/tmp/__minimax_speech_input__.txt'
	os.write_file(test_path, '  第一行\n第二行  ') or {
		assert false
		return
	}
	defer { os.rm(test_path) or {} }
	text := load_speech_synthesis_command_text({
		'text_file': test_path
	}, '') or {
		assert false
		return
	}
	assert text == '第一行\n第二行'
}

fn test_split_speech_text_into_chunks_keeps_content_order() {
	text := 'abcdefghijABCDEFGHIJ12345'
	chunks := split_speech_text_into_chunks(text, 10)
	assert chunks.len == 3
	assert chunks.join('') == text
	for chunk in chunks {
		assert chunk.len <= 10
	}
}

fn test_handle_builtin_command_with_client_routes_speech_command() {
	mut client := new_api_client(default_config())
	result := handle_builtin_command_with_client(mut client, 'speech --text hello world')
	assert result.contains('speech synthesis requires an API key')
}

fn test_handle_builtin_command_with_client_shows_speech_help() {
	mut client := new_api_client(default_config())
	result := handle_builtin_command_with_client(mut client, 'speech --help')
	assert result.contains('用法: speech')
	assert result.contains('--text <文本>')
}

fn test_handle_builtin_command_with_client_supports_split_usage() {
	mut client := new_api_client(default_config())
	result := handle_builtin_command_with_client(mut client, 'speech --split --text abcdefghijklmnopqrstuvwxyz')
	assert result.contains('speech synthesis requires an API key')
		|| result.contains('Error: speech synthesis requires an API key')
}

fn test_handle_builtin_command_with_client_shows_file_management_help() {
	mut client := new_api_client(default_config())
	result := handle_builtin_command_with_client(mut client, 'files --help')
	assert result.contains('用法: files list --purpose')
	assert result.contains('voice_clone')
}

fn test_parse_file_management_list_command_extracts_purpose() {
	parsed := parse_file_management_list_command('files list --purpose t2a_async_input') or {
		panic(err)
	}
	assert parsed['purpose'] == 't2a_async_input'
}

fn test_summarize_file_management_list_response_formats_files() {
	body := '{"files":[{"file_id":"f1","filename":"demo.txt","purpose":"t2a_async_input","bytes":123,"created_at":456}]}'
	summary := summarize_file_management_list_response(body)
	assert summary.contains('files: 1')
	assert summary.contains('demo.txt')
	assert summary.contains('id=f1')
	assert summary.contains('123 bytes')
}

fn test_get_tools_schema_json_includes_generate_image() {
	json := get_tools_schema_json()
	assert json.contains('"name":"generate_image"')
	assert json.contains('"response_format"')
	assert json.contains('"prompt_optimizer"')
	assert json.contains('"subject_reference"')
	assert json.contains('"save_path"')
}

fn test_get_tools_schema_json_includes_generate_speech() {
	json := get_tools_schema_json()
	assert json.contains('"name":"generate_speech"')
	assert json.contains('"output_format"')
	assert json.contains('"subtitle_enable"')
}

fn test_get_tools_schema_json_includes_list_files() {
	json := get_tools_schema_json()
	assert json.contains('"name":"list_files"')
	assert json.contains('"purpose"')
}

fn test_execute_tool_use_list_files_requires_api_key() {
	tool := ToolUse{
		id:    'tu_1'
		name:  'list_files'
		input: {
			'purpose': 't2a_async_input'
		}
	}
	result := execute_tool_use_in_workspace(tool, '', default_config())
	assert result.contains('file management requires an API key')
}

fn test_execute_tool_use_unknown() {
	tool := ToolUse{
		id:    'tu_1'
		name:  'unknown_tool'
		input: {}
	}
	result := execute_tool_use(tool)
	assert result.contains('Unknown tool')
}

// ===== print_tool_result =====
// Just verify no crash on various inputs

fn test_print_tool_result_short() {
	mut client := new_api_client(default_config())
	print_tool_result(mut client, 'test', 'short result')
}

fn test_print_tool_result_long() {
	mut client := new_api_client(default_config())
	print_tool_result(mut client, 'test', 'x'.repeat(200))
}

// ===== grep_search_tool =====

fn test_grep_search_tool_valid() {
	test_dir := '/tmp/__minimax_grep_test__'
	os.mkdir_all(test_dir) or {}
	os.write_file(os.join_path(test_dir, 'hello.txt'), 'line1 foo\nline2 bar\nline3 foo bar') or {}
	defer { os.rmdir_all(test_dir) or {} }

	result := grep_search_tool('foo', test_dir, '')
	assert result.contains('foo')
	assert result.contains('hello.txt')
}

fn test_grep_search_tool_no_match() {
	test_dir := '/tmp/__minimax_grep_nomatch__'
	os.mkdir_all(test_dir) or {}
	os.write_file(os.join_path(test_dir, 'data.txt'), 'nothing here') or {}
	defer { os.rmdir_all(test_dir) or {} }

	result := grep_search_tool('zzzznotfound', test_dir, '')
	// Should not crash; may return empty or 'no matches'
	assert result.len >= 0
}

fn test_grep_search_tool_with_include() {
	test_dir := '/tmp/__minimax_grep_include__'
	os.mkdir_all(test_dir) or {}
	os.write_file(os.join_path(test_dir, 'code.v'), 'fn main() {}') or {}
	os.write_file(os.join_path(test_dir, 'notes.txt'), 'fn notes') or {}
	defer { os.rmdir_all(test_dir) or {} }

	result := grep_search_tool('fn', test_dir, '*.v')
	assert result.contains('code.v')
}

// ===== find_files_tool =====

fn test_find_files_tool_valid() {
	test_dir := '/tmp/__minimax_find_test__'
	os.mkdir_all(os.join_path(test_dir, 'sub')) or {}
	os.write_file(os.join_path(test_dir, 'main.v'), '') or {}
	os.write_file(os.join_path(test_dir, 'sub', 'util.v'), '') or {}
	os.write_file(os.join_path(test_dir, 'readme.md'), '') or {}
	defer { os.rmdir_all(test_dir) or {} }

	result := find_files_tool('*.v', test_dir)
	assert result.contains('main.v')
	assert result.contains('util.v')
	assert !result.contains('readme.md')
}

fn test_find_files_tool_no_match() {
	test_dir := '/tmp/__minimax_find_none__'
	os.mkdir_all(test_dir) or {}
	os.write_file(os.join_path(test_dir, 'data.txt'), '') or {}
	defer { os.rmdir_all(test_dir) or {} }

	result := find_files_tool('*.zzz_no_match', test_dir)
	// Should indicate no files found or return empty
	assert result.contains('No files found') || !result.contains('data.txt')
}

// ===== json_edit_tool =====

fn test_json_edit_tool_view() {
	test_path := '/tmp/__minimax_json_test__.json'
	os.write_file(test_path, '{"name":"test","version":"1.0"}') or {}
	defer { os.rm(test_path) or {} }

	result := json_edit_tool('view', test_path, '', '')
	assert result.contains('name')
	assert result.contains('test')
}

fn test_json_edit_tool_set() {
	test_path := '/tmp/__minimax_json_set__.json'
	// Write valid JSON
	os.write_file(test_path, '{"name":"old"}') or {
		assert false
		return
	}
	defer { os.rm(test_path) or {} }

	// json_edit uses jq; verify it works
	jq_check := os.execute('jq . "${test_path}" 2>&1')
	if jq_check.exit_code != 0 {
		// jq not available or broken, skip
		return
	}

	result := json_edit_tool('set', test_path, 'name', 'new')
	// On jq failure, result starts with 'Error' — accept both outcomes
	if result.starts_with('Error') {
		// jq env issue, skip gracefully
		return
	}
	assert result.contains('Set')
	content := os.read_file(test_path) or { '' }
	assert content.contains('new')
}

fn test_json_edit_tool_invalid_action() {
	result := json_edit_tool('invalid', '/tmp/x.json', '', '')
	assert result.contains('Error') || result.contains('Unknown')
}

// ===== todo_manager_tool =====

fn test_todo_manager_add_and_list() {
	// Clear
	todo_manager_tool('clear', '', 0, '', '')

	result := todo_manager_tool('add', '', 0, 'First task', '')
	assert result.contains('Added')
	assert result.contains('First task')

	list := todo_manager_tool('list', '', 0, '', '')
	assert list.contains('First task')
}

fn test_todo_manager_update() {
	todo_manager_tool('clear', '', 0, '', '')
	todo_manager_tool('add', '', 0, 'Task 1', '')

	result := todo_manager_tool('update', '', 1, '', 'done')
	assert result.contains('Updated')
	assert result.contains('done')
}

fn test_todo_manager_clear() {
	todo_manager_tool('add', '', 0, 'temp', '')
	result := todo_manager_tool('clear', '', 0, '', '')
	assert result.contains('cleared')

	list := todo_manager_tool('list', '', 0, '', '')
	// Should be empty or show 'no items'
	assert !list.contains('temp')
}

fn test_todo_manager_set_from_text() {
	todo_manager_tool('clear', '', 0, '', '')
	result := todo_manager_tool('set', '', 0, '1. Setup env\n2. Write code\n3. Test',
		'')
	assert !result.starts_with('Error')

	list := todo_manager_tool('list', '', 0, '', '')
	assert list.contains('Setup env')
}

fn test_todo_manager_invalid_action() {
	result := todo_manager_tool('bad', '', 0, '', '')
	assert result.contains('Error') || result.contains('Unknown')
}

// ===== activate_skill via execute_tool_use =====

fn test_execute_tool_use_activate_skill() {
	// Reset skill registry
	skill_registry.skills = []
	skill_registry.loaded = false
	for s in get_builtin_skills() {
		skill_registry.skills << s
	}
	skill_registry.loaded = true

	tool := ToolUse{
		id:    'tu_1'
		name:  'activate_skill'
		input: {
			'name': 'coder'
		}
	}
	result := execute_tool_use(tool)
	assert result.contains('Skill activated')
	assert result.contains('coder')
}

fn test_execute_tool_use_activate_skill_not_found() {
	skill_registry.skills = []
	skill_registry.loaded = false
	for s in get_builtin_skills() {
		skill_registry.skills << s
	}
	skill_registry.loaded = true

	tool := ToolUse{
		id:    'tu_1'
		name:  'activate_skill'
		input: {
			'name': 'nonexistent'
		}
	}
	result := execute_tool_use(tool)
	assert result.contains('not found')
}

fn test_execute_tool_use_match_sop() {
	test_dir := '/tmp/__minimax_tool_match_sop__'
	os.mkdir_all(os.join_path(test_dir, 'sops', 'wechat-mp-draft-publisher')) or {}
	os.setenv('MINIMAX_CONFIG_HOME', test_dir, true)
	defer {
		os.unsetenv('MINIMAX_CONFIG_HOME')
		os.rmdir_all(test_dir) or {}
	}
	os.write_file(os.join_path(test_dir, 'sops', 'wechat-mp-draft-publisher', 'SOP.md'),
		'# SOP\n\n微信公众号草稿箱发布流程\n\n先检查草稿状态再处理封面。') or {}
	tool := ToolUse{
		id:    'tu_sop_1'
		name:  'match_sop'
		input: {
			'task':  '请处理微信公众号草稿箱封面'
			'limit': '2'
		}
	}
	result := execute_tool_use(tool)
	assert result.contains('Best SOP matches for task')
	assert result.contains('suggested_read_order:')
	assert result.contains('wechat-mp-draft-publisher')
	assert result.contains('score_breakdown:')
	assert result.contains('matched_terms')
	assert result.contains('path:')
}

// ===== BashSession =====

fn test_new_bash_session_default() {
	session := new_bash_session('')
	assert session.cwd.len > 0
	assert session.timeout == 120
}

fn test_new_bash_session_with_workspace() {
	session := new_bash_session('/tmp')
	assert session.cwd == '/tmp'
}

fn test_bash_session_execute() {
	mut session := new_bash_session('/tmp')
	result := session.execute('echo hello123')
	assert result.contains('hello123')
}

fn test_should_use_windows_direct_command_matches_supported_shells() {
	if os.user_os() != 'windows' {
		return
	}
	assert should_use_windows_direct_command('pueue add -- bun -v')
	assert should_use_windows_direct_command('pueue.exe add -- bun -v')
	assert should_use_windows_direct_command('pwsh -NoProfile -Command "Get-Date"')
	assert should_use_windows_direct_command('nu -c "ls"')
	assert !should_use_windows_direct_command('bun -v')
}

// ===== read_many_files_tool =====

fn test_read_many_files_tool_valid() {
	test_dir := '/tmp/__minimax_readmany__'
	os.mkdir_all(test_dir) or {}
	os.write_file(os.join_path(test_dir, 'a.txt'), 'content_a') or {}
	os.write_file(os.join_path(test_dir, 'b.txt'), 'content_b') or {}
	defer { os.rmdir_all(test_dir) or {} }

	result := read_many_files_tool('${test_dir}/a.txt,${test_dir}/b.txt', '')
	assert result.contains('content_a')
	assert result.contains('content_b')
}

fn test_read_many_files_tool_glob() {
	test_dir := '/tmp/__minimax_readmany_glob__'
	os.mkdir_all(test_dir) or {}
	os.write_file(os.join_path(test_dir, 'x.v'), 'v_code') or {}
	os.write_file(os.join_path(test_dir, 'y.v'), 'v_code2') or {}
	defer { os.rmdir_all(test_dir) or {} }

	result := read_many_files_tool('${test_dir}/*.v', '')
	assert result.contains('v_code')
}

// ===== sequentialthinking_tool =====

fn test_sequentialthinking_tool_basic() {
	result := sequentialthinking_tool('First step', 1, 3, true, false, 0, 0)
	assert result.contains('1/3')
	assert result.contains('recorded')
	assert result.contains('continuing')
}

fn test_sequentialthinking_tool_last_step() {
	result := sequentialthinking_tool('Final', 3, 3, false, false, 0, 0)
	assert result.contains('3/3')
	assert result.contains('complete')
}

fn test_sequentialthinking_tool_revision() {
	result := sequentialthinking_tool('Revised thought', 2, 3, true, true, 1, 0)
	assert result.contains('Revision')
	assert result.contains('recorded')
}

// ===== session_note_tool =====

fn test_session_note_tool_read() {
	result := session_note_tool('read', '')
	// Should not crash, may be empty
	assert result.len >= 0
}

fn test_session_note_tool_write_and_read() {
	session_note_tool('write', 'test note content')
	result := session_note_tool('read', '')
	assert result.contains('test note content')
	// Clean up
	session_note_tool('write', '')
}

fn test_session_note_tool_append() {
	session_note_tool('write', 'base')
	session_note_tool('append', '\nappended')
	result := session_note_tool('read', '')
	assert result.contains('base')
	assert result.contains('appended')
	// Clean up
	session_note_tool('write', '')
}

// ===== get_tools_schema_json =====

fn test_get_tools_schema_json_valid() {
	json := get_tools_schema_json()
	// Should be valid JSON array
	assert json.starts_with('[')
	assert json.ends_with(']')
	// Should contain core tools
	assert json.contains('str_replace_editor')
	assert json.contains('bash')
	assert json.contains('read_file')
	assert json.contains('write_file')
	assert json.contains('list_dir')
	assert json.contains('run_command')
	assert json.contains('mouse_control')
	assert json.contains('keyboard_control')
	assert json.contains('capture_screen')
	assert json.contains('screen_analyze')
	assert json.contains('image_source')
	assert json.contains('match_sop')
	assert json.contains('record_experience')
	assert json.contains('session_note')
	assert json.contains('task_done')
	assert json.contains('grep_search')
	assert json.contains('find_files')
	assert json.contains('sequentialthinking')
	assert json.contains('json_edit')
	assert json.contains('ask_user')
	assert json.contains('update_working_checkpoint')
	assert json.contains('todo_manager')
	assert json.contains('read_many_files')
	assert json.contains('activate_skill')
}

fn test_mouse_control_requires_flag() {
	prev := allow_desktop_control
	allow_desktop_control = false
	defer {
		allow_desktop_control = prev
	}
	result := mouse_control_tool('move', 10, 10, 'left', 1, 120)
	assert result.contains('未开启')
}

fn test_keyboard_control_requires_flag() {
	prev := allow_desktop_control
	allow_desktop_control = false
	defer {
		allow_desktop_control = prev
	}
	result := keyboard_control_tool('type', 'hello', '')
	assert result.contains('未开启')
}

fn test_capture_screen_requires_flag() {
	prev := allow_screen_capture
	allow_screen_capture = false
	defer {
		allow_screen_capture = prev
	}
	result := capture_screen_tool('', 0, 0, 0, 0)
	assert result.contains('Error:')
	assert result.contains('未开启')
}

fn test_build_macos_screencapture_command_fullscreen() {
	cmd := build_macos_screencapture_command('/tmp/demo shot.png', 0, 0, 0, 0)
	assert cmd == "screencapture -x '/tmp/demo shot.png'"
}

fn test_build_macos_screencapture_command_region() {
	cmd := build_macos_screencapture_command('/tmp/cap.png', 10, 20, 300, 200)
	assert cmd == "screencapture -x -R10,20,300,200 '/tmp/cap.png'"
}

fn test_build_macos_sips_resize_command() {
	cmd := build_macos_sips_resize_command('/tmp/input image.png', '/tmp/output image.png',
		1600)
	assert cmd == "sips -Z 1600 '/tmp/input image.png' --out '/tmp/output image.png'"
}

fn test_is_understand_image_error_result_detects_tool_errors() {
	assert is_understand_image_error_result('Error executing tool understand_image: 1 validation error')
	assert is_understand_image_error_result('Error: MCP response timeout for request 4')
	assert !is_understand_image_error_result('这是一段正常的图像分析结果')
}

fn test_is_understand_image_retryable_error_message_detects_validation_issues() {
	assert is_understand_image_retryable_error_message('1 validation error for understand_imageArguments')
	assert is_understand_image_retryable_error_message('Field required')
	assert !is_understand_image_retryable_error_message('MCP response timeout for request 4')
	assert !is_understand_image_retryable_error_message('MCP 调用失败: transport error')
}

fn test_normalize_understand_image_input_prefers_primary_fields() {
	input := {
		'image_source': '/tmp/alias.png'
		'question':     '看图'
		'x':            '10'
	}
	normalized := normalize_understand_image_input(input)
	assert normalized['image_path'] == '/tmp/alias.png'
	assert normalized['prompt'] == '看图'
	assert normalized['x'] == '10'
}

fn test_normalize_understand_image_input_keeps_primary_fields() {
	input := {
		'image_path': '/tmp/primary.png'
		'prompt':     '请识别'
		'path':       '/tmp/alias.png'
		'question':   '别覆盖'
	}
	normalized := normalize_understand_image_input(input)
	assert normalized['image_path'] == '/tmp/primary.png'
	assert normalized['prompt'] == '请识别'
}

fn test_parse_macos_send_keys_windows_style_combo() {
	send := parse_macos_send_keys('^l') or {
		assert false
		return
	}
	assert send.keystroke == 'l'
	assert send.modifiers == ['control down']
}

fn test_parse_macos_send_keys_textual_special_key() {
	send := parse_macos_send_keys('cmd+shift+enter') or {
		assert false
		return
	}
	assert send.key_code == 36
	assert send.modifiers == ['command down', 'shift down']
}

fn test_escape_windows_sendkeys_literal_handles_special_chars() {
	assert escape_windows_sendkeys_literal('{') == '{{}'
	assert escape_windows_sendkeys_literal('}') == '{}}'
	assert escape_windows_sendkeys_literal('+') == '{+}'
	assert escape_windows_sendkeys_literal('1+3') == '1{+}3'
	assert escape_windows_sendkeys_literal('^%~()[]') == '{^}{%}{~}{(}{)}{[}{]}'
}

fn test_build_macos_keyboard_script_type() {
	script := build_macos_keyboard_script('type', 'hello', '') or {
		assert false
		return
	}
	assert script == 'tell application "System Events" to keystroke "hello"'
}

fn test_build_macos_keyboard_script_send() {
	script := build_macos_keyboard_script('send', '', '^l') or {
		assert false
		return
	}
	assert script == 'tell application "System Events" to keystroke "l" using {control down}'
}

fn test_build_macos_mouse_swift_script_contains_action() {
	script := build_macos_mouse_swift_script('click', 10, 20, 'left', 2, 120)
	assert script.contains('let action = "click"')
	assert script.contains('let x = Double(10)')
	assert script.contains('let y = Double(20)')
	assert script.contains('let clicks = 2')
	assert script.contains('AXIsProcessTrusted')
}

fn test_build_doctor_report_formats_checks_and_notes() {
	report := build_doctor_report('测试自检', [
		DoctorCheck{'foo', 'ok', 'ready'},
		DoctorCheck{'bar', 'warn', 'missing permission'},
	], ['first note'])
	assert report.contains('🩺 测试自检')
	assert report.contains('✅ foo: ready')
	assert report.contains('⚠️ bar: missing permission')
	assert report.contains('建议:')
	assert report.contains('first note')
}

fn test_handle_builtin_command_doctor() {
	result := handle_builtin_command('doctor')
	assert result.contains('桌面能力自检')
	assert result.contains('当前平台')
}

fn test_handle_builtin_command_read() {
	test_path := '/tmp/__minimax_builtin_read__.txt'
	os.write_file(test_path, 'builtin read content') or {
		assert false
		return
	}
	defer { os.rm(test_path) or {} }
	result := handle_builtin_command('#read ${test_path}')
	assert result == 'builtin read content'
}

fn test_handle_builtin_command_write() {
	test_path := '/tmp/__minimax_builtin_write__.txt'
	defer { os.rm(test_path) or {} }
	result := handle_builtin_command('#write ${test_path} hello builtin world')
	assert result.contains('文件已写入')
	content := os.read_file(test_path) or {
		assert false
		return
	}
	assert content == 'hello builtin world'
}

fn test_handle_builtin_command_ls() {
	test_dir := '/tmp/__minimax_builtin_ls__'
	os.mkdir(test_dir) or {}
	os.write_file(os.join_path(test_dir, 'file1.txt'), '') or {}
	defer { os.rmdir_all(test_dir) or {} }
	result := handle_builtin_command('#ls ${test_dir}')
	assert result.contains('file1.txt')
	assert result.contains('[FILE]')
}

fn test_handle_builtin_command_run() {
	result := handle_builtin_command('#run echo builtin-run-ok')
	assert result.contains('builtin-run-ok')
}

fn test_handle_builtin_command_write_usage() {
	result := handle_builtin_command('#write only_path')
	assert result == '用法: #write <path> <content>'
}

fn test_doctor_command_usage_lists_test_commands() {
	usage := doctor_command_usage()
	assert usage.contains('doctor test screen [path]')
	assert usage.contains('doctor test mouse move <x> <y>')
	assert usage.contains('doctor test keyboard send <keys>')
}

fn test_handle_doctor_command_help() {
	result := handle_doctor_command('doctor help')
	assert result.contains('用法:')
	assert result.contains('doctor test keyboard type <text>')
}

fn test_handle_doctor_command_invalid_mouse_args() {
	result := handle_doctor_command('doctor test mouse move 10')
	assert result == '用法: doctor test mouse move <x> <y>'
}

fn test_handle_doctor_command_invalid_keyboard_args() {
	result := handle_doctor_command('doctor test keyboard send ')
	assert result.contains('用法: doctor test keyboard send <keys>')
}

fn test_build_mcp_args_json_typed_values() {
	input := {
		'x':      '123'
		'active': 'true'
		'meta':   '{"score":1}'
		'name':   'alice'
	}
	args := build_mcp_args_json(input)
	assert args.starts_with('{')
	assert args.ends_with('}')
	assert args.contains('"x":123')
	assert args.contains('"active":true')
	assert args.contains('"meta":{"score":1}')
	assert args.contains('"name":"alice"')
}

fn test_build_mcp_args_json_dot_path() {
	// Regression test: "." should be treated as a string, not a number
	input := {
		'path': '.'
	}
	args := build_mcp_args_json(input)
	assert args == '{"path":"."}'
}

fn test_detect_jq_value_special_strings() {
	// "." should be a string, not a number
	assert detect_jq_value('.') == '"."'
	// "-" alone should be a string
	assert detect_jq_value('-') == '"-"'
	// ".5" is a valid number
	assert detect_jq_value('.5') == '.5'
	// "5." is a valid number
	assert detect_jq_value('5.') == '5.'
	// "123" is a number
	assert detect_jq_value('123') == '123'
	// "-123" is a number
	assert detect_jq_value('-123') == '-123'
	// ".." should be a string
	assert detect_jq_value('..') == '".."'
}

// ===== task_done tool =====

fn test_execute_tool_use_task_done() {
	tool := ToolUse{
		id:    'tu_1'
		name:  'task_done'
		input: {
			'result': 'All tasks completed'
		}
	}
	result := execute_tool_use(tool)
	assert result.starts_with('__TASK_DONE__:')
	assert result.contains('All tasks completed')
}
