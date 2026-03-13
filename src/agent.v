module main

import os
import time

// --- Agent State Machine ---
// Inspired by Trae Agent's AgentStepState / AgentExecution architecture

enum AgentStepState {
	thinking
	calling_tool
	reflecting
	completed
	error
}

enum AgentState {
	idle
	running
	completed
	error
}

struct AgentStep {
mut:
	step_number  int
	state        AgentStepState
	thought      string    // LLM text response
	thinking     string    // LLM thinking content
	tool_calls   []ToolUse // Tools called in this step
	tool_results []string  // Results from tool execution
	reflection   string    // Reflection on errors
	error_msg    string    // Error message if step failed
	start_time   i64       // Unix timestamp ms
	end_time     i64       // Unix timestamp ms
}

struct AgentExecution {
mut:
	task         string
	steps        []AgentStep
	final_result string
	success      bool
	total_input  int // Total input tokens (estimated)
	total_output int // Total output tokens (estimated)
	start_time   i64
	end_time     i64
	agent_state  AgentState
}

fn new_agent_execution(task string) AgentExecution {
	return AgentExecution{
		task:        task
		steps:       []AgentStep{}
		success:     false
		start_time:  time.now().unix_milli()
		agent_state: .running
	}
}

fn (e AgentExecution) duration_secs() f64 {
	if e.end_time > 0 {
		return f64(e.end_time - e.start_time) / 1000.0
	}
	return f64(time.now().unix_milli() - e.start_time) / 1000.0
}

fn step_state_emoji(state AgentStepState) string {
	return match state {
		.thinking { '🤔' }
		.calling_tool { '🔧' }
		.reflecting { '💭' }
		.completed { '✅' }
		.error { '❌' }
	}
}

fn step_state_color(state AgentStepState) string {
	return match state {
		.thinking { '\x1b[34m' } // blue
		.calling_tool { '\x1b[33m' } // yellow
		.reflecting { '\x1b[35m' } // magenta
		.completed { '\x1b[32m' } // green
		.error { '\x1b[31m' } // red
	}
}

fn step_state_name(state AgentStepState) string {
	return match state {
		.thinking { 'THINKING' }
		.calling_tool { 'CALLING_TOOL' }
		.reflecting { 'REFLECTING' }
		.completed { 'COMPLETED' }
		.error { 'ERROR' }
	}
}

fn print_step_status(step AgentStep) {
	if g_acp_mode {
		return
	}
	if term_ui_is_active() {
		elapsed := if step.end_time > 0 {
			f64(step.end_time - step.start_time) / 1000.0
		} else {
			0.0
		}
		mut summary := '${step_state_emoji(step.state)} Step ${step.step_number} [${step_state_name(step.state)}]'
		if elapsed > 0 {
			summary += ' (${elapsed:.1f}s)'
		}
		term_ui_add_activity(summary)
		return
	}
	clear_phase_status_line()
	emoji := step_state_emoji(step.state)
	color := step_state_color(step.state)
	name := step_state_name(step.state)
	reset := '\x1b[0m'
	elapsed := if step.end_time > 0 {
		f64(step.end_time - step.start_time) / 1000.0
	} else {
		0.0
	}
	if elapsed > 0 {
		println('${color}${emoji} Step ${step.step_number} [${name}] (${elapsed:.1f}s)${reset}')
	} else {
		println('${color}${emoji} Step ${step.step_number} [${name}]${reset}')
	}
}

// --- Reflection ---
// Generates reflection message when tool execution fails

fn generate_reflection(tool_results []string, tool_names []string) string {
	mut has_errors := false
	mut reflection := ''
	for i, result in tool_results {
		if result.starts_with('Error:') || result.starts_with('Exit code:') {
			has_errors = true
			name := if i < tool_names.len { tool_names[i] } else { 'unknown' }
			reflection += 'Tool "${name}" failed: ${result}\n'
		}
	}
	if !has_errors {
		return ''
	}
	return 'Some tools failed. Consider trying a different approach or fixing the parameters.\n${reflection}'
}

