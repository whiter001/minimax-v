module main

import net.http
import os
import sync.stdatomic
import time

const max_tool_call_rounds = 5000
const max_tool_output_chars = 10000
const tool_failure_escalation_round = 3
const repeated_failed_tool_batch_limit = 3
const repeated_failed_bash_command_limit = 3
const default_agent_prompt = 'You are a helpful AI assistant with access to tools for reading files, writing files, listing directories, and running shell commands.

Guidelines:
- For file operations: Use read_file, write_file, list_dir tools
- For shell commands: Use bash tool (supports &&, ||, pipes, redirects)
- On Windows: use "start URL" to open browser, "start ." to open file explorer
- For downloading web content: use curl or wget in bash
- Break complex tasks into smaller steps
- When a command fails, try alternative approaches
- When the task is complete, ALWAYS call task_done with a brief summary of what was accomplished'

const default_experience_capture_instruction = 'When tools are enabled, consider whether the task produced a reusable lesson worth remembering. Before calling task_done, call record_experience if you verified a stable fix, discovered an environment-specific constraint, established a reliable fallback for a failure mode, or completed a repeatable SOP-worthy workflow. Do not record trivial restatements of the request, obvious facts, or unverified guesses. Keep experience records concise and evidence-based, and usually record at most one or two focused lessons per task.'

__global g_phase_status_visible = u64(0)
__global g_phase_status_generation = u64(0)

@[heap]
struct StreamState {
mut:
	full_text      string
	thinking_text  string
	buffer         string
	raw_body       string // accumulated full SSE body for tool_use parsing
	current_block  string // 'text', 'thinking', or ''
	in_thinking    bool
	show_output    bool // false = silent mode (streaming used internally, no UI output)
	output_started bool
}

struct StreamResult {
	text     string
	thinking string
	raw_body string
}

fn is_tool_error_result(result string) bool {
	return result.starts_with('Error:') || result.starts_with('Exit code:')
}

fn normalize_tool_command(command string) string {
	if command.trim_space().len == 0 {
		return ''
	}
	return command.split_any(' \t\n\r').filter(it.len > 0).join(' ')
}

fn extract_tool_command_head(command string) string {
	trimmed := command.trim_space()
	if trimmed.len == 0 {
		return ''
	}
	if trimmed[0] == `"` || trimmed[0] == `'` {
		quote := trimmed[0]
		for i := 1; i < trimmed.len; i++ {
			if trimmed[i] == quote {
				return trimmed[1..i]
			}
		}
		return trimmed[1..]
	}
	for i := 0; i < trimmed.len; i++ {
		if trimmed[i] in [` `, `\t`, `\n`, `\r`, `;`, `&`, `|`, `>`, `<`] {
			return trimmed[..i]
		}
	}
	return trimmed
}

fn summarize_path_entries(path_value string, focus_terms []string, limit int) string {
	if path_value.len == 0 {
		return ''
	}
	mut entries := []string{}
	for raw_entry in path_value.split(';') {
		entry := raw_entry.trim_space()
		if entry.len > 0 {
			entries << entry
		}
	}
	if entries.len == 0 {
		return ''
	}
	mut focused := []string{}
	for entry in entries {
		lower_entry := entry.to_lower()
		for term in focus_terms {
			if lower_entry.contains(term) {
				focused << entry
				break
			}
		}
	}
	selected := if focused.len > 0 { focused } else { entries }
	max_items := if limit > 0 { limit } else { selected.len }
	end_idx := if max_items < selected.len { max_items } else { selected.len }
	return selected[..end_idx].join(' | ')
}

fn resolve_bash_shell_path() string {
	bash_path := find_bash_path()
	if bash_path.len == 0 {
		return ''
	}
	if bash_path == 'bash' {
		return os.find_abs_path_of_executable('bash') or { 'bash' }
	}
	return bash_path
}

fn resolve_tool_command_path(command_name string) string {
	if command_name.trim_space().len == 0 {
		return ''
	}
	return os.find_abs_path_of_executable(command_name) or { '' }
}

fn build_bash_tool_diagnostic(command string) string {
	normalized := normalize_tool_command(command)
	command_head := extract_tool_command_head(command)
	use_direct := should_use_windows_direct_command(command)
	shell_path := if use_direct {
		resolve_tool_command_path('pwsh')
	} else {
		resolve_bash_shell_path()
	}
	shell_kind := if use_direct {
		'pwsh-direct'
	} else if shell_path.len > 0 {
		'bash'
	} else if os.user_os() == 'windows' {
		'cmd'
	} else {
		'sh'
	}
	path_value := os.getenv_opt('PATH') or { '' }
	path_focus := summarize_path_entries(path_value, ['bun', 'pueue', 'git', 'nu\\bin', 'nu/bin',
		'public'], 8)
	mut parts := [
		'shell=${shell_kind}',
		'cwd=${bash_session.cwd}',
		'session_env=${bash_session.env.len}',
	]
	if shell_path.len > 0 {
		parts << 'shell_path=${shell_path}'
	}
	if use_direct {
		parts << 'route=windows-direct'
	}
	if normalized.len > 0 {
		parts << 'command=${normalized}'
	}
	if command_head.len > 0 {
		parts << 'command_head=${command_head}'
		head_path := resolve_tool_command_path(command_head)
		if head_path.len > 0 {
			parts << 'command_path=${head_path}'
		}
	}
	for probe in ['pueue', 'bun', 'bash'] {
		resolved := resolve_tool_command_path(probe)
		if resolved.len > 0 {
			parts << '${probe}_path=${resolved}'
		} else {
			parts << '${probe}_path=<missing>'
		}
	}
	if path_focus.len > 0 {
		parts << 'path_focus=${path_focus}'
	}
	return parts.join(' | ')
}

fn tool_use_signature(tool ToolUse) string {
	mut keys := tool.input.keys()
	keys.sort()
	mut parts := []string{}
	for key in keys {
		parts << '${key}=${tool.input[key] or { '' }}'
	}
	return '${tool.name}(' + parts.join(',') + ')'
}

fn tool_use_batch_signature(tools []ToolUse) string {
	mut parts := []string{}
	for tool in tools {
		parts << tool_use_signature(tool)
	}
	return parts.join(' | ')
}

fn build_tool_error_results_json(tools []ToolUse, message string) string {
	escaped := escape_json_string(message)
	mut results_json := '['
	for tool in tools {
		results_json += '{"type":"tool_result","tool_use_id":"${tool.id}","content":"${escaped}","is_error":true},'
	}
	if results_json.ends_with(',') {
		results_json = results_json[..results_json.len - 1]
	}
	results_json += ']'
	return results_json
}

fn should_block_repeated_failed_bash_command(tool ToolUse, last_failed_command string, streak int) bool {
	if tool.name != 'bash' {
		return false
	}
	if streak + 1 < repeated_failed_bash_command_limit {
		return false
	}
	command := normalize_tool_command(tool.input['command'] or { '' })
	return command.len > 0 && command == last_failed_command
}

pub struct ChatMessage {
pub mut:
	role         string
	content      string
	content_json string // raw JSON content (for tool_use/tool_result messages)
}

pub struct ApiClient {
pub mut:
	api_key                string
	api_url                string
	messages               []ChatMessage
	model                  string
	temperature            f64
	max_tokens             i32
	max_rounds             int
	token_limit            int
	system_prompt          string
	use_streaming          bool
	enable_tools           bool
	auto_skills            bool
	auto_check_sops        bool
	enable_desktop_control bool
	enable_screen_capture  bool
	debug                  bool
	workspace              string
	logger                 Logger
	mcp_manager            McpManager
	trajectory             TrajectoryRecorder
	plan_mode              bool // Plan mode: draft plan first, execute after user approval
	silent_mode            bool // suppress console output (used by ACP mode)
	interactive_mode       bool // true only in REPL mode where ask_user can safely block for input
}

