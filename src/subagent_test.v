module main

// subagent_test.v - sub-agent 系统的单元测试
// 只测试 profile / spec / result / host / spec_from_input 这些纯数据结构与解析逻辑。
// 真正的 chat() 调用需要 API key，在 integration_test.sh 里跑（需要 --with-api）。

// helper：构造 map[string]string（V 不支持 inline kv init）
fn mk_input(kvs ...string) map[string]string {
	mut m := map[string]string{}
	for i := 0; i + 1 < kvs.len; i += 2 {
		m[kvs[i]] = kvs[i + 1]
	}
	return m
}

// ===== profile =====

fn test_profile_coder_has_prompt_and_defaults() {
	p := subagent_profile(.coder)
	assert p.kind == .coder
	assert p.system_prompt.len > 0
	assert p.max_rounds > 0
	assert p.max_tokens > 0
	assert p.timeout_ms > 0
}

fn test_profile_explore_is_readonly() {
	p := subagent_profile(.explore)
	assert p.kind == .explore
	assert 'write_file' !in p.enable_tools
	assert 'bash' !in p.enable_tools
	assert 'run_command' !in p.enable_tools
	assert 'read_file' in p.enable_tools
	assert 'list_dir' in p.enable_tools
	assert p.system_prompt.contains('只读')
}

fn test_profile_plan_is_readonly() {
	p := subagent_profile(.plan)
	assert p.kind == .plan
	assert 'write_file' !in p.enable_tools
	assert 'bash' !in p.enable_tools
	assert 'edit_file' !in p.enable_tools
	assert 'read_file' in p.enable_tools
	assert p.system_prompt.contains('规划')
}

// ===== profile name <-> kind 互转 =====

fn test_profile_name_roundtrip() {
	assert subagent_profile_name(.coder) == 'coder'
	assert subagent_profile_name(.explore) == 'explore'
	assert subagent_profile_name(.plan) == 'plan'
	assert subagent_profile_from_name('Coder') == .coder
	assert subagent_profile_from_name('EXPLORE') == .explore
	assert subagent_profile_from_name('plan') == .plan
	assert subagent_profile_from_name('unknown') == .coder // 兜底
}

// ===== SubagentSpec 默认值 =====

fn test_spec_defaults() {
	mut spec := SubagentSpec{
		prompt: 'test'
	}
	assert spec.profile == .coder
	assert spec.depth == 1
	assert spec.model == ''
	assert spec.parent_exec == ''
}

// ===== SubagentResult 序列化 =====

fn test_result_status_name() {
	assert subagent_status_name(.running) == 'running'
	assert subagent_status_name(.completed) == 'completed'
	assert subagent_status_name(.failed) == 'failed'
	assert subagent_status_name(.timeout) == 'timeout'
	assert subagent_status_name(.aborted) == 'aborted'
}

fn test_result_is_terminal() {
	r1 := SubagentResult{
		status: .running
	}
	assert !r1.is_terminal()
	r2 := SubagentResult{
		status: .completed
	}
	assert r2.is_terminal()
	r3 := SubagentResult{
		status: .failed
	}
	assert r3.is_terminal()
}

fn test_result_to_json_contains_required_fields() {
	r := SubagentResult{
		exec_id:         'subagent_1_test'
		profile:         .coder
		status:          .completed
		summary:         '完成了 foo 的修复'
		duration_ms:     1234
		trajectory_path: '/tmp/traj.json'
	}
	json := r.to_json()
	assert json.contains('"exec_id":"subagent_1_test"')
	assert json.contains('"profile":"coder"')
	assert json.contains('"status":"completed"')
	assert json.contains('"summary":"完成了 foo 的修复"')
	assert json.contains('"duration_ms":1234')
	assert json.contains('"trajectory_path":"/tmp/traj.json"')
}

fn test_result_short_string() {
	r := SubagentResult{
		profile:     .explore
		status:      .completed
		summary:     '我发现 src/tools.v 是工具中心，4660 行'
		duration_ms: 5000
	}
	s := r.short_string()
	assert s.contains('[explore completed 5s]')
	assert s.contains('4660 行')
}

// ===== SubagentHost 构造 =====

