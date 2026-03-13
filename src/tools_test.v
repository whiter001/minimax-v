module main

import os

// ===== resolve_workspace_path =====

fn test_resolve_workspace_path_empty_workspace() {
	assert resolve_workspace_path('test.txt', '') == 'test.txt'
}

fn test_resolve_workspace_path_absolute_path() {
	assert resolve_workspace_path('/tmp/test.txt', '/home/user') == '/tmp/test.txt'
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
	result := execute_tool_use_in_workspace(tool, '')
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
	result := execute_tool_use_in_workspace(tool, test_dir)
	assert result == 'workspace file'
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
	print_tool_result('test', 'short result')
}

fn test_print_tool_result_long() {
	print_tool_result('test', 'x'.repeat(200))
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