fn new_api_client(config Config) ApiClient {
	// Initialize global bash session with workspace
	bash_session = new_bash_session(config.workspace)
	return ApiClient{
		api_key:                config.api_key
		api_url:                config.api_url
		messages:               []ChatMessage{}
		model:                  config.model
		temperature:            config.temperature
		max_tokens:             config.max_tokens
		max_rounds:             config.max_rounds
		token_limit:            config.token_limit
		system_prompt:          config.system_prompt
		use_streaming:          false
		enable_tools:           config.enable_tools
		auto_skills:            config.auto_skills
		auto_check_sops:        config.auto_check_sops
		enable_desktop_control: config.enable_desktop_control
		enable_screen_capture:  config.enable_screen_capture
		debug:                  config.debug
		workspace:              config.workspace
		logger:                 new_logger(config.enable_logging)
		trajectory:             new_trajectory_recorder(false)
		silent_mode:            false
		interactive_mode:       false
	}
}

fn (mut c ApiClient) add_message(role string, content string) {
	c.messages << ChatMessage{
		role:    role
		content: content
	}
}

fn (mut c ApiClient) build_request_json() string {
	mut body_json := '{"model":"${c.model}","max_tokens":${c.max_tokens},"temperature":${c.temperature}'

	if c.use_streaming {
		body_json += ',"stream":true'
	}

	if c.enable_tools {
		mut tools_json := get_tools_schema_json()
		// Append MCP tools
		mcp_schema := get_mcp_tools_schema_json(c.mcp_manager.get_all_tools())
		if mcp_schema.len > 0 {
			tools_json = tools_json[..tools_json.len - 1] + ',' + mcp_schema + ']'
		}
		body_json += ',"tools":${tools_json}'
	}

	// Build effective system prompt (with workspace context if set)
	mut effective_system := c.system_prompt
	// Inject default agent prompt when tools enabled and no custom prompt
	if c.enable_tools && effective_system.len == 0 {
		effective_system = default_agent_prompt
	}

	// Plan mode: inject planning instruction
	if c.plan_mode {
		plan_instruction := 'You are currently in PLAN MODE. Before executing any actions:\n1. First analyze the task and create a detailed step-by-step plan\n2. Present the plan to the user for review\n3. Only use the sequentialthinking tool to organize your plan\n4. Use ask_user to confirm the plan before proceeding with execution\n5. After user approval, execute the plan step by step\nDo NOT modify files or run commands until the user has approved your plan.'
		if effective_system.len > 0 {
			effective_system = '${effective_system}\n\n${plan_instruction}'
		} else {
			effective_system = plan_instruction
		}
	}

	// Inject AGENTS.md context (user-level first, then project-level overrides)
	agents_context := load_agents_md(c.workspace)
	if agents_context.len > 0 {
		if effective_system.len > 0 {
			effective_system = '${effective_system}\n\n${agents_context}'
		} else {
			effective_system = agents_context
		}
	}

	// Inject skills metadata so AI can discover and activate skills
	if c.enable_tools {
		skills_meta := build_skills_metadata()
		if skills_meta.len > 0 {
			if effective_system.len > 0 {
				effective_system = '${effective_system}\n\n${skills_meta}'
			} else {
				effective_system = skills_meta
			}
		}
		sops_meta := build_sops_metadata()
		if sops_meta.len > 0 {
			if effective_system.len > 0 {
				effective_system = '${effective_system}\n\n${sops_meta}'
			} else {
				effective_system = sops_meta
			}
		}
		if c.auto_skills {
			auto_skills_instruction := 'When the user task matches one of the available skills, proactively call the activate_skill tool yourself before continuing. Choose the best matching skill without asking the user unless the choice is genuinely ambiguous.'
			if effective_system.len > 0 {
				effective_system = '${effective_system}\n\n${auto_skills_instruction}'
			} else {
				effective_system = auto_skills_instruction
			}
		}
		if c.auto_check_sops && sops_meta.len > 0 {
			auto_sops_instruction := 'Before executing a task, proactively call the match_sop tool with the user task to identify the best matching SOP. If relevant SOPs are returned, follow the suggested_read_order, read the recommended SOP files with the read_file tool, and use them as operating guidance. Do this without asking the user unless multiple SOPs conflict or the match is genuinely unclear. Repository instructions, workspace instructions, and direct user instructions override SOP guidance when they conflict.'
			if effective_system.len > 0 {
				effective_system = '${effective_system}\n\n${auto_sops_instruction}'
			} else {
				effective_system = auto_sops_instruction
			}
		}
		if effective_system.len > 0 {
			effective_system = '${effective_system}\n\n${default_experience_capture_instruction}'
		} else {
			effective_system = default_experience_capture_instruction
		}
		working_checkpoint := get_working_checkpoint_context()
		if working_checkpoint.len > 0 {
			if effective_system.len > 0 {
				effective_system = '${effective_system}\n\n${working_checkpoint}'
			} else {
				effective_system = working_checkpoint
			}
		}
	}

	if c.workspace.len > 0 {
		workspace_ctx := 'Working directory: ${c.workspace}\\nAll relative file paths should be resolved relative to this directory.'
		if effective_system.len > 0 {
			effective_system = '${effective_system}\\n\\n${workspace_ctx}'
		} else {
			effective_system = workspace_ctx
		}
	}

	// system: top-level field per Anthropic spec (tools → system → messages cache order)
	// Add cache_control so the static system prompt is cached as a prefix anchor.
	if effective_system.len > 0 {
		escaped_sys := escape_json_string(effective_system)
		body_json += ',"system":[{"type":"text","text":"${escaped_sys}","cache_control":{"type":"ephemeral"}}]'
	}

	body_json += ',"messages":['

	for i, msg in c.messages {
		mut content_val := ''
		if msg.content_json.len > 0 {
			content_val = msg.content_json
		} else {
			escaped_content := escape_json_string(msg.content)
			content_val = '"${escaped_content}"'
		}
		// Add cache_control on the second-to-last assistant message to cache conversation
		// history prefix (leave the very last user turn outside the cache so it can vary).
		is_cache_anchor := c.messages.len >= 4 && i == c.messages.len - 2 && msg.role == 'assistant'
		if is_cache_anchor {
			// Wrap plain string content into a content block with cache_control
			if !content_val.starts_with('[') {
				body_json += '{"role":"${msg.role}","content":[{"type":"text","text":${content_val},"cache_control":{"type":"ephemeral"}}]},'
			} else {
				body_json += '{"role":"${msg.role}","content":${content_val}},'
			}
		} else {
			body_json += '{"role":"${msg.role}","content":${content_val}},'
		}
	}

	if body_json.ends_with(',') {
		body_json = body_json[..body_json.len - 1]
	}
	body_json += ']}'
	return body_json
}

fn normalize_tool_uses(mut tool_uses []ToolUse) bool {
	mut changed := false
	for i in 0 .. tool_uses.len {
		if tool_uses[i].name == 'browser_wait_for' {
			has_time := (tool_uses[i].input['time'] or { '' }).trim_space().len > 0
			has_text := (tool_uses[i].input['text'] or { '' }).trim_space().len > 0
			has_text_gone := (tool_uses[i].input['textGone'] or { '' }).trim_space().len > 0
			if !has_time && !has_text && !has_text_gone {
				tool_uses[i].input['time'] = '1'
				changed = true
			}
		} else if tool_uses[i].name == 'browser_take_screenshot' {
			if (tool_uses[i].input['type'] or { '' }).trim_space().len == 0 {
				tool_uses[i].input['type'] = 'png'
				changed = true
			}
		} else if tool_uses[i].name == 'browser_console_messages' {
			if (tool_uses[i].input['level'] or { '' }).trim_space().len == 0 {
				tool_uses[i].input['level'] = 'info'
				changed = true
			}
		} else if tool_uses[i].name == 'browser_network_requests' {
			if (tool_uses[i].input['includeStatic'] or { '' }).trim_space().len == 0 {
				tool_uses[i].input['includeStatic'] = 'false'
				changed = true
			}
		}
	}
	return changed
}

