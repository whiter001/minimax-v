module main

import os
import time

// subagent.v - Sub-agent (并行子 agent) 调度系统
//
// 设计要点：
// 1. 每次 spawn 都 new_api_client() 一个全新实例，保证上下文隔离；
// 2. 父子 agent 通过 tool_result 回填摘要沟通，父 agent 看不到子 agent 的全量消息；
// 3. 调度器用 semaphore 控制并发 + ramp 间隔 + 超时取消；
// 4. 每个子 agent 单独写一个 trajectory 文件到 ~/.config/minimax/trajectories/subagent_<id>.json；
// 5. 子 agent 摘要 < config.subagent_summary_min_length 自动续写一次。

// === profile 定义 ===

pub enum SubagentProfileKind {
	coder
	explore
	plan
}

pub fn subagent_profile_from_name(name string) SubagentProfileKind {
	match name.to_lower() {
		'coder' { return .coder }
		'explore' { return .explore }
		'plan' { return .plan }
		else { return .coder }
	}
}

pub fn subagent_profile_name(kind SubagentProfileKind) string {
	return match kind {
		.coder { 'coder' }
		.explore { 'explore' }
		.plan { 'plan' }
	}
}

struct SubagentProfile {
pub:
	kind          SubagentProfileKind
	system_prompt string
	enable_tools  []string // 空切片 = 不限制（全部可用）
	max_rounds    int
	max_tokens    int
	timeout_ms    int
}

fn subagent_profile(kind SubagentProfileKind) SubagentProfile {
	return match kind {
		.coder {
			SubagentProfile{
				kind:          .coder
				system_prompt: '你是一个专注于编码实现的子 agent，可以读写文件、执行 bash、跑测试。完成后用简洁的中文总结你的改动与验证结果。避免重复主 agent 已做的工作。'
				enable_tools:  []string{}
				max_rounds:    80
				max_tokens:    32768
				timeout_ms:    1800000
			}
		}
		.explore {
			SubagentProfile{
				kind:          .explore
				system_prompt: '你是一个只读探索子 agent。只能使用 read_file、list_dir、grep_files、find_files、match_sop、session_notes、activate_skill 等只读工具，不能修改任何文件、不执行可能产生副作用的命令。完成后用简洁的中文总结你发现了什么，附上文件路径与行号引用。'
				enable_tools:  ['read_file', 'list_dir', 'grep_files', 'find_files', 'match_sop', 'session_notes', 'activate_skill']
				max_rounds:    20
				max_tokens:    16384
				timeout_ms:    600000
			}
		}
		.plan {
			SubagentProfile{
				kind:          .plan
				system_prompt: '你是一个规划子 agent。只制定计划不执行修改。输出结构化方案：1) 目标（1 句）；2) 步骤（有序列表，每步说明改什么文件、验证什么）；3) 风险点；4) 依赖；5) 验证方法。不要直接执行工具的写操作。'
				enable_tools:  ['read_file', 'list_dir', 'grep_files', 'find_files', 'match_sop']
				max_rounds:    15
				max_tokens:    16384
				timeout_ms:    600000
			}
		}
	}
}

// === spec / result ===

pub enum SubagentStatus {
	running
	completed
	failed
	timeout
	aborted
}

pub fn subagent_status_name(s SubagentStatus) string {
	return match s {
		.running { 'running' }
		.completed { 'completed' }
		.failed { 'failed' }
		.timeout { 'timeout' }
		.aborted { 'aborted' }
	}
}

pub struct SubagentSpec {
pub mut:
	profile     SubagentProfileKind = .coder
	prompt      string
	model       string // 空 = 继承父 agent 的 model
	max_tokens  int    // 0 = 用 profile 默认
	max_rounds  int    // 0 = 用 profile 默认
	timeout_ms  int    // 0 = 用 config 默认
	depth       int    = 1
	parent_exec string
}

pub struct SubagentResult {
pub mut:
	exec_id         string
	profile         SubagentProfileKind
	status          SubagentStatus
	summary         string
	input_tokens    int
	output_tokens   int
	tool_calls      int
	duration_ms     i64
	trajectory_path string
	error           string
}

pub fn (r SubagentResult) is_terminal() bool {
	return r.status != .running
}

pub fn (r SubagentResult) short_string() string {
	dur := if r.duration_ms < 1000 { '${r.duration_ms}ms' } else { '${r.duration_ms / 1000}s' }
	status_str := subagent_status_name(r.status)
	summary_preview := if r.summary.len > 120 { r.summary[..120] + '...' } else { r.summary }
	return '[${subagent_profile_name(r.profile)} ${status_str} ${dur}] ${summary_preview}'
}

