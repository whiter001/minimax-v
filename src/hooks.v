module main

import json
import os
import time

// hooks.v - 用户自定义钩子机制
//
// 设计要点：
// 1. 配置文件 ~/.config/minimax/hooks.json，声明 event/matcher/command/timeout；
// 2. 支持 9 个事件，其中 UserPromptSubmit / PreToolUse / Stop 可阻断
//    （hook 命令退出码 2 = deny，stderr 作为原因），其余为通知型（结果忽略）；
// 3. hook 命令通过 bash 执行，payload JSON 写入临时文件并通过环境变量
//    MINIMAX_HOOK_INPUT 传入（V 的 os.Process 无法关闭子进程 stdin，
//    走 stdin 会让 `cat` 类脚本挂起）；
// 4. 除退出码 2 外一律 fail-open：hook 崩溃/超时/不存在都不影响主流程，
//    安全护栏只在你明确 exit 2 时生效。

const hook_event_types = ['UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'PostToolUseFailure',
	'Stop', 'SessionStart', 'SessionEnd', 'PreCompact', 'PostCompact']

const hook_default_timeout_s = 30

struct HookDef {
pub mut:
	event   string
	matcher string
	command string
	timeout int // 秒，默认 30，范围 1-600
}

struct HooksFileConfig {
pub mut:
	hooks []HookDef
}

struct HookEngine {
pub mut:
	defs       []HookDef
	cwd        string
	session_id string
	debug      bool
}

fn get_hooks_config_path() string {
	return os.join_path(get_minimax_config_dir(), 'hooks.json')
}

// load_hooks_config reads and validates a hooks.json file.
// Missing/invalid files yield an empty config (hooks disabled).
fn load_hooks_config(path string) HooksFileConfig {
	if !os.is_file(path) {
		return HooksFileConfig{}
	}
	content := os.read_file(path) or { return HooksFileConfig{} }
	cfg := json.decode(HooksFileConfig, content) or { return HooksFileConfig{} }
	mut valid := []HookDef{}
	for def in cfg.hooks {
		if def.event !in hook_event_types {
			eprintln('[hooks] 跳过未知事件类型: ${def.event}')
			continue
		}
		if def.command.trim_space().len == 0 {
			eprintln('[hooks] 跳过缺少 command 的 ${def.event} 规则')
			continue
		}
		mut d := def
		if d.timeout <= 0 {
			d.timeout = hook_default_timeout_s
		}
		if d.timeout > 600 {
			d.timeout = 600
		}
		valid << d
	}
	return HooksFileConfig{
		hooks: valid
	}
}

fn new_hook_engine(debug bool) HookEngine {
	cfg := load_hooks_config(get_hooks_config_path())
	return HookEngine{
		defs:       cfg.hooks
		cwd:        os.getwd()
		session_id: '${os.getpid()}_${time.now().unix_milli()}'
		debug:      debug
	}
}

fn (e HookEngine) enabled() bool {
	return e.defs.len > 0
}

// hook_matcher_matches tests a hook matcher against the event's match value.
// Empty matcher matches everything; otherwise it's a case-sensitive substring
// match (V's builtin regex flavor is too limited to expose to end users).
fn hook_matcher_matches(matcher string, value string) bool {
	if matcher.len == 0 {
		return true
	}
	return value.contains(matcher)
}

fn (e HookEngine) matching_defs(event string, match_value string) []HookDef {
	mut out := []HookDef{}
	for def in e.defs {
		if def.event == event && hook_matcher_matches(def.matcher, match_value) {
			out << def
		}
	}
	return out
}

// build_hook_payload assembles the JSON payload passed to the hook command.
fn build_hook_payload(event string, session_id string, cwd string, extra map[string]string) string {
	mut parts := ['"hook_event_name":"${event}"', '"session_id":"${escape_json_string(session_id)}"',
		'"cwd":"${escape_json_string(cwd)}"']
	for key, val in extra {
		parts << '"${escape_json_string(key)}":"${escape_json_string(val)}"'
	}
	return '{${parts.join(',')}}'
}