fn build_assistant_content_json(text string, thinking string, tool_uses []ToolUse) string {
	mut blocks := []string{}
	if thinking.len > 0 {
		escaped_thinking := escape_json_string(thinking)
		blocks << '{"type":"thinking","thinking":"${escaped_thinking}"}'
	}
	if text.len > 0 {
		escaped_text := escape_json_string(text)
		blocks << '{"type":"text","text":"${escaped_text}"}'
	}
	for tu in tool_uses {
		if tu.id.len == 0 || tu.name.len == 0 {
			continue
		}
		escaped_id := escape_json_string(tu.id)
		escaped_name := escape_json_string(tu.name)
		input_json := build_mcp_args_json(tu.input)
		blocks << '{"type":"tool_use","id":"${escaped_id}","name":"${escaped_name}","input":${input_json}}'
	}
	if blocks.len == 0 {
		return ''
	}
	return '[' + blocks.join(',') + ']'
}

fn message_has_tool_use(msg ChatMessage) bool {
	return msg.role == 'assistant' && msg.content_json.contains('"type":"tool_use"')
}

fn message_has_tool_result(msg ChatMessage) bool {
	return msg.role == 'user' && msg.content_json.contains('"type":"tool_result"')
}

fn unescape_json_text(value string) string {
	return decode_json_string(value)
}

fn extract_tool_result_contents(content_json string) []string {
	mut results := []string{}
	mut search_pos := 0
	for search_pos < content_json.len {
		remaining := content_json[search_pos..]
		if type_idx := remaining.index('"type":"tool_result"') {
			abs_pos := search_pos + type_idx
			after_type := content_json[abs_pos..]
			if content_idx := after_type.index('"content":"') {
				start := abs_pos + content_idx + '"content":"'.len
				end := find_json_string_terminator(content_json, start)
				if end > start {
					results << unescape_json_text(content_json[start..end])
					search_pos = end + 1
					continue
				}
			}
			search_pos = abs_pos + '"type":"tool_result"'.len
		} else {
			break
		}
	}
	return results
}

fn unique_non_empty_ids(ids []string) []string {
	mut seen := map[string]bool{}
	mut unique := []string{}
	for id in ids {
		if id.len == 0 || id in seen {
			continue
		}
		seen[id] = true
		unique << id
	}
	return unique
}

fn extract_message_block_ids(content_json string, block_type string, id_key string) []string {
	mut ids := []string{}
	mut search_pos := 0
	pattern := '"type":"${block_type}"'
	for search_pos < content_json.len {
		remaining := content_json[search_pos..]
		if type_idx := remaining.index(pattern) {
			abs_pos := search_pos + type_idx
			mut block_start := abs_pos - 1
			for block_start >= 0 && content_json[block_start] != `{` {
				block_start--
			}
			if block_start >= 0 {
				block_end := find_matching_bracket(content_json, block_start)
				if block_end > block_start {
					block := content_json[block_start..block_end + 1]
					id := decode_json_string(extract_json_string_value(block, id_key))
					if id.len > 0 {
						ids << id
					}
					search_pos = block_end + 1
					continue
				}
			}
			search_pos = abs_pos + pattern.len
		} else {
			break
		}
	}
	return unique_non_empty_ids(ids)
}

fn extract_tool_use_ids(content_json string) []string {
	return extract_message_block_ids(content_json, 'tool_use', 'id')
}

fn extract_tool_result_ids(content_json string) []string {
	return extract_message_block_ids(content_json, 'tool_result', 'tool_use_id')
}

fn tool_pair_ids_match(tool_use_msg ChatMessage, tool_result_msg ChatMessage) bool {
	tool_use_ids := extract_tool_use_ids(tool_use_msg.content_json)
	tool_result_ids := extract_tool_result_ids(tool_result_msg.content_json)
	if tool_use_ids.len == 0 || tool_result_ids.len == 0 || tool_use_ids.len != tool_result_ids.len {
		return false
	}
	mut tool_result_set := map[string]bool{}
	for id in tool_result_ids {
		tool_result_set[id] = true
	}
	for id in tool_use_ids {
		if id !in tool_result_set {
			return false
		}
	}
	return true
}

fn summarize_assistant_message_for_api(msg ChatMessage) string {
	if msg.content.trim_space().len > 0 {
		return msg.content.trim_space()
	}
	mut parts := []string{}
	text := extract_text_blocks(msg.content_json).trim_space()
	thinking := extract_thinking_blocks(msg.content_json).trim_space()
	if text.len > 0 {
		parts << text
	}
	if thinking.len > 0 && thinking != text {
		parts << thinking
	}
	if parts.len == 0 {
		return '[Historical assistant tool call omitted for API compatibility]'
	}
	return parts.join('\n\n')
}

fn summarize_user_tool_result_for_api(msg ChatMessage) string {
	if msg.content.trim_space().len > 0 {
		return msg.content.trim_space()
	}
	contents := extract_tool_result_contents(msg.content_json)
	if contents.len == 0 {
		return '[Historical tool result omitted for API compatibility]'
	}
	joined := contents.join('\n\n')
	if joined.len > max_tool_output_chars {
		return '[Historical tool result]\n' + utf8_safe_truncate(joined, max_tool_output_chars) +
			'\n\n[... truncated for API compatibility]'
	}
	return '[Historical tool result]\n' + joined
}

fn sanitize_messages_for_api(messages []ChatMessage) ([]ChatMessage, bool) {
	mut sanitized := []ChatMessage{}
	mut changed := false
	for i, msg in messages {
		if message_has_tool_use(msg) {
			next_is_tool_result := i + 1 < messages.len && message_has_tool_result(messages[i + 1])
				&& tool_pair_ids_match(msg, messages[i + 1])
			if next_is_tool_result {
				sanitized << msg
			} else {
				changed = true
				sanitized << ChatMessage{
					role:    'assistant'
					content: summarize_assistant_message_for_api(msg)
				}
			}
			continue
		}
		if message_has_tool_result(msg) {
			prev_is_tool_use := sanitized.len > 0
				&& message_has_tool_use(sanitized[sanitized.len - 1])
				&& tool_pair_ids_match(sanitized[sanitized.len - 1], msg)
			if prev_is_tool_use {
				sanitized << msg
			} else {
				changed = true
				sanitized << ChatMessage{
					role:    'user'
					content: summarize_user_tool_result_for_api(msg)
				}
			}
			continue
		}
		sanitized << msg
	}
	return sanitized, changed
}

fn adjust_summary_boundary_for_tool_pairs(messages []ChatMessage, old_count int) int {
	if old_count <= 0 || old_count >= messages.len {
		return old_count
	}
	if message_has_tool_result(messages[old_count]) && message_has_tool_use(messages[old_count - 1])
		&& tool_pair_ids_match(messages[old_count - 1], messages[old_count]) {
		return old_count - 1
	}
	return old_count
}

fn (mut c ApiClient) repair_message_history_for_api() bool {
	sanitized, changed := sanitize_messages_for_api(c.messages)
	if changed {
		c.messages = sanitized
		c.logger.log('WARN', 'MESSAGE_HISTORY', 'sanitized invalid tool_use/tool_result history before API request')
	}
	return changed
}