fn test_host_construction_uses_default_concurrency() {
	mut cfg := default_config()
	cfg.subagent_max_concurrency = 0 // 测试兜底
	h := new_subagent_host(cfg, '/tmp/traj')
	assert h.next_exec_id == 1
}

fn test_host_construction_respects_config_concurrency() {
	mut cfg := default_config()
	cfg.subagent_max_concurrency = 3
	h := new_subagent_host(cfg, '/tmp/traj')
	// semaphore 容量不可直接读，但 next_exec_id 与 active_children 应就绪
	assert h.next_exec_id == 1
	assert h.active_children.len == 0
}

// ===== subagent_spec_from_input 解析 =====

fn test_spec_from_input_minimal() {
	input := mk_input('prompt', '看一下 src/skills.v')
	spec := subagent_spec_from_input(input, 1, 'parent_exec_1') or {
		assert false, err.msg()
		return
	}
	assert spec.prompt == '看一下 src/skills.v'
	assert spec.profile == .coder
	assert spec.depth == 1
	assert spec.parent_exec == 'parent_exec_1'
}

fn test_spec_from_input_full() {
	input := mk_input('prompt', '跑测试', 'profile', 'explore', 'model', 'MiniMax-M3',
		'max_tokens', '8192', 'max_rounds', '40', 'timeout_ms', '120000')
	spec := subagent_spec_from_input(input, 2, 'p1') or {
		assert false, err.msg()
		return
	}
	assert spec.profile == .explore
	assert spec.model == 'MiniMax-M3'
	assert spec.max_tokens == 8192
	assert spec.max_rounds == 40
	assert spec.timeout_ms == 120000
	assert spec.depth == 2
}

fn test_spec_from_input_rejects_empty_prompt() {
	input := mk_input('prompt', '')
	_ := subagent_spec_from_input(input, 1, '') or { return }
	assert false, 'expected error for empty prompt'
}

fn test_spec_from_input_rejects_missing_prompt() {
	input := mk_input('profile', 'coder')
	_ := subagent_spec_from_input(input, 1, '') or { return }
	assert false, 'expected error for missing prompt'
}

// ===== swarm_specs_from_input 解析 =====

fn test_swarm_specs_simple_items() {
	input := mk_input('prompt_template', '总结 {{item}} 这个模块', 'items',
		'["src/skills.v", "src/tools.v", "src/agent.v"]', 'profile', 'explore')
	specs := swarm_specs_from_input(input) or {
		assert false, err.msg()
		return
	}
	assert specs.len == 3
	assert specs[0].prompt == '总结 src/skills.v 这个模块'
	assert specs[1].prompt == '总结 src/tools.v 这个模块'
	assert specs[2].prompt == '总结 src/agent.v 这个模块'
	assert specs[0].profile == .explore
	assert specs[0].depth == 1
}

fn test_swarm_specs_single_item() {
	input := mk_input('prompt_template', '查看 {{item}}', 'items', '"src/main.v"', 'profile',
		'coder')
	specs := swarm_specs_from_input(input) or {
		assert false, err.msg()
		return
	}
	assert specs.len == 1
	assert specs[0].prompt == '查看 src/main.v'
}

fn test_swarm_specs_rejects_missing_template() {
	input := mk_input('items', '["a"]')
	_ := swarm_specs_from_input(input) or { return }
	assert false, 'expected error for missing prompt_template'
}

fn test_swarm_specs_rejects_missing_items() {
	input := mk_input('prompt_template', 'x {{item}}')
	_ := swarm_specs_from_input(input) or { return }
	assert false, 'expected error for missing items'
}

// ===== depth limit =====

fn test_depth_limit_exceeded_marks_failed() {
	mut cfg := default_config()
	cfg.subagent_max_depth = 2
	cfg.api_key = 'sk-test' // 不需要真打 API；depth check 在 chat() 之前
	cfg.subagent_default_timeout_ms = 1000

	mut h := new_subagent_host(cfg, '/tmp/traj_test')
	spec := SubagentSpec{
		profile: .coder
		prompt:  'should fail'
		depth:   5
	}
	res := h.run(spec)
	assert res.status == .failed
	assert res.error.contains('depth')
	assert res.duration_ms >= 0
}