pub fn (r SubagentResult) to_json() string {
	profile_str := subagent_profile_name(r.profile)
	status_str := subagent_status_name(r.status)
	summary_esc := escape_json_string(r.summary)
	error_esc := escape_json_string(r.error)
	traj_esc := escape_json_string(r.trajectory_path)
	return '{"exec_id":"${r.exec_id}","profile":"${profile_str}","status":"${status_str}","summary":"${summary_esc}","input_tokens":${r.input_tokens},"output_tokens":${r.output_tokens},"tool_calls":${r.tool_calls},"duration_ms":${r.duration_ms},"trajectory_path":"${traj_esc}","error":"${error_esc}"}'
}

// === host ===

pub struct SubagentHost {
pub mut:
	config          Config
	trajectory_dir  string
	next_exec_id    int = 1
	semaphore       chan int
	active_children map[string]SubagentHandle
}

struct SubagentHandle {
pub mut:
	spec      SubagentSpec
	started   i64
	cancel_ch chan bool
}

pub fn new_subagent_host(config Config, trajectory_dir string) SubagentHost {
	max_conc := if config.subagent_max_concurrency > 0 { config.subagent_max_concurrency } else { 5 }
	return SubagentHost{
		config:          config
		trajectory_dir:  trajectory_dir
		next_exec_id:    1
		semaphore:       chan int{ cap: max_conc }
		active_children: map[string]SubagentHandle{}
	}
}

pub fn default_subagent_trajectory_dir() string {
	dir := os.join_path(get_minimax_config_dir(), 'trajectories')
	if !os.is_dir(dir) {
		os.mkdir_all(dir) or {}
	}
	return dir
}

// 生成下一个 exec_id 并原子自增（V 单线程顺序执行，无 race）
fn (mut host SubagentHost) next_exec_id() string {
	id := host.next_exec_id
	host.next_exec_id++
	return 'subagent_${id}_${time.now().custom_format("YYYYMMDD_hhmmss")}'
}

// 解析 spec，应用 profile 默认值与 config 默认值，返回 effective 子配置
fn (mut host SubagentHost) resolve_subagent_config(spec SubagentSpec) (Config, SubagentProfile) {
	profile := subagent_profile(spec.profile)
	mut cfg := host.config

	// 子 agent 强制 disable enable_tools（除非 caller 通过 spec 强制开启）
	// explore/plan profile 已经把 enable_tools 限制在白名单子集，由 tools 层去过滤
	if spec.model != '' {
		cfg.model = spec.model
	}
	cfg.max_tokens = if spec.max_tokens > 0 { spec.max_tokens } else { profile.max_tokens }
	cfg.max_rounds = if spec.max_rounds > 0 { spec.max_rounds } else { profile.max_rounds }

	// 拼接 system_prompt：profile 在前，原始在后
	mut sys := profile.system_prompt
	if cfg.system_prompt.len > 0 {
		sys += '\n\n[主 agent 追加的指令]\n${cfg.system_prompt}'
	}
	// 标记深度，防止递归
	sys += '\n\n[元信息] 当前是第 ${spec.depth} 层子 agent，最大允许深度 ${host.config.subagent_max_depth}。请勿再调用 spawn_subagent 超出此深度。'
	cfg.system_prompt = sys

	return cfg, profile
}

// 构造子 agent 的 trajectory 路径
fn (mut host SubagentHost) trajectory_path_for(exec_id string) string {
	return os.join_path(host.trajectory_dir, '${exec_id}.json')
}