fn summarize_tool_timing_detail(tool ToolUse) string {
	priority_keys := ['command', 'cmd', 'path', 'filePath', 'url', 'question', 'query', 'task',
		'pattern']
	for key in priority_keys {
		value := (tool.input[key] or { '' }).trim_space()
		if value.len == 0 {
			continue
		}
		preview := if value.len > 120 { value[..120] + '...' } else { value }
		return '${key}=${preview.replace('\n', ' ')}'
	}
	keys := tool.input.keys()
	if keys.len == 0 {
		return 'input_keys=[]'
	}
	return 'input_keys=[${keys.join(',')}]'
}

fn trim_status_detail(detail string, limit int) string {
	if detail.len <= limit {
		return detail
	}
	return detail[..limit] + '...'
}

fn phase_status_spinner_frame(elapsed_seconds int) string {
	frames := ['|', '/', '-', '\\']
	return frames[elapsed_seconds % frames.len]
}

fn render_phase_status_line(message string, detail string, elapsed_seconds int) {
	spinner := phase_status_spinner_frame(elapsed_seconds)
	if term_ui_is_active() {
		mut status := '${spinner} ${message}'
		if detail.len > 0 {
			status += ': ${trim_status_detail(detail, 100)}'
		}
		status += ' (${elapsed_seconds}s)'
		term_ui_set_status(status)
		return
	}
	mut line := '\x1b[2m${spinner} ${message}'
	if detail.len > 0 {
		line += ': ${trim_status_detail(detail, 100)}'
	}
	line += ' (${elapsed_seconds}s)\x1b[0m'
	print('\r\x1b[2K${line}')
	stdatomic.store_u64(&g_phase_status_visible, 1)
}

fn phase_status_timer_loop(generation u64, message string, detail string) {
	mut elapsed_seconds := 0
	for {
		time.sleep(1 * time.second)
		if stdatomic.load_u64(&g_phase_status_generation) != generation {
			return
		}
		elapsed_seconds++
		render_phase_status_line(message, detail, elapsed_seconds)
	}
}

fn clear_phase_status_line() {
	if term_ui_is_active() {
		term_ui_clear_status()
		return
	}
	stdatomic.add_u64(&g_phase_status_generation, 1)
	if stdatomic.load_u64(&g_phase_status_visible) == 0 {
		return
	}
	print('\r\x1b[2K')
	stdatomic.store_u64(&g_phase_status_visible, 0)
}

fn (c ApiClient) should_show_phase_status() bool {
	return c.interactive_mode && !c.silent_mode && !g_acp_mode
}

fn (c ApiClient) print_phase_status(message string, detail string) {
	if !c.should_show_phase_status() {
		return
	}
	generation := stdatomic.add_u64(&g_phase_status_generation, 1)
	render_phase_status_line(message, detail, 0)
	go phase_status_timer_loop(generation, message, detail)
}

fn tool_phase_message(tool ToolUse) string {
	builtin_names := ['str_replace_editor', 'bash', 'read_file', 'write_file', 'list_dir',
		'run_command', 'mouse_control', 'keyboard_control', 'capture_screen', 'match_sop',
		'session_note', 'task_done', 'grep_search', 'find_files', 'sequentialthinking', 'json_edit',
		'ask_user', 'update_working_checkpoint', 'todo_manager', 'read_many_files', 'activate_skill']
	return match tool.name {
		'bash', 'run_command' {
			'执行 shell'
		}
		'ask_user' {
			'正在等待用户输入'
		}
		'screen_analyze' {
			'等待 MCP 返回'
		}
		else {
			if tool.name in builtin_names {
				'执行工具 ${tool.name}'
			} else {
				'等待 MCP 返回'
			}
		}
	}
}

fn (mut c ApiClient) handle_chat_request_retry(mut step AgentStep, mut execution AgentExecution, consecutive_errors int, err_prefix string, err_msg string) !int {
	mut next_errors := consecutive_errors + 1
	step.state = .error
	step.error_msg = '${err_prefix}: ${err_msg}'
	step.end_time = time.now().unix_milli()
	c.trajectory.record_step(step)
	execution.steps << step
	c.logger.log_error('API', '${err_prefix} (attempt ${next_errors}): ${err_msg}')
	if next_errors >= 3 {
		execution.agent_state = .error
		execution.end_time = time.now().unix_milli()
		c.trajectory.finalize(false, 'API 连续失败 ${next_errors} 次')
		return error('API 连续失败 ${next_errors} 次: ${err_msg}')
	}
	if !c.silent_mode {
		println('\x1b[33m⚠️  请求失败，${next_errors}s 后重试 (${next_errors}/3)...\x1b[0m')
	}
	time.sleep(next_errors * time.second)
	return next_errors
}

fn (c ApiClient) log_cache_stats_if_debug(response_body string) {
	if c.debug && !c.silent_mode {
		cr, cc := parse_cache_stats(response_body)
		if cr > 0 || cc > 0 {
			println('[Cache] 命中=${cr} tokens  新写入=${cc} tokens')
		}
	}
}

fn build_parsed_response_from_stream_result(sr StreamResult) ParsedResponse {
	mut parsed := parse_sse_full(sr.raw_body)
	parsed.text = sr.text
	parsed.thinking = sr.thinking
	return parsed
}

fn (c ApiClient) parse_non_streaming_response(response_body string) ParsedResponse {
	parsed := parse_response_full(response_body)
	c.log_cache_stats_if_debug(response_body)
	return parsed
}

fn (c ApiClient) parse_text_response(response_body string) string {
	full_response := parse_anthropic_response(response_body)
	c.log_cache_stats_if_debug(response_body)
	return full_response
}

fn (mut c ApiClient) log_parsed_thinking_if_needed(parsed ParsedResponse) {
	if !c.use_streaming && parsed.thinking.len > 0 {
		if term_ui_is_active() {
			term_ui_append_thinking(parsed.thinking)
		} else if !c.silent_mode {
			clear_phase_status_line()
			println('\x1b[92m🧠 Thinking: ${parsed.thinking}\x1b[0m')
		}
		c.logger.log('INFO', 'THINKING', parsed.thinking.replace('\n', '\\n'))
	}
}

fn (mut c ApiClient) store_assistant_response(parsed ParsedResponse) {
	assistant_content_json := if parsed.tool_uses.len > 0 {
		build_assistant_content_json(parsed.text, parsed.thinking, parsed.tool_uses)
	} else {
		parsed.raw_content_json
	}
	if assistant_content_json.len > 0 {
		c.messages << ChatMessage{
			role:         'assistant'
			content:      parsed.text
			content_json: assistant_content_json
		}
	} else {
		c.add_message('assistant', parsed.text)
	}
}

fn (mut c ApiClient) finalize_successful_round(mut step AgentStep, parsed ParsedResponse) {
	step.thought = parsed.text
	step.thinking = parsed.thinking
	c.log_parsed_thinking_if_needed(parsed)
	c.logger.log_response(parsed.stop_reason, parsed.text.len, parsed.tool_uses.len, parsed.thinking.len)
	c.logger.log_ai_response(parsed.text, false)
	c.store_assistant_response(parsed)
}

struct ToolRoundExecutionResult {
	results_json               string
	tool_results               []string
	tool_names                 []string
	task_done_result           string
	round_has_tool_errors      bool
	round_all_tool_errors      bool
	last_failed_bash_command   string
	failed_bash_command_streak int
}

fn (mut c ApiClient) block_repeated_failed_tool_batch(mut step AgentStep, mut execution AgentExecution, tools []ToolUse, message string) {
	step.state = .error
	step.error_msg = 'repeated failed tool batch blocked'
	step.tool_calls = tools
	step.tool_results = [message]
	step.end_time = time.now().unix_milli()
	print_step_status(step)
	c.trajectory.record_step(step)
	execution.steps << step
	c.messages << ChatMessage{
		role:         'user'
		content:      ''
		content_json: build_tool_error_results_json(tools, message)
	}
	c.add_message('user', 'SYSTEM: 不要再次执行相同且已连续失败的工具调用。必须更换策略、修改参数，或先总结现状。')
}

