module main

import time

// ===== AgentStepState helpers =====

fn test_step_state_emoji() {
	assert step_state_emoji(.thinking) == '🤔'
	assert step_state_emoji(.calling_tool) == '🔧'
	assert step_state_emoji(.reflecting) == '💭'
	assert step_state_emoji(.completed) == '✅'
	assert step_state_emoji(.error) == '❌'
}

fn test_step_state_color() {
	// Each state should return an ANSI color code
	assert step_state_color(.thinking).len > 0
	assert step_state_color(.calling_tool).len > 0
	assert step_state_color(.reflecting).len > 0
	assert step_state_color(.completed).len > 0
	assert step_state_color(.error).len > 0
}

fn test_step_state_name() {
	assert step_state_name(.thinking) == 'THINKING'
	assert step_state_name(.calling_tool) == 'CALLING_TOOL'
	assert step_state_name(.reflecting) == 'REFLECTING'
	assert step_state_name(.completed) == 'COMPLETED'
	assert step_state_name(.error) == 'ERROR'
}

// ===== new_agent_execution =====

fn test_new_agent_execution() {
	exec := new_agent_execution('Fix the bug')
	assert exec.task == 'Fix the bug'
	assert exec.steps.len == 0
	assert exec.success == false
	assert exec.agent_state == .running
	assert exec.start_time > 0
}

// ===== duration_secs =====

fn test_duration_secs_in_progress() {
	exec := new_agent_execution('task')
	// Still running — should return positive value
	d := exec.duration_secs()
	assert d >= 0.0
}

fn test_duration_secs_completed() {
	mut exec := new_agent_execution('task')
	exec.start_time = time.now().unix_milli() - 2500 // 2.5 seconds ago
	exec.end_time = time.now().unix_milli()
	d := exec.duration_secs()
	assert d >= 2.0 && d <= 4.0
}

// ===== generate_reflection =====

fn test_generate_reflection_no_errors() {
	result := generate_reflection(['success', 'ok'], ['tool1', 'tool2'])
	assert result == '' // no errors
}

fn test_generate_reflection_with_error() {
	result := generate_reflection(['Error: file not found', 'ok'], ['read_file', 'list_dir'])
	assert result.contains('read_file')
	assert result.contains('file not found')
	assert result.contains('different approach')
}

fn test_generate_reflection_exit_code_error() {
	result := generate_reflection(['Exit code: 1 output here'], ['bash'])
	assert result.contains('bash')
	assert result.contains('Exit code')
}

fn test_generate_reflection_multiple_errors() {
	results := ['Error: not found', 'ok', 'Error: permission denied']
	names := ['read_file', 'list_dir', 'write_file']
	result := generate_reflection(results, names)
	assert result.contains('read_file')
	assert result.contains('write_file')
	assert !result.contains('list_dir') // list_dir succeeded
}

fn test_generate_reflection_empty_inputs() {
	assert generate_reflection([], []) == ''
}

// ===== TrajectoryRecorder =====

fn test_new_trajectory_recorder_disabled() {
	t := new_trajectory_recorder(false)
	assert t.enabled == false
}

fn test_new_trajectory_recorder_enabled() {
	t := new_trajectory_recorder(true)
	assert t.enabled == true
	assert t.trajectory_file.len > 0
	assert t.trajectory_file.contains('.json')
}

fn test_trajectory_recorder_start_recording() {
	mut t := new_trajectory_recorder(true)
	t.start_recording('my task', 'MiniMax-M2.7')
	assert t.task == 'my task'
	assert t.model == 'MiniMax-M2.7'
	assert t.start_time.len > 0
}

fn test_trajectory_recorder_record_step() {
	mut t := new_trajectory_recorder(true)
	t.start_recording('task', 'model')

	step := AgentStep{
		step_number:  1
		state:        .thinking
		thought:      'I need to analyze the code'
		thinking:     'deep thinking'
		tool_calls:   []
		tool_results: []
		start_time:   time.now().unix_milli() - 1000
		end_time:     time.now().unix_milli()
	}
	t.record_step(step)
	assert t.steps.len == 1
	assert t.steps[0].contains('"step_number":1')
	assert t.steps[0].contains('THINKING')
}

fn test_trajectory_recorder_record_step_with_tools() {
	mut t := new_trajectory_recorder(true)
	t.start_recording('task', 'model')

	step := AgentStep{
		step_number:  2
		state:        .calling_tool
		thought:      'Reading file'
		tool_calls:   [
			ToolUse{
				id:    'tu_1'
				name:  'read_file'
				input: {
					'path': '/tmp/test.txt'
				}
			},
		]
		tool_results: ['file content here']
		start_time:   time.now().unix_milli() - 500
		end_time:     time.now().unix_milli()
	}
	t.record_step(step)
	assert t.steps.len == 1
	assert t.steps[0].contains('read_file')
	assert t.steps[0].contains('tu_1')
}

fn test_trajectory_recorder_disabled_no_recording() {
	mut t := new_trajectory_recorder(false)
	t.start_recording('task', 'model')
	step := AgentStep{
		step_number: 1
		state:       .thinking
		thought:     'x'
	}
	t.record_step(step)
	assert t.steps.len == 0 // disabled, nothing recorded
}

// ===== print_step_status (no crash) =====

fn test_print_step_status_no_crash() {
	mut client := new_api_client(default_config())
	step := AgentStep{
		step_number: 1
		state:       .completed
		start_time:  time.now().unix_milli() - 1000
		end_time:    time.now().unix_milli()
	}
	print_step_status(mut client, step)
}

fn test_print_step_status_no_elapsed() {
	mut client := new_api_client(default_config())
	step := AgentStep{
		step_number: 1
		state:       .thinking
	}
	print_step_status(mut client, step) // elapsed == 0, should not crash
}