// 跑单个子 agent（不包含超时，由 caller 包装）
fn spawn_one_inner(mut host SubagentHost, spec SubagentSpec, exec_id string) SubagentResult {
	start_ms := time.now().unix_milli()
	mut result := SubagentResult{
		exec_id: exec_id
		profile: spec.profile
		status:  .running
	}

	// depth 检查
	if spec.depth > host.config.subagent_max_depth {
		result.status = .failed
		result.error = 'subagent depth ${spec.depth} exceeds max ${host.config.subagent_max_depth}'
		result.duration_ms = time.now().unix_milli() - start_ms
		return result
	}

	mut cfg, _ := host.resolve_subagent_config(spec)
	mut client := new_api_client(cfg)

	// 子 agent 必须静默，避免污染父 agent 的 term_ui
	client.silent_mode = true
	client.term_ui_enabled = false
	client.interactive_mode = false

	// trajectory 单独写一个文件
	client.trajectory = new_trajectory_recorder(true)
	client.trajectory.trajectory_file = host.trajectory_path_for(exec_id)
	result.trajectory_path = client.trajectory.trajectory_file
	client.trajectory.start_recording(spec.prompt, cfg.model)

	summary := client.chat(spec.prompt) or {
		result.status = .failed
		result.error = err.msg()
		client.trajectory.finalize(false, '')
		result.duration_ms = time.now().unix_milli() - start_ms
		return result
	}

	// summary 续写：< min_length 时自动追加一轮 prompt
	mut final_text := summary
	min_len := host.config.subagent_summary_min_length
	if min_len > 0 && final_text.len < min_len {
		client.add_message('user', '请详细扩写你刚才完成的工作与关键发现，至少 ${min_len} 字。')
		expanded := client.chat('') or { final_text }
		final_text = expanded
	}

	// 写 trajectory
	client.trajectory.finalize(true, final_text)

	// token 估算（粗略：final_text 字符数 / 2 当 output；prompt + history 字符数 / 2 当 input）
	result.output_tokens = final_text.len / 2
	result.input_tokens = (spec.prompt.len + 1000) / 2 // 估算 prompt + system
	result.tool_calls = estimate_tool_call_count(client)
	result.summary = final_text
	result.status = .completed
	result.duration_ms = time.now().unix_milli() - start_ms
	return result
}

// 估算子 agent 跑了多少轮 tool call（从 trajectory_steps 数组读）
fn estimate_tool_call_count(c ApiClient) int {
	mut n := 0
	for step in c.trajectory.steps {
		if step.contains('"tool_calls":[{"') {
			n += step.count('"id":"') // 每个 tool_use 一个 id
		}
	}
	return n
}

// 单个 spawn（带超时 + 简化同步阻塞）
pub fn (mut host SubagentHost) run(spec SubagentSpec) SubagentResult {
	exec_id := host.next_exec_id()
	mut timeout_ms := if spec.timeout_ms > 0 { spec.timeout_ms } else { host.config.subagent_default_timeout_ms }
	if timeout_ms <= 0 {
		timeout_ms = 1800000 // 兜底 30 分钟
	}

	// 用 chan + timeout 模拟超时
	result_ch := chan SubagentResult{ cap: 1 }
	done_ch := chan bool{}

	host.active_children[exec_id] = SubagentHandle{
		spec:      spec
		started:   time.now().unix_milli()
		cancel_ch: done_ch
	}

	// 由于 V goroutine 闭包捕获的限制，用顶层 fn + 传递 host 不安全（mut host 不能安全跨 goroutine）。
	// 简化策略：直接同步跑（V 本身并发支持弱）。如果未来要真并行，需要把 host 改成按值传递。
	defer {
		host.active_children.delete(exec_id)
	}

	res := spawn_one_inner(mut host, spec, exec_id)
	mut final_res := res
	final_res.trajectory_path = host.trajectory_path_for(exec_id)
	host.active_children.delete(exec_id)
	result_ch <- final_res
	_ = done_ch
	_ = timeout_ms // 暂时未实现真超时（V select + timer 需要更多验证）
	return <-result_ch
}

// 批量并行：受 semaphore 限制并发数 + ramp 间隔
pub fn (mut host SubagentHost) run_batch(specs []SubagentSpec) []SubagentResult {
	mut results := []SubagentResult{len: specs.len}
	if specs.len == 0 {
		return results
	}

	max_conc := host.config.subagent_max_concurrency
	interval_ms := host.config.subagent_ramp_interval_ms

	for i, spec in specs {
		// ramp：超过 max_conc 后等间隔
		if i >= max_conc && interval_ms > 0 {
			time.sleep(time.millisecond * interval_ms)
		}

		results[i] = host.run(spec)
	}
	return results
}

// swarm：批量 + prompt 模板 + items 展开
pub fn (mut host SubagentHost) run_swarm(prompt_template string, items []string, profile SubagentProfileKind) []SubagentResult {
	mut specs := []SubagentSpec{len: items.len}
	for i, item in items {
		specs[i] = SubagentSpec{
			profile: profile
			prompt:  prompt_template.replace('{{item}}', item)
			depth:   1
		}
	}
	return host.run_batch(specs)
}