fn (mut c ApiClient) execute_tool_batch(mut step AgentStep, tool_round int, tools []ToolUse, last_failed_bash_command string, failed_bash_command_streak int) ToolRoundExecutionResult {
	mut results_json := '['
	mut tool_results := []string{}
	mut tool_names := []string{}
	mut task_done_result := ''
	mut next_last_failed_bash_command := last_failed_bash_command
	mut next_failed_bash_command_streak := failed_bash_command_streak
	for tu in tools {
		c.logger.log_tool_call(tu.name, tu.input.keys().str())
		c.logger.log_tool_input(tu.name, tu.input)
		if tu.name == 'bash' {
			c.logger.log_tool_diagnostic(tu.name, build_bash_tool_diagnostic(tu.input['command'] or {
				''
			}))
		}
		tool_start_ms := time.now().unix_milli()
		tool_detail := summarize_tool_timing_detail(tu)
		c.print_phase_status(tool_phase_message(tu), tool_detail)
		c.logger.log_phase_start('tool.execute', 'step=${step.step_number} round=${tool_round} name=${tu.name} ${tool_detail}')
		mut raw_result := ''
		if should_block_repeated_failed_bash_command(tu, next_last_failed_bash_command,
			next_failed_bash_command_streak)
		{
			raw_result = 'Error: 检测到相同的 bash 失败命令已连续重复，已阻止再次执行。请先修改命令、检查路径或权限，或改用其他工具。'
			c.logger.log('WARN', 'TOOL_GUARD', 'blocked repeated failed bash command')
		} else {
			raw_result = execute_tool_use_with_mcp(mut c.mcp_manager, tu, c.workspace)
		}
		c.logger.log_phase_end('tool.execute', time.now().unix_milli() - tool_start_ms,
			'step=${step.step_number} round=${tool_round} name=${tu.name} ${tool_detail}')
		if tu.name == 'bash' {
			normalized_command := normalize_tool_command(tu.input['command'] or { '' })
			if is_tool_error_result(raw_result) && normalized_command.len > 0 {
				if normalized_command == next_last_failed_bash_command {
					next_failed_bash_command_streak++
				} else {
					next_last_failed_bash_command = normalized_command
					next_failed_bash_command_streak = 1
				}
			} else if normalized_command == next_last_failed_bash_command {
				next_last_failed_bash_command = ''
				next_failed_bash_command_streak = 0
			}
		}
		if raw_result.starts_with('__TASK_DONE__:') {
			task_done_result = raw_result[14..]
			print_tool_result(tu.name, task_done_result)
			tool_results << task_done_result
			tool_names << tu.name
		} else {
			print_tool_result(tu.name, raw_result)
			tool_results << raw_result
			tool_names << tu.name
		}
		is_truncated := raw_result.len > max_tool_output_chars
		result := if is_truncated {
			utf8_safe_truncate(raw_result, max_tool_output_chars) +
				'\n\n[... truncated, ${raw_result.len - max_tool_output_chars} chars omitted]'
		} else {
			raw_result
		}
		c.logger.log_tool_result(tu.name, raw_result.len, is_truncated)
		c.logger.log_tool_result_detail(tu.name, raw_result)
		escaped := escape_json_string(result)
		results_json += '{"type":"tool_result","tool_use_id":"${tu.id}","content":"${escaped}"},'
	}
	if results_json.ends_with(',') {
		results_json = results_json[..results_json.len - 1]
	}
	results_json += ']'
	mut round_has_tool_errors := false
	mut round_all_tool_errors := tool_results.len > 0
	for tr in tool_results {
		if is_tool_error_result(tr) {
			round_has_tool_errors = true
		} else {
			round_all_tool_errors = false
		}
	}
	return ToolRoundExecutionResult{
		results_json:               results_json
		tool_results:               tool_results
		tool_names:                 tool_names
		task_done_result:           task_done_result
		round_has_tool_errors:      round_has_tool_errors
		round_all_tool_errors:      round_all_tool_errors
		last_failed_bash_command:   next_last_failed_bash_command
		failed_bash_command_streak: next_failed_bash_command_streak
	}
}

fn (mut c ApiClient) complete_task_done(mut step AgentStep, mut execution AgentExecution, task_done_result string, total_retries int) string {
	step.state = .completed
	step.end_time = time.now().unix_milli()
	print_step_status(step)
	c.trajectory.record_step(step)
	execution.steps << step
	execution.final_result = task_done_result
	execution.success = true
	execution.agent_state = .completed
	execution.end_time = time.now().unix_milli()
	c.trajectory.finalize(true, task_done_result)

	// Self-Correction: if there were multiple retries but final success, automate experience recording
	if total_retries >= 2 && c.enable_tools {
		skill_name := if skill_registry.active_skill.len > 0 {
			skill_registry.active_skill
		} else {
			'general'
		}
		c.logger.log('INFO', 'SELF_CORRECTION', 'Automating experience for task with ${total_retries} retries')
		exp_msg := record_experience_automated(skill_name, 'Self-Correction: ' + c.trajectory.task,
			'Task completed after ${total_retries} retries', 'Iterative tool execution and error correction',
			'Success: ' + utf8_safe_truncate(task_done_result, 200), 'self-correction,retry-success',
			4)
		if !c.silent_mode {
			println('\x1b[36m💡 Self-Correction: 自动记录多次重试后的成功路径...\x1b[0m')
			if c.debug {
				println('[DEBUG] ${exp_msg}')
			}
		}
	}

	if term_ui_is_active() {
		term_ui_add_activity('Agent 完成任务')
	} else if !c.silent_mode {
		println('\x1b[32m✅ Agent 完成任务\x1b[0m')
	}
	c.add_message('assistant', task_done_result)
	return task_done_result
}

fn (c ApiClient) send_api_request(body_json string) !string {
	start_ms := time.now().unix_milli()
	request_mode := 'sync'
	c.logger.log_phase_start('api.request', 'mode=${request_mode} bytes=${body_json.len}')
	c.print_phase_status('等待模型', 'mode=${request_mode}, body=${body_json.len} bytes')
	if c.debug && !c.silent_mode {
		println('[DEBUG] 发送请求... body=${body_json.len} bytes')
	}

	mut headers := http.new_header()
	headers.add(.authorization, 'Bearer ${c.api_key}')
	headers.add(.content_type, 'application/json')
	headers.add(.connection, 'close') // avoid stale keep-alive connections

	mut req := http.Request{
		method:        .post
		url:           c.api_url
		header:        headers
		data:          body_json
		read_timeout:  180 * time.second
		write_timeout: 60 * time.second
	}

	response := req.do() or {
		c.logger.log_error('API', 'phase=api.request mode=${request_mode} duration_ms=${time.now().unix_milli() - start_ms} err=${err}')
		clear_phase_status_line()
		return err
	}

	if response.status_code != 200 {
		c.logger.log_error('API', 'phase=api.request mode=${request_mode} duration_ms=${time.now().unix_milli() - start_ms} status=${response.status_code}')
		clear_phase_status_line()
		return error('API Error ${response.status_code}: ${response.body}')
	}
	c.logger.log_phase_end('api.request', time.now().unix_milli() - start_ms, 'mode=${request_mode} bytes=${body_json.len} status=${response.status_code} body_bytes=${response.body.len}')
	clear_phase_status_line()

	return response.body
}

fn (c ApiClient) send_streaming_request(body_json string) !StreamResult {
	return c.send_streaming_request_opt(body_json, true)
}

fn (c ApiClient) send_streaming_request_silent(body_json string) !StreamResult {
	return c.send_streaming_request_opt(body_json, false)
}

