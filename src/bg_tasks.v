module main

import os
import time

// bg_tasks.v - 后台任务系统
//
// 设计要点：
// 1. bash 工具带 run_in_background=true 时启动后台任务：独立 bash 进程，
//    输出重定向到 ~/.config/minimax/tasks/<task_id>.log，立即返回 task_id；
// 2. 任务状态惰性刷新（task_list/task_output/通知抽取时检查 is_alive 与超时）；
// 3. 工具循环每轮通过 drain_finished_notifications 把刚结束的任务作为
//    SYSTEM: 消息注入对话，模型无需轮询即可得知完成；
// 4. 注册表挂在 BashSession 上（与 bash 持久会话状态一致，避免 __global），
//    进程退出后后台进程由系统回收，日志文件保留在磁盘。

const bg_task_default_timeout_ms = i64(1800000) // 30 分钟

struct BackgroundTask {
pub mut:
	id          string
	command     string
	cwd         string
	status      string // running / completed / failed / stopped / timeout
	output_path string
	started     i64
	ended       i64
	exit_code   int = -1
	timeout_ms  i64
	notified    bool
	proc        &os.Process
}

fn bg_tasks_dir() string {
	dir := os.join_path(get_user_home_dir(), '.config', 'minimax', 'tasks')
	os.mkdir_all(dir) or {}
	return dir
}

// start_background_task spawns a detached bash process running command with all
// output redirected to the task log file, and registers it on this session.
fn (mut s BashSession) start_background_task(command string, timeout_ms i64) !&BackgroundTask {
	if danger_msg := check_dangerous_command(command) {
		return error(danger_msg)
	}
	bash_path := find_bash_path()
	if bash_path.len == 0 {
		return error('bash not found; background tasks require bash')
	}
	s.bg_counter++
	id := 'bg_${s.bg_counter}_${time.now().unix_milli()}'
	output_path := os.join_path(bg_tasks_dir(), '${id}.log')

	// Redirect inside the shell so nothing leaks to the parent's terminal.
	safe_out := output_path.replace("'", "'\\''")
	full_cmd := "(${command}) > '${safe_out}' 2>&1"
	bash_c_arg := if os.user_os() == 'windows' { full_cmd.replace('"', '\\"') } else { full_cmd }

	mut p := os.new_process(bash_path)
	p.set_args(['-c', bash_c_arg])
	if s.cwd.len > 0 && os.is_dir(s.cwd) {
		p.set_work_folder(s.cwd)
	}
	p.use_pgroup = true
	p.create_no_window = true
	p.run()
	if p.status != .running {
		return error('failed to start background task: ${p.err}')
	}

	task := &BackgroundTask{
		id:          id
		command:     command
		cwd:         s.cwd
		status:      'running'
		output_path: output_path
		started:     time.now().unix_milli()
		timeout_ms:  if timeout_ms > 0 { timeout_ms } else { bg_task_default_timeout_ms }
		proc:        p
	}
	s.bg_tasks[id] = task
	return task
}

// bg_task_refresh updates a running task's status (completion or timeout).
fn bg_task_refresh(mut task BackgroundTask) {
	if task.status != 'running' {
		return
	}
	now := time.now().unix_milli()
	if now - task.started >= task.timeout_ms {
		task.proc.signal_pgkill()
		task.proc.wait()
		task.proc.close()
		task.status = 'timeout'
		task.ended = now
		return
	}
	if !task.proc.is_alive() {
		// Reap the finished process so the real exit code is available
		// (is_alive() alone does not update proc.code on Windows).
		task.proc.wait()
		task.ended = now
		task.exit_code = task.proc.code
		task.status = if task.proc.code == 0 { 'completed' } else { 'failed' }
		task.proc.close()
	}
}

fn (mut s BashSession) refresh_all_bg_tasks() {
	for _, mut task in s.bg_tasks {
		bg_task_refresh(mut task)
	}
}

// drain_finished_notifications returns notices for tasks that reached a
// terminal state since the last drain, marking them as notified.
fn (mut s BashSession) drain_finished_notifications() []string {
	mut notices := []string{}
	for _, mut task in s.bg_tasks {
		bg_task_refresh(mut task)
		if task.status != 'running' && !task.notified {
			task.notified = true
			dur := task.ended - task.started
			notices << '[后台任务结束] ${task.id} status=${task.status} exit_code=${task.exit_code} duration=${dur}ms command=`${task.command}` — 用 task_output 工具查看输出: ${task.output_path}'
		}
	}
	return notices
}

fn bg_task_duration_ms(task &BackgroundTask) i64 {
	end_ms := if task.status == 'running' { time.now().unix_milli() } else { task.ended }
	return end_ms - task.started
}

// --- 工具入口（被 tools.v 的 task_list / task_output / task_stop 调用） ---

fn (mut s BashSession) bg_task_list_text() string {
	s.refresh_all_bg_tasks()
	if s.bg_tasks.len == 0 {
		return 'No background tasks.'
	}
	mut lines := []string{cap: s.bg_tasks.len}
	for id, task in s.bg_tasks {
		lines << '${id} [${task.status}] ${bg_task_duration_ms(task)}ms exit=${task.exit_code} cmd=`${task.command}`'
	}
	return lines.join('\n')
}

fn (mut s BashSession) bg_task_output_text(id string) string {
	mut task := s.bg_tasks[id] or { return 'Error: unknown task_id ${id}' }
	bg_task_refresh(mut task)
	mut out := 'task_id=${task.id} status=${task.status} exit_code=${task.exit_code} duration=${bg_task_duration_ms(task)}ms\n'
	if os.is_file(task.output_path) {
		content := os.read_file(task.output_path) or { '' }
		out += if content.len > 0 { content } else { '(no output yet)' }
	} else {
		out += '(no output yet)'
	}
	return out
}

fn (mut s BashSession) bg_task_stop_text(id string) string {
	mut task := s.bg_tasks[id] or { return 'Error: unknown task_id ${id}' }
	if task.status != 'running' {
		return 'task ${id} already ${task.status}'
	}
	task.proc.signal_pgkill()
	task.proc.wait()
	task.proc.close()
	task.status = 'stopped'
	task.ended = time.now().unix_milli()
	return 'task ${id} stopped'
}