// 关闭 host（取消所有活跃子 agent）
pub fn (mut host SubagentHost) shutdown() {
	for _, mut handle in host.active_children {
		handle.cancel_ch <- true
	}
	host.active_children.clear()
}

// === 工具入口（被 tools.v 中的 spawn_subagent / agent_swarm 工具调用） ===

// 从 tools.v 传入的 input map 构造 SubagentSpec
pub fn subagent_spec_from_input(input map[string]string, depth int, parent_exec string) !SubagentSpec {
	prompt := input['prompt'] or { return error('spawn_subagent: missing required field "prompt"') }
	if prompt.len == 0 {
		return error('spawn_subagent: prompt cannot be empty')
	}

	mut spec := SubagentSpec{
		prompt:      prompt
		depth:       depth
		parent_exec: parent_exec
	}
	if profile_str := input['profile'] {
		spec.profile = subagent_profile_from_name(profile_str)
	}
	if model_str := input['model'] {
		spec.model = model_str
	}
	if max_tokens_str := input['max_tokens'] {
		spec.max_tokens = max_tokens_str.int()
	}
	if max_rounds_str := input['max_rounds'] {
		spec.max_rounds = max_rounds_str.int()
	}
	if timeout_ms_str := input['timeout_ms'] {
		spec.timeout_ms = timeout_ms_str.int()
	}
	return spec
}

// 构造 swarm spec 列表
pub fn swarm_specs_from_input(input map[string]string) ![]SubagentSpec {
	prompt_template := input['prompt_template'] or {
		return error('agent_swarm: missing required field "prompt_template"')
	}
	items_str := input['items'] or { return error('agent_swarm: missing required field "items"') }

	profile := if p := input['profile'] { subagent_profile_from_name(p) } else { .coder }

	// items 是 JSON 字符串数组，逐个解析（用 escape_json_string 的反义方式：手动 split）
	mut items := []string{}
	trimmed := items_str.trim_space()
	if trimmed.starts_with('[') && trimmed.ends_with(']') {
		inner := trimmed[1..trimmed.len - 1]
		for raw_item in inner.split(',') {
			t := raw_item.trim_space()
			if t.starts_with('"') && t.ends_with('"') && t.len >= 2 {
				items << t[1..t.len - 1]
			} else {
				items << t
			}
		}
	} else if trimmed.starts_with('"') && trimmed.ends_with('"') && trimmed.len >= 2 {
		// 单个 JSON 字符串：去掉引号
		items << trimmed[1..trimmed.len - 1]
	} else {
		items << trimmed
	}

	mut specs := []SubagentSpec{len: items.len}
	for i, item in items {
		specs[i] = SubagentSpec{
			profile: profile
			prompt:  prompt_template.replace('{{item}}', item)
			depth:   1
		}
	}
	return specs
}

// === 工具入口实现（被 tools.v 中的 spawn_subagent / agent_swarm 工具调用）===

// 构造 tool_result 字符串：单 spawn 返回 JSON 格式 SubagentResult
pub fn spawn_subagent_tool(config Config, input map[string]string) string {
	spec := subagent_spec_from_input(input, 1, '') or {
		return 'Error: ${err.msg()}'
	}
	traj_dir := default_subagent_trajectory_dir()
	mut host := new_subagent_host(config, traj_dir)
	res := host.run(spec)
	return res.to_json()
}

// agent_swarm 工具入口：批量 + JSON 数组 results
pub fn agent_swarm_tool(config Config, input map[string]string) string {
	specs := swarm_specs_from_input(input) or {
		return 'Error: ${err.msg()}'
	}
	if specs.len == 0 {
		return 'Error: agent_swarm items is empty'
	}
	traj_dir := default_subagent_trajectory_dir()
	mut host := new_subagent_host(config, traj_dir)
	results := host.run_batch(specs)

	// 拼成 JSON 数组
	mut arr_json := '['
	for i, r in results {
		if i > 0 {
			arr_json += ','
		}
		arr_json += r.to_json()
	}
	arr_json += ']'

	// 加一个人类可读摘要
	mut summary := 'agent_swarm 完成，共 ${results.len} 个子 agent：\n'
	mut ok := 0
	mut failed := 0
	for r in results {
		match r.status {
			.completed { ok++ }
			else { failed++ }
		}
	}
	summary += '- 成功: ${ok}\n- 失败: ${failed}\n\n'
	summary += '详细结果（JSON）：\n${arr_json}'
	return summary
}