fn (c ApiClient) send_streaming_request_opt(body_json string, show_output bool) !StreamResult {
	start_ms := time.now().unix_milli()
	c.logger.log_phase_start('api.stream', 'bytes=${body_json.len} show_output=${show_output}')
	if show_output {
		c.print_phase_status('等待模型', 'stream body=${body_json.len} bytes')
	}
	if c.debug && !c.silent_mode {
		println('[DEBUG] 发送流式请求...')
	}

	mut headers := http.new_header()
	headers.add(.authorization, 'Bearer ${c.api_key}')
	headers.add(.content_type, 'application/json')

	mut state := &StreamState{
		full_text:      ''
		thinking_text:  ''
		buffer:         ''
		raw_body:       ''
		current_block:  ''
		in_thinking:    false
		show_output:    show_output
		output_started: false
	}

	mut req := http.Request{
		method:             .post
		url:                c.api_url
		header:             headers
		data:               body_json
		read_timeout:       120 * time.second
		write_timeout:      30 * time.second
		on_progress_body:   fn [mut state] (request &http.Request, chunk []u8, body_so_far u64, body_expected u64, status_code int) ! {
			if status_code != 200 {
				return
			}
			chunk_str := chunk.bytestr()
			state.buffer += chunk_str
			state.raw_body += chunk_str

			// Process complete SSE lines
			for state.buffer.contains('\n') {
				nl_idx := state.buffer.index('\n') or { break }
				line := state.buffer[..nl_idx].trim_space()
				state.buffer = state.buffer[nl_idx + 1..]

				if !line.starts_with('data:') {
					continue
				}
				json_str := line[5..].trim_space()
				if json_str == '[DONE]' {
					continue
				}

				// Detect content_block_start to track block type
				if json_str.contains('"type":"content_block_start"') {
					if json_str.contains('"type":"thinking"') {
						state.current_block = 'thinking'
						if !state.in_thinking {
							state.in_thinking = true
							if state.show_output {
								if !state.output_started {
									clear_phase_status_line()
									state.output_started = true
								}
								print('\x1b[92m🧠 Thinking: ')
							}
						}
					} else if json_str.contains('"type":"text"') {
						if state.in_thinking {
							state.in_thinking = false
							if state.show_output {
								print('\x1b[0m\n')
							}
						}
						state.current_block = 'text'
					}
					continue
				}

				// content_block_stop
				if json_str.contains('"type":"content_block_stop"') {
					if state.current_block == 'thinking' {
						// Will be closed when text block starts or at end
					}
					continue
				}

				// Extract text from content_block_delta
				if json_str.contains('"type":"content_block_delta"') {
					if json_str.contains('"type":"thinking_delta"') {
						// Thinking delta
						text_pattern := '"thinking":"'
						if idx := json_str.index(text_pattern) {
							start := idx + text_pattern.len
							mut end := start
							for end < json_str.len {
								if json_str[end] == `"`
									&& (end == start || json_str[end - 1] != `\\`) {
									break
								}
								end++
							}
							if end > start {
								text := json_str[start..end]
								unescaped := text.replace('\\n', '\n').replace('\\t',
									'\t').replace('\\"', '"')
								if term_ui_is_active() {
									term_ui_append_thinking(unescaped)
								} else if state.show_output {
									if !state.output_started {
										clear_phase_status_line()
										state.output_started = true
									}
									print(unescaped)
								}
								state.thinking_text += unescaped
							}
						}
					} else if json_str.contains('"type":"text_delta"') {
						// Text delta
						text_pattern := '"text":"'
						if idx := json_str.index(text_pattern) {
							start := idx + text_pattern.len
							mut end := start
							for end < json_str.len {
								if json_str[end] == `"`
									&& (end == start || json_str[end - 1] != `\\`) {
									break
								}
								end++
							}
							if end > start {
								text := json_str[start..end]
								unescaped := text.replace('\\n', '\n').replace('\\t',
									'\t').replace('\\"', '"')
								if term_ui_is_active() {
									term_ui_append_stream_text(unescaped)
								} else if state.show_output {
									if !state.output_started {
										clear_phase_status_line()
										state.output_started = true
									}
									print(unescaped)
								}
								state.full_text += unescaped
							}
						}
					}
				}
			}
		}
		stop_copying_limit: 0
	}

	response := req.do() or {
		c.logger.log_error('API', 'phase=api.stream duration_ms=${time.now().unix_milli() - start_ms} err=${err}')
		clear_phase_status_line()
		return err
	}

	if response.status_code != 200 {
		c.logger.log_error('API', 'phase=api.stream duration_ms=${time.now().unix_milli() - start_ms} status=${response.status_code}')
		clear_phase_status_line()
		return error('API Error ${response.status_code}: ${response.body}')
	}

	mut final_text := state.full_text
	mut final_thinking := state.thinking_text
	mut final_raw_body := state.raw_body

	// Some environments don't invoke on_progress_body reliably; fall back to parsing response.body.
	if final_raw_body.len == 0 && response.body.len > 0 && response.body.contains('data:') {
		final_raw_body = response.body
	}
	if final_raw_body.len > 0 && (final_text.len == 0 || final_thinking.len == 0) {
		fallback := parse_sse_full(final_raw_body)
		if final_text.len == 0 {
			final_text = fallback.text
		}
		if final_thinking.len == 0 {
			final_thinking = fallback.thinking
		}
	}

	// Close thinking style if still open
	if state.in_thinking {
		if state.show_output {
			print('\x1b[0m\n')
		}
	}
	if term_ui_is_active() && state.full_text.len == 0 && final_text.len > 0 {
		term_ui_append_stream_text(final_text)
	} else if state.show_output && state.full_text.len == 0 && final_text.len > 0 {
		if !state.output_started {
			clear_phase_status_line()
			state.output_started = true
		}
		print(final_text)
	}
	if state.show_output && !term_ui_is_active() {
		println('')
	}
	c.logger.log_phase_end('api.stream', time.now().unix_milli() - start_ms, 'bytes=${body_json.len} text_len=${final_text.len} thinking_len=${final_thinking.len}')
	// newline after streaming output
	return StreamResult{
		text:     final_text
		thinking: final_thinking
		raw_body: final_raw_body
	}
}

// Estimate token count for all messages (rough: ~2.5 chars per token for mixed CJK/English)
fn (c ApiClient) estimate_tokens() int {
	mut total_chars := 0
	if c.system_prompt.len > 0 {
		total_chars += c.system_prompt.len
	}
	for msg in c.messages {
		if msg.content_json.len > 0 {
			total_chars += msg.content_json.len
		} else {
			total_chars += msg.content.len
		}
	}
	return int(f64(total_chars) / 2.5)
}

// Summarize older messages when context exceeds token limit.
// Keeps the system prompt, last user message, and recent assistant response.
// Compresses everything in between into a summary.
fn (mut c ApiClient) summarize_context() ! {
	effective_limit := if c.token_limit > 0 { c.token_limit } else { 80000 }
	estimated := c.estimate_tokens()
	if estimated < effective_limit {
		return
	}

	if c.debug && !c.silent_mode {
		println('[DEBUG] Token estimation: ~${estimated} (limit: ${effective_limit}), triggering summarization...')
	}

	// Keep the last 4 messages (recent context), summarize the rest
	keep_recent := 4
	if c.messages.len <= keep_recent {
		return
	}

	mut old_count := c.messages.len - keep_recent
	old_count = adjust_summary_boundary_for_tool_pairs(c.messages, old_count)
	mut summary_input := ''
	for i in 0 .. old_count {
		msg := c.messages[i]
		content := if msg.content.len > 0 { msg.content } else { msg.content_json }
		summary_input += '[${msg.role}]: ${content}\n\n'
	}

	// Use a compact summarization prompt
	summarize_prompt := '请将以下对话历史压缩为简洁的摘要，保留关键信息（工具调用结果、重要决策、文件路径等）。只输出摘要文本，不要添加额外说明：\n\n${summary_input}'

	// Build a minimal request for summarization
	escaped := escape_json_string(summarize_prompt)
	body_json := '{"model":"${c.model}","max_tokens":2000,"temperature":0.3,"messages":[{"role":"user","content":"${escaped}"}]}'

	response_body := c.send_api_request(body_json)!
	summary := parse_anthropic_response(response_body)

	if summary.len > 0 {
		// Replace old messages with a single summary message
		recent := c.messages[old_count..].clone()
		c.messages.clear()
		c.messages << ChatMessage{
			role:    'user'
			content: '[Context Summary]: ${summary}'
		}
		for msg in recent {
			c.messages << msg
		}
		if c.debug && !c.silent_mode {
			new_est := c.estimate_tokens()
			println('[DEBUG] Context summarized: ${old_count} messages → 1 summary. New token estimate: ~${new_est}')
		}
		c.logger.log_summarize(old_count, c.estimate_tokens())
		if !c.silent_mode {
			println('\x1b[2m[Context auto-summarized: ${old_count} messages compressed]\x1b[0m')
		}
	}
}

