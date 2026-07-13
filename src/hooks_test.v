module main

import os
import time

fn make_test_engine(defs []HookDef) HookEngine {
	return HookEngine{
		defs:       defs
		cwd:        os.getwd()
		session_id: 'test-session'
		debug:      false
	}
}

fn hooks_require_bash() bool {
	if find_bash_path().len == 0 {
		eprintln('bash not found; skipping hook execution test')
		return false
	}
	return true
}

fn test_hooks_config_load_valid_and_invalid() {
	dir := os.join_path(os.temp_dir(), 'minimax_hooks_test_${os.getpid()}')
	os.mkdir_all(dir) or { return }
	defer {
		os.rmdir_all(dir) or {}
	}
	path := os.join_path(dir, 'hooks.json')
	os.write_file(path,
		'{"hooks":[{"event":"PreToolUse","matcher":"bash","command":"echo ok"},{"event":"BogusEvent","command":"echo no"},{"event":"Stop","command":"echo s","timeout":9999},{"event":"PostToolUse","command":""}]}') or {
		assert false, 'write failed'
		return
	}
	cfg := load_hooks_config(path)
	assert cfg.hooks.len == 2, 'expected 2 valid hooks, got ${cfg.hooks.len}'
	assert cfg.hooks[0].event == 'PreToolUse'
	assert cfg.hooks[0].timeout == 30, 'default timeout expected, got ${cfg.hooks[0].timeout}'
	assert cfg.hooks[1].event == 'Stop'
	assert cfg.hooks[1].timeout == 600, 'timeout should be clamped to 600, got ${cfg.hooks[1].timeout}'
}

fn test_hooks_config_missing_file() {
	cfg := load_hooks_config(os.join_path(os.temp_dir(),
		'minimax_hooks_test_not_exist_${os.getpid()}.json'))
	assert cfg.hooks.len == 0
}

fn test_hook_matcher_matches() {
	assert hook_matcher_matches('', 'anything')
	assert hook_matcher_matches('bash', 'bash')
	assert !hook_matcher_matches('bash', 'read_file')
	assert hook_matcher_matches('write', 'write_file')
	assert !hook_matcher_matches('Bash', 'bash')
}

fn test_hook_engine_matching_defs() {
	engine := make_test_engine([
		HookDef{
			event:   'PreToolUse'
			matcher: 'bash'
			command: 'echo a'
		},
		HookDef{
			event:   'PreToolUse'
			command: 'echo all'
		},
		HookDef{
			event:   'PostToolUse'
			command: 'echo post'
		},
	])
	assert engine.matching_defs('PreToolUse', 'bash').len == 2
	assert engine.matching_defs('PreToolUse', 'read_file').len == 1
	assert engine.matching_defs('PostToolUse', 'bash').len == 1
	assert engine.matching_defs('Stop', '').len == 0
	assert engine.enabled()
	assert !make_test_engine([]HookDef{}).enabled()
}

fn test_hook_block_exit_code_2() {
	if !hooks_require_bash() {
		return
	}
	engine := make_test_engine([
		HookDef{
			event:   'PreToolUse'
			command: 'echo "no deletion allowed" >&2; exit 2'
			timeout: 10
		},
	])
	blocked, reason := engine.trigger_block('PreToolUse', 'bash', {})
	assert blocked
	assert reason.contains('no deletion allowed'), 'reason was: ${reason}'
}

fn test_hook_allow_and_fail_open() {
	if !hooks_require_bash() {
		return
	}
	// exit 0 allows.
	engine := make_test_engine([
		HookDef{
			event:   'PreToolUse'
			command: 'exit 0'
			timeout: 10
		},
	])
	blocked, _ := engine.trigger_block('PreToolUse', 'bash', {})
	assert !blocked
	// Non-zero, non-2 exit codes fail open.
	engine2 := make_test_engine([
		HookDef{
			event:   'PreToolUse'
			command: 'exit 1'
			timeout: 10
		},
	])
	blocked2, _ := engine2.trigger_block('PreToolUse', 'bash', {})
	assert !blocked2
	// Missing binary fails open.
	engine3 := make_test_engine([
		HookDef{
			event:   'PreToolUse'
			command: 'this_command_does_not_exist_xyz'
			timeout: 10
		},
	])
	blocked3, _ := engine3.trigger_block('PreToolUse', 'bash', {})
	assert !blocked3
}

fn test_hook_timeout_fails_open_fast() {
	if !hooks_require_bash() {
		return
	}
	engine := make_test_engine([
		HookDef{
			event:   'Stop'
			command: 'sleep 5'
			timeout: 1
		},
	])
	start := time.now().unix_milli()
	blocked, _ := engine.trigger_block('Stop', '', {})
	elapsed := time.now().unix_milli() - start
	assert !blocked
	assert elapsed < 10000, 'timeout hook took too long: ${elapsed}ms'
}

fn test_hook_receives_payload_file() {
	if !hooks_require_bash() {
		return
	}
	engine := make_test_engine([
		HookDef{
			event:   'PreToolUse'
			command: 'grep -q "\\"tool_name\\":\\"bash\\"" "$MINIMAX_HOOK_INPUT" && exit 2 || exit 0'
			timeout: 10
		},
	])
	blocked, _ := engine.trigger_block('PreToolUse', 'bash', {
		'tool_name': 'bash'
	})
	assert blocked, 'hook should see tool_name=bash in payload'
}

fn test_build_hook_payload_escapes() {
	payload := build_hook_payload('PreToolUse', 's1', 'C:\\work', {
		'tool_input': 'line1\nline2 "quoted"'
	})
	assert payload.contains('"hook_event_name":"PreToolUse"')
	assert payload.contains('line1\\nline2')
	assert payload.contains('\\"quoted\\"')
	assert payload.contains('C:\\\\work')
}