// run_hook_command executes command through bash with the payload in a temp
// file (env MINIMAX_HOOK_INPUT), returning (exit_code, stdout, stderr).
// Returns exit code -1 on spawn failure or timeout.
fn run_hook_command(command string, payload string, timeout_s int, cwd string) (int, string, string) {
	bash_path := find_bash_path()
	if bash_path.len == 0 {
		return -1, '', 'bash not found; hooks require bash'
	}
	input_path := os.join_path(os.temp_dir(),
		'minimax_hook_${os.getpid()}_${time.now().unix_milli()}.json')
	os.write_file(input_path, payload) or { return -1, '', 'failed to write hook input file' }
	defer {
		os.rm(input_path) or {}
	}

	mut full_env := os.environ()
	full_env['MINIMAX_HOOK_INPUT'] = input_path

	mut p := os.new_process(bash_path)
	p.set_args(['-c', command])
	p.set_redirect_stdio()
	p.set_environment(full_env)
	if cwd.len > 0 && os.is_dir(cwd) {
		p.set_work_folder(cwd)
	}
	p.use_pgroup = true
	p.create_no_window = true
	p.run()
	if p.status != .running {
		return -1, '', 'failed to start hook command: ${p.err}'
	}

	deadline := time.now().unix_milli() + i64(timeout_s) * 1000
	for p.is_alive() {
		if time.now().unix_milli() >= deadline {
			p.signal_pgkill()
			p.wait()
			// Non-blocking drain: grandchildren may hold the pipes open, so
			// slurp (which blocks until EOF) is not an option here.
			out, err_out := drain_process_pipes(mut p)
			p.close()
			return -1, out, 'hook timed out after ${timeout_s}s\n${err_out}'
		}
		time.sleep(50 * time.millisecond)
	}
	p.wait()
	exit_code := p.code
	out, err_out := drain_process_pipes(mut p)
	p.close()
	return exit_code, out, err_out
}

// drain_process_pipes reads whatever is available in the child pipes without
// blocking, with a short grace period for final output to arrive after exit.
fn drain_process_pipes(mut p os.Process) (string, string) {
	mut out := ''
	mut err_out := ''
	for _ in 0 .. 20 {
		out += p.stdout_read()
		err_out += p.stderr_read()
		if !p.is_pending(.stdout) && !p.is_pending(.stderr) {
			break
		}
		time.sleep(10 * time.millisecond)
	}
	return out, err_out
}

// trigger_block runs all hooks matching the event and returns (blocked, reason).
// Exit code 2 blocks with stderr as the reason; everything else is fail-open.
fn (e HookEngine) trigger_block(event string, match_value string, extra map[string]string) (bool, string) {
	mut blocked := false
	mut reason := ''
	for def in e.matching_defs(event, match_value) {
		payload := build_hook_payload(event, e.session_id, e.cwd, extra)
		code, out, err_out := run_hook_command(def.command, payload, def.timeout, e.cwd)
		if e.debug {
			eprintln('[hooks] ${event} command=`${def.command}` exit=${code}')
		}
		if code == 2 {
			blocked = true
			r := err_out.trim_space()
			reason = if r.len > 0 { r } else { 'Blocked by ${event} hook' }
			break
		} else if code != 0 && e.debug {
			eprintln('[hooks] ${event} hook failed (fail-open): ${err_out.trim_space()} ${out.trim_space()}')
		}
	}
	return blocked, reason
}

// trigger fires notification hooks whose results are ignored.
fn (e HookEngine) trigger(event string, match_value string, extra map[string]string) {
	for def in e.matching_defs(event, match_value) {
		payload := build_hook_payload(event, e.session_id, e.cwd, extra)
		code, _, err_out := run_hook_command(def.command, payload, def.timeout, e.cwd)
		if e.debug {
			eprintln('[hooks] ${event} command=`${def.command}` exit=${code} ${err_out.trim_space()}')
		}
	}
}

// truncate_hook_preview caps long strings for hook payloads.
fn truncate_hook_preview(s string, limit int) string {
	if s.len <= limit {
		return s
	}
	return s[..limit] + '...[truncated]'
}

// build_tool_input_json serializes a tool input map as a JSON object string.
fn build_tool_input_json(input map[string]string) string {
	mut parts := []string{cap: input.len}
	for key, val in input {
		parts << '"${escape_json_string(key)}":"${escape_json_string(val)}"'
	}
	return '{${parts.join(',')}}'
}