fn (mut c ApiClient) chat(prompt string) !string {
	c.add_message('user', prompt)
	c.logger.log_user_prompt(prompt)

	// Simple mode (no tools)
	if !c.enable_tools {
		body_json := c.build_request_json()
		c.logger.log_request(c.model, c.messages.len, false, c.use_streaming)
		if c.use_streaming {
			sr := c.send_streaming_request(body_json)!
			c.add_message('assistant', sr.text)
			return sr.text
		}
		response_body := c.send_api_request(body_json)!
		full_response := c.parse_text_response(response_body)
		c.add_message('assistant', full_response)
		return full_response
	}

	// Tool calling mode with Agent state machine
	mut tool_rounds := 0
	effective_max := if c.max_rounds > 0 { c.max_rounds } else { max_tool_call_rounds }
	mut consecutive_errors := 0
	mut consecutive_tool_failure_rounds := 0
	mut max_rounds_asked_user := false
	mut last_failed_tool_batch_signature := ''
	mut failed_tool_batch_streak := 0
	mut last_failed_bash_command := ''
	mut failed_bash_command_streak := 0
	mut total_retries_in_task := 0 // Track total retries for self-correction mechanism
	mut execution := new_agent_execution(prompt)
	c.trajectory.start_recording(prompt, c.model)

	for tool_rounds <= effective_max {
		mut step := AgentStep{
			step_number: tool_rounds + 1
			state:       .thinking
			start_time:  time.now().unix_milli()
		}

		c.repair_message_history_for_api()

		// Auto-summarize if context is too large
		c.summarize_context() or {
			if c.debug && !c.silent_mode {
				println('[DEBUG] Summarization failed: ${err}')
			}
		}

		body_json := c.build_request_json()

		mut parsed := ParsedResponse{}

		// When tool rounds are in progress, use streaming internally for reliability.
		// The MiniMax API closes non-streaming connections unreliably for multi-round requests.
		force_stream := !c.use_streaming && tool_rounds > 0
		if c.use_streaming || force_stream {
			mut stream_body := body_json
			if force_stream {
				c.use_streaming = true
				stream_body = c.build_request_json()
			}
			c.logger.log_request(c.model, c.messages.len, true, true)
			mut sr := StreamResult{}
			if force_stream {
				sr = c.send_streaming_request_silent(stream_body) or {
					c.use_streaming = false
					consecutive_errors = c.handle_chat_request_retry(mut step, mut execution,
						consecutive_errors, 'streaming request failed', err.str()) or { return err }
					continue
				}
				c.use_streaming = false
			} else {
				sr = c.send_streaming_request(stream_body) or {
					consecutive_errors = c.handle_chat_request_retry(mut step, mut execution,
						consecutive_errors, 'streaming request failed', err.str()) or { return err }
					continue
				}
			}
			parsed = build_parsed_response_from_stream_result(sr)
			if force_stream && parsed.stop_reason.len == 0 && parsed.text.len == 0
				&& parsed.tool_uses.len == 0 {
				if c.debug && !c.silent_mode {
					println('[DEBUG] 强制流式返回空响应，回退非流式重试...')
				}
				c.logger.log_error('API', 'forced streaming returned empty parsed response, retrying non-streaming')
				c.logger.log_request(c.model, c.messages.len, true, false)
				response_body := c.send_api_request(body_json) or {
					consecutive_errors = c.handle_chat_request_retry(mut step, mut execution,
						consecutive_errors, 'request failed', err.str()) or { return err }
					continue
				}
				parsed = c.parse_non_streaming_response(response_body)
			}
		} else {
			c.logger.log_request(c.model, c.messages.len, true, false)
			response_body := c.send_api_request(body_json) or {
				consecutive_errors = c.handle_chat_request_retry(mut step, mut execution,
					consecutive_errors, 'request failed', err.str()) or { return err }
				continue
			}
			parsed = c.parse_non_streaming_response(response_body)
		}

		// Reset consecutive errors on success
		consecutive_errors = 0

		normalized_tool_use := normalize_tool_uses(mut parsed.tool_uses)
		if normalized_tool_use {
			c.logger.log('WARN', 'TOOL_INPUT', 'normalized tool input with safe defaults')
		}

		c.finalize_successful_round(mut step, parsed)

		// Check for tool use
		if parsed.tool_uses.len > 0 && tool_rounds < effective_max {
			current_tool_batch_signature := tool_use_batch_signature(parsed.tool_uses)
			if failed_tool_batch_streak >= repeated_failed_tool_batch_limit - 1
				&& current_tool_batch_signature == last_failed_tool_batch_signature {
				block_message := '检测到连续重复的相同工具调用且前几轮全部失败，已阻止再次执行。请调整参数、先检查环境，或直接总结当前结果。'
				tool_rounds++
				c.block_repeated_failed_tool_batch(mut step, mut execution, parsed.tool_uses,
					block_message)
				continue
			}

			step.state = .calling_tool
			step.tool_calls = parsed.tool_uses
			tool_rounds++
			tool_round_result := c.execute_tool_batch(mut step, tool_rounds, parsed.tool_uses,
				last_failed_bash_command, failed_bash_command_streak)
			last_failed_bash_command = tool_round_result.last_failed_bash_command
			failed_bash_command_streak = tool_round_result.failed_bash_command_streak
			step.tool_results = tool_round_result.tool_results
			if tool_round_result.round_has_tool_errors {
				consecutive_tool_failure_rounds++
				total_retries_in_task++
			} else {
				consecutive_tool_failure_rounds = 0
			}
			if tool_round_result.round_all_tool_errors {
				if current_tool_batch_signature == last_failed_tool_batch_signature {
					failed_tool_batch_streak++
				} else {
					last_failed_tool_batch_signature = current_tool_batch_signature
					failed_tool_batch_streak = 1
				}
			} else {
				last_failed_tool_batch_signature = ''
				failed_tool_batch_streak = 0
			}

			// task_done: early exit if agent signaled completion
			if tool_round_result.task_done_result.len > 0 {
				return c.complete_task_done(mut step, mut execution, tool_round_result.task_done_result,
					total_retries_in_task)
			}

			// Reflection: check for tool errors and generate reflection message
			reflection := generate_reflection(tool_round_result.tool_results, tool_round_result.tool_names)
			if reflection.len > 0 {
				step.state = .reflecting
				step.reflection = reflection
				if c.debug && !c.silent_mode {
					println('\x1b[35m💭 Reflection: ${reflection}\x1b[0m')
				}
			}

			step.end_time = time.now().unix_milli()
			print_step_status(step)
			c.trajectory.record_step(step)
			execution.steps << step

			c.messages << ChatMessage{
				role:         'user'
				content:      ''
				content_json: tool_round_result.results_json
			}
			// Failure escalation: after repeated tool failures, force user handoff in interactive mode.
			if tool_round_result.round_has_tool_errors {
				if consecutive_tool_failure_rounds == 2 {
					c.add_message('user', 'SYSTEM: 连续两轮工具执行失败。请先探测环境状态并避免重复同样参数。')
				} else if consecutive_tool_failure_rounds >= tool_failure_escalation_round {
					if c.interactive_mode && !g_acp_mode {
						question := '连续${consecutive_tool_failure_rounds}轮工具失败。请告诉我你希望我下一步怎么做（例如改目标/给路径/允许先总结）。'
						user_guidance := ask_user_tool(question)
						if user_guidance.len > 0 && !user_guidance.starts_with('Error:')
							&& user_guidance != '(User provided no answer)' {
							c.add_message('user', 'User guidance (failure escalation): ${user_guidance}')
						} else if tool_round_result.round_all_tool_errors {
							c.add_message('user', 'SYSTEM: 多轮工具全部失败，请先调用 ask_user 澄清需求后再继续。')
						}
					} else if tool_round_result.round_all_tool_errors {
						c.add_message('user', 'SYSTEM: 多轮工具全部失败，请先调用 ask_user 澄清需求后再继续。')
					}
					consecutive_tool_failure_rounds = 0
				}
			}
			continue
		}

		// No tool calls or reached limit - finalize step
		step.state = .completed
		step.end_time = time.now().unix_milli()

		// Reached tool round limit
		if parsed.tool_uses.len > 0 {
			step.state = .error
			step.error_msg = 'max tool rounds reached'
			if !c.silent_mode {
				println('[WARN] 达到最大工具调用轮数 (${effective_max})')
			}
			mut err_json := '['
			for tu in parsed.tool_uses {
				err_json += '{"type":"tool_result","tool_use_id":"${tu.id}","content":"工具调用次数已达上限，请根据已获取的信息直接回答用户问题。","is_error":true},'
			}
			if err_json.ends_with(',') {
				err_json = err_json[..err_json.len - 1]
			}
			err_json += ']'
			c.messages << ChatMessage{
				role:         'user'
				content:      ''
				content_json: err_json
			}
			if c.interactive_mode && !g_acp_mode && !max_rounds_asked_user {
				user_guidance := ask_user_tool('已达到最大工具调用轮数。请明确下一步优先级，或允许我直接总结当前结果。')
				max_rounds_asked_user = true
				if user_guidance.len > 0 && !user_guidance.starts_with('Error:')
					&& user_guidance != '(User provided no answer)' {
					c.add_message('user', 'User guidance (max rounds): ${user_guidance}')
					consecutive_tool_failure_rounds = 0
					tool_rounds = 0
					continue
				}
			}
			c.trajectory.record_step(step)
			execution.steps << step
			// One final request for summary
			final_body := c.build_request_json()
			final_resp := c.send_api_request(final_body)!
			final_parsed := c.parse_non_streaming_response(final_resp)
			if final_parsed.text.len > 0 {
				c.add_message('assistant', final_parsed.text)
				execution.final_result = final_parsed.text
				execution.success = true
				execution.agent_state = .completed
				execution.end_time = time.now().unix_milli()
				c.trajectory.finalize(true, final_parsed.text)
				return final_parsed.text
			}
		}

		// Normal completion — if AI returned empty text after tool use, provide fallback summary
		final_text := if parsed.text.len == 0 && execution.steps.len > 0 {
			// Collect what tools were called as context for fallback message
			mut tool_summary := []string{}
			for s in execution.steps {
				for tc in s.tool_calls {
					tool_summary << tc.name
				}
			}
			if tool_summary.len > 0 {
				'任务已完成（使用工具: ${tool_summary.join(', ')}）'
			} else {
				'任务已完成'
			}
		} else {
			parsed.text
		}
		execution.final_result = final_text
		execution.success = true
		execution.agent_state = .completed
		execution.end_time = time.now().unix_milli()
		if execution.steps.len > 0 {
			// Only show trajectory info when there were actual tool steps
			c.trajectory.record_step(step)
			execution.steps << step
			c.trajectory.finalize(true, final_text)
		}
		return final_text
	}

	execution.agent_state = .error
	execution.end_time = time.now().unix_milli()
	c.trajectory.finalize(false, '超过最大请求轮数')
	return error('超过最大请求轮数')
}

