module main

import os
import time

fn wait_for_terminal(mut s BashSession, task_id string, max_wait_ms i64) string {
	deadline := time.now().unix_milli() + max_wait_ms
	for {
		s.refresh_all_bg_tasks()
		task := s.bg_tasks[task_id] or { return 'missing' }
		if task.status != 'running' {
			return task.status
		}
		if time.now().unix_milli() > deadline {
			return 'still_running'
		}
		time.sleep(100 * time.millisecond)
	}
	return ''
}

fn cleanup_task(mut s BashSession, task_id string) {
	task := s.bg_tasks[task_id] or { return }
	if task.status == 'running' {
		s.bg_task_stop_text(task_id)
	}
	if os.is_file(task.output_path) {
		os.rm(task.output_path) or {}
	}
}

fn test_bg_task_run_to_completion() {
	mut session := new_bash_session('')
	task := session.start_background_task('echo bg-hello', 0) or {
		assert false, 'start failed: ${err}'
		return
	}
	defer {
		cleanup_task(mut session, task.id)
	}
	status := wait_for_terminal(mut session, task.id, 15000)
	assert status == 'completed', 'unexpected status: ${status}'
	content := os.read_file(task.output_path) or { '' }
	assert content.contains('bg-hello'), 'output missing bg-hello: ${content}'
	out := session.bg_task_output_text(task.id)
	assert out.contains('status=completed')
	assert out.contains('bg-hello')
}

fn test_bg_task_stop_running() {
	mut session := new_bash_session('')
	task := session.start_background_task('sleep 60', 0) or {
		assert false, 'start failed: ${err}'
		return
	}
	defer {
		cleanup_task(mut session, task.id)
	}
	res := session.bg_task_stop_text(task.id)
	assert res.contains('stopped')
	assert session.bg_tasks[task.id] or { return }.status == 'stopped'
}

fn test_bg_task_timeout() {
	mut session := new_bash_session('')
	task := session.start_background_task('sleep 30', 500) or {
		assert false, 'start failed: ${err}'
		return
	}
	defer {
		cleanup_task(mut session, task.id)
	}
	status := wait_for_terminal(mut session, task.id, 15000)
	assert status == 'timeout', 'unexpected status: ${status}'
}

fn test_bg_task_dangerous_command_rejected() {
	mut session := new_bash_session('')
	session.start_background_task('rm -rf /', 0) or {
		assert err.msg().len > 0
		return
	}
	assert false, 'dangerous command should be rejected'
}

fn test_bg_task_list_and_notifications() {
	mut session := new_bash_session('')
	assert session.bg_task_list_text().contains('No background tasks')
	task := session.start_background_task('echo bg-notify', 0) or {
		assert false, 'start failed: ${err}'
		return
	}
	defer {
		cleanup_task(mut session, task.id)
	}
	status := wait_for_terminal(mut session, task.id, 15000)
	assert status == 'completed', 'unexpected status: ${status}'
	notices := session.drain_finished_notifications()
	assert notices.len == 1, 'expected 1 notice, got ${notices.len}'
	assert notices[0].contains(task.id)
	// Second drain should be empty (already notified).
	assert session.drain_finished_notifications().len == 0
	list := session.bg_task_list_text()
	assert list.contains(task.id)
	assert list.contains('[completed]')
}