// --- Trajectory Recorder ---
// Records execution trajectory in JSON format

struct TrajectoryRecorder {
mut:
	enabled         bool
	trajectory_dir  string
	trajectory_file string
	steps           []string // JSON strings for each step
	task            string
	model           string
	start_time      string
}

fn new_trajectory_recorder(enabled bool) TrajectoryRecorder {
	traj_dir := os.join_path(get_minimax_config_dir(), 'trajectories')
	if enabled && !os.is_dir(traj_dir) {
		os.mkdir_all(traj_dir) or {}
	}
	timestamp := time.now().custom_format('YYYY-MM-DD_hh-mm-ss')
	traj_file := os.join_path(traj_dir, '${timestamp}.json')
	return TrajectoryRecorder{
		enabled:         enabled
		trajectory_dir:  traj_dir
		trajectory_file: traj_file
		steps:           []string{}
		start_time:      time.now().format_rfc3339()
	}
}

fn (mut t TrajectoryRecorder) start_recording(task string, model string) {
	if !t.enabled {
		return
	}
	t.task = task
	t.model = model
	t.start_time = time.now().format_rfc3339()
	t.steps.clear()
}

fn (mut t TrajectoryRecorder) record_step(step AgentStep) {
	if !t.enabled {
		return
	}

	// Build tool_calls JSON array
	mut tc_json := '[]'
	if step.tool_calls.len > 0 {
		mut tc_parts := []string{}
		for tc in step.tool_calls {
			mut input_json := '{'
			for key, val in tc.input {
				escaped := escape_json_string(val)
				input_json += '"${key}":"${escaped}",'
			}
			if input_json.ends_with(',') {
				input_json = input_json[..input_json.len - 1]
			}
			input_json += '}'
			tc_parts << '{"id":"${tc.id}","name":"${tc.name}","input":${input_json}}'
		}
		tc_json = '[' + tc_parts.join(',') + ']'
	}

	// Build tool_results JSON array
	mut tr_json := '[]'
	if step.tool_results.len > 0 {
		mut tr_parts := []string{}
		for r in step.tool_results {
			// Truncate very large results for trajectory
			truncated := if r.len > 2000 { r[..2000] + '...(truncated)' } else { r }
			tr_parts << '"${escape_json_string(truncated)}"'
		}
		tr_json = '[' + tr_parts.join(',') + ']'
	}

	escaped_thought := escape_json_string(step.thought)
	escaped_thinking := escape_json_string(step.thinking)
	escaped_reflection := escape_json_string(step.reflection)
	escaped_error := escape_json_string(step.error_msg)
	state_name := step_state_name(step.state)
	duration_ms := step.end_time - step.start_time

	step_json := '{"step_number":${step.step_number},"state":"${state_name}","thought":"${escaped_thought}","thinking":"${escaped_thinking}","tool_calls":${tc_json},"tool_results":${tr_json},"reflection":"${escaped_reflection}","error":"${escaped_error}","duration_ms":${duration_ms}}'

	t.steps << step_json
}

fn (mut t TrajectoryRecorder) finalize(success bool, final_result string) {
	if !t.enabled {
		return
	}

	end_time := time.now().format_rfc3339()
	escaped_task := escape_json_string(t.task)
	escaped_result := escape_json_string(final_result)
	steps_json := '[' + t.steps.join(',') + ']'

	trajectory_json := '{"task":"${escaped_task}","model":"${t.model}","start_time":"${t.start_time}","end_time":"${end_time}","success":${success},"final_result":"${escaped_result}","steps":${steps_json}}'

	os.write_file(t.trajectory_file, trajectory_json) or {
		println('\x1b[33m⚠️  Failed to save trajectory: ${err}\x1b[0m')
		return
	}
	println('\x1b[2m[Trajectory saved: ${t.trajectory_file}]\x1b[0m')
}