fn (mut c ApiClient) clear_messages() {
	c.messages.clear()
}

const minimax_quota_url = 'https://www.minimaxi.com/v1/api/openplatform/coding_plan/remains'

fn (c ApiClient) check_quota() !string {
	mut headers := http.new_header()
	headers.add(.authorization, 'Bearer ${c.api_key}')
	headers.add(.content_type, 'application/json')

	mut req := http.Request{
		method:       .get
		url:          minimax_quota_url
		header:       headers
		read_timeout: 30 * time.second
	}

	response := req.do()!

	if response.status_code != 200 {
		return error('API Error ${response.status_code}: ${response.body}')
	}

	return parse_quota_response(response.body)
}

fn parse_quota_response(body string) string {
	mut result := ''

	// Check for error
	if body.contains('"status_code":') && !body.contains('"status_code":0') {
		return '  ❌ 请求失败: ${body}'
	}

	// Parse model_remains array
	if !body.contains('"model_remains"') {
		return '  原始响应: ${body}'
	}

	// Find model_remains array
	target := '"model_remains":['
	arr_start_idx := body.index(target) or { return '  原始响应: ${body}' }
	arr_start := arr_start_idx + target.len - 1
	arr_end := find_matching_bracket(body, arr_start)
	if arr_end <= arr_start {
		return '  原始响应: ${body}'
	}
	arr_content := body[arr_start..arr_end + 1]

	// Extract each model block
	mut search_pos := 0
	for search_pos < arr_content.len {
		remaining := arr_content[search_pos..]
		obj_start := remaining.index('{') or { break }
		abs_start := search_pos + obj_start
		obj_end := find_matching_bracket(arr_content, abs_start)
		if obj_end <= abs_start {
			break
		}
		block := arr_content[abs_start..obj_end + 1]

		model_name := extract_json_string_value(block, 'model_name')
		total := extract_json_number_value(block, 'current_interval_total_count')
		usage := extract_json_number_value(block, 'current_interval_usage_count')
		remains_time := extract_json_number_value(block, 'remains_time')

		used := total - usage
		remains_hours := remains_time / 3600000
		remains_mins := (remains_time % 3600000) / 60000

		result += '  📌 ${model_name}\n'
		result += '     总次数: ${total}  已用: ${used}  剩余: ${usage}\n'
		result += '     重置倒计时: ${remains_hours}h ${remains_mins}m\n'

		search_pos = obj_end + 1
	}

	if result.len == 0 {
		return '  原始响应: ${body}'
	}

	return result.trim_right('\n')
}

fn extract_json_number_value(json_str string, key string) i64 {
	pattern := '"${key}":'
	if idx := json_str.index(pattern) {
		mut start := idx + pattern.len
		for start < json_str.len && json_str[start] == u8(` `) {
			start++
		}
		mut end := start
		for end < json_str.len && json_str[end] !in [u8(`,`), `}`, `]`, ` `, `\n`] {
			end++
		}
		if end > start {
			val_str := json_str[start..end]
			// Parse as i64
			mut val := i64(0)
			mut is_neg := false
			mut pos := 0
			if val_str.len > 0 && val_str[0] == `-` {
				is_neg = true
				pos = 1
			}
			for pos < val_str.len {
				ch := val_str[pos]
				if ch >= `0` && ch <= `9` {
					val = val * 10 + i64(ch - `0`)
				} else {
					break
				}
				pos++
			}
			if is_neg {
				return -val
			}
			return val
		}
	}
	return 0
}
