module main

import os
import time
import json

const cron_runner_tick_interval_seconds = 30

fn parse_delay_seconds(raw string) !int {
	seconds := raw.trim_space().int()
	if seconds <= 0 {
		return error('delay 秒数必须大于 0')
	}
	return seconds
}

fn build_cron_delay_job(name string, delay_seconds int, command string, mut scheduler CronScheduler) !CronJob {
	run_at := time.now().unix() + delay_seconds
	return scheduler.add_once_job(name, run_at, command)
}

fn is_cron_cli_subcommand(args []string) bool {
	return args.len >= 2 && args[1] == 'cron'
}

fn cron_storage_path() string {
	return os.join_path(get_minimax_config_dir(), 'cron')
}

fn cron_logs_path() string {
	return os.join_path(cron_storage_path(), 'logs')
}

fn cron_job_log_path(job_id string) string {
	return os.join_path(cron_logs_path(), '${job_id}.log')
}

fn ensure_cron_storage_dirs() ! {
	os.mkdir_all(cron_storage_path())!
	os.mkdir_all(cron_logs_path())!
}

fn new_cli_cron_scheduler() !CronScheduler {
	ensure_cron_storage_dirs()!
	return new_cron_scheduler(cron_storage_path(), execute_cron_job)
}

fn format_cron_timestamp(ts i64) string {
	if ts <= 0 {
		return '-'
	}
	return time.unix(ts).utc_to_local().format_ss()
}

fn append_cron_job_log(job_id string, content string) ! {
	ensure_cron_storage_dirs()!
	path := cron_job_log_path(job_id)
	existing := os.read_file(path) or { '' }
	os.write_file(path, existing + content)!
}

fn execute_cron_job_shell(command string) (string, int) {
	bash_path := find_bash_path()
	if bash_path.len > 0 {
		actual_bash := if bash_path == 'bash' {
			os.find_abs_path_of_executable('bash') or { 'bash' }
		} else {
			bash_path
		}
		mut proc := os.new_process(actual_bash)
		proc.set_args(['-lc', command])
		proc.use_stdio_ctl = true
		proc.run()
		mut output := proc.stdout_slurp()
		output += proc.stderr_slurp()
		proc.wait()
		return output, proc.code
	}
	mut proc := os.new_process('cmd')
	proc.set_args(['/c', command])
	proc.use_stdio_ctl = true
	proc.run()
	mut output := proc.stdout_slurp()
	output += proc.stderr_slurp()
	proc.wait()
	return output, proc.code
}

fn execute_cron_job(job CronJob) ! {
	started_at := time.now()
	output, exit_code := execute_cron_job_shell(job.command)
	finished_at := time.now()
	mut lines := []string{}
	lines << '=== ${started_at.format_ss()} | ${job.id} | ${job.name} ==='
	lines << 'schedule: ${job.schedule}'
	lines << 'command: ${job.command}'
	lines << 'finished: ${finished_at.format_ss()}'
	lines << 'exit_code: ${exit_code}'
	if output.trim_space().len > 0 {
		lines << 'output:'
		lines << output.trim_right('\n')
		lines << ''
	}
	lines << ''
	append_cron_job_log(job.id, lines.join('\n'))!
	if exit_code != 0 {
		return error('Cron 任务执行失败（exit ${exit_code}）')
	}
}

fn cron_help_text() string {
	return [
		'用法: minimax_cli cron <command> [args]',
		'',
		'命令:',
		'  cron help',
		'  cron list',
		'  cron add <name> <schedule> <command...>',
		'  cron delay <seconds> <name> <command...>',
		'  cron add-once <seconds> <name> <command...>',
		'  cron show <id>',
		'  cron delete <id>',
		'  cron enable <id>',
		'  cron disable <id>',
		'  cron stats',
		'  cron tick',
		'  cron log <id>',
		'  cron run',
		'  cron timer <command> [args]',
		'',
		'说明:',
		'  schedule 支持标准 5 字段 Cron，以及 @daily/@hourly/@weekly/@monthly/@yearly/@every-30m',
		'  delay/add-once 用于一次性延迟执行，任务执行后会自动停用',
		'  cron run 会常驻运行并每 30 秒检查一次任务',
		'  cron timer 提供类似 JS setTimeout/setInterval 的可取消定时器',
		'  任务持久化目录: ${cron_storage_path()}',
		'',
		'示例:',
		'  minimax_cli cron add x-latest "*/5 * * * *" /Users/byf/bl/github/minimax-v/minimax_cli --mcp -p "打开 x.com，获取最新动态并用中文总结"',
		'  minimax_cli cron delay 60 x-once /Users/byf/bl/github/minimax-v/minimax_cli --mcp -p "1分钟后打开 x.com，获取最新动态并用中文总结"',
		'  minimax_cli cron list',
		'  minimax_cli cron run',
	].join('\n')
}

fn build_cron_jobs_text(jobs []CronJob) string {
	if jobs.len == 0 {
		return '当前没有 Cron 任务'
	}
	mut ordered := jobs.clone()
	ordered.sort(a.created_at < b.created_at)
	mut lines := ['Cron 任务列表:']
	for job in ordered {
		status := if job.enabled { 'enabled' } else { 'disabled' }
		job_type := if job.run_once { 'once' } else { 'cron' }
		lines << '[${job.id}] ${job.name} (${status}, ${job_type})'
		lines << '  schedule: ${job.schedule}'
		lines << '  next_run: ${format_cron_timestamp(job.next_run)}'
		lines << '  last_run: ${format_cron_timestamp(job.last_run)}'
		lines << '  executions: ${job.execution_count}'
		lines << '  command: ${job.command}'
	}
	return lines.join('\n')
}

fn build_cron_job_text(job CronJob) string {
	status := if job.enabled { 'enabled' } else { 'disabled' }
	job_type := if job.run_once { 'once' } else { 'cron' }
	return [
		'任务 ID: ${job.id}',
		'名称: ${job.name}',
		'类型: ${job_type}',
		'状态: ${status}',
		'计划: ${job.schedule}',
		'下次执行: ${format_cron_timestamp(job.next_run)}',
		'上次执行: ${format_cron_timestamp(job.last_run)}',
		'执行次数: ${job.execution_count}',
		'创建时间: ${format_cron_timestamp(job.created_at)}',
		'日志文件: ${cron_job_log_path(job.id)}',
		'命令: ${job.command}',
	].join('\n')
}

fn build_cron_stats_text(stats map[string]int) string {
	return [
		'Cron 统计:',
		'  total_jobs: ${stats['total_jobs']}',
		'  enabled_jobs: ${stats['enabled_jobs']}',
		'  disabled_jobs: ${stats['disabled_jobs']}',
		'  total_executions: ${stats['total_executions']}',
	].join('\n')
}

// ──────────────────────────────────────────────
// Timer 定时器（类似 JS setTimeout/setInterval）
// ──────────────────────────────────────────────

__global g_timer_manager = TimerManager{}

fn timer_storage_path() string {
	return os.join_path(get_minimax_config_dir(), 'timers.json')
}

fn ensure_timer_storage() ! {
	dir := os.join_path(get_minimax_config_dir())
	if !os.is_dir(dir) {
		os.mkdir_all(dir)!
	}
}

fn load_timers() ! {
	ensure_timer_storage()!
	path := timer_storage_path()
	if !os.exists(path) {
		return
	}
	content := os.read_file(path)!
	if content.len == 0 {
		return
	}
	timers := json.decode([]Timer, content) or {
		return error('定时器文件(${path})损坏，无法加载: ${err}')
	}
	for timer in timers {
		g_timer_manager.timers[timer.id] = timer
	}
}

fn save_timers() ! {
	ensure_timer_storage()!
	mut timer_list := []Timer{}
	for _, timer in g_timer_manager.timers {
		timer_list << timer
	}
	data := json.encode(timer_list)
	os.write_file(timer_storage_path(), data)!
}

fn execute_timer_job(timer Timer) ! {
	started_at := time.now()
	output, exit_code := execute_cron_job_shell(timer.command)
	finished_at := time.now()
	mut lines := []string{}
	lines << '=== ${started_at.format_ss()} | ${timer.id} | ${timer.name} ==='
	lines << 'type: ${timer.timer_type}'
	lines << 'command: ${timer.command}'
	lines << 'finished: ${finished_at.format_ss()}'
	lines << 'exit_code: ${exit_code}'
	if output.trim_space().len > 0 {
		lines << 'output:'
		lines << output.trim_right('\n')
	}
	lines << ''
	append_cron_job_log(timer.id, lines.join('\n'))!
	if exit_code != 0 {
		return error('Timer 任务执行失败（exit ${exit_code}）')
	}
}

fn format_timer_timestamp(ts i64) string {
	if ts <= 0 {
		return '-'
	}
	return time.unix(ts).utc_to_local().format_ss()
}

fn build_timer_text(timer Timer) string {
	timer_type_str := match timer.timer_type {
		.timeout { 'setTimeout' }
		.interval { 'setInterval' }
	}
	status := if timer.enabled { 'enabled' } else { 'disabled' }
	interval_str := if timer.interval_sec > 0 {
		'${timer.interval_sec}s'
	} else {
		'一次性'
	}
	return [
		'Timer ID: ${timer.id}',
		'名称: ${timer.name}',
		'类型: ${timer_type_str}',
		'状态: ${status}',
		'间隔: ${interval_str}',
		'下次执行: ${format_timer_timestamp(timer.next_run)}',
		'创建时间: ${format_timer_timestamp(timer.created_at)}',
		'命令: ${timer.command}',
	].join('\n')
}

fn build_timers_text(timers []Timer) string {
	if timers.len == 0 {
		return '当前没有定时器'
	}
	mut lines := ['定时器列表:']
	for timer in timers {
		timer_type_str := match timer.timer_type {
			.timeout { 'timeout' }
			.interval { 'interval' }
		}
		status := if timer.enabled { '✓' } else { '✗' }
		lines << '${status} [${timer.id}] ${timer.name} (${timer_type_str}, 下次 ${format_timer_timestamp(timer.next_run)})'
	}
	return lines.join('\n')
}

fn build_timer_stats_text(stats map[string]int) string {
	return [
		'Timer 统计:',
		'  total_timers: ${stats['total_timers']}',
		'  enabled: ${stats['enabled']}',
		'  disabled: ${stats['disabled']}',
		'  timeouts: ${stats['timeouts']}',
		'  intervals: ${stats['intervals']}',
	].join('\n')
}

// 统一的定时器创建入口，收敛 set-timeout 和 set-interval 的重复逻辑
fn timer_create(mut mgr TimerManager, name string, seconds int, command string, is_interval bool) (string, int) {
	timer := if is_interval {
		mgr.set_interval(name, seconds, command) or {
			return '❌ 创建 setInterval 失败: ${err}', 1
		}
	} else {
		mgr.set_timeout(name, seconds, command) or {
			return '❌ 创建 setTimeout 失败: ${err}', 1
		}
	}
	save_timers() or { return '❌ 定时器已创建但保存失败: ${err}', 1 }
	type_label := if is_interval { 'setInterval' } else { 'setTimeout' }
	return '✅ ${type_label} 已创建\n' + build_timer_text(timer), 0
}

// 定时器帮助
fn timer_cmd_help() (string, int) {
	return timer_help_text(), 0
}

// 定时器列表
fn timer_cmd_list(mgr &TimerManager) (string, int) {
	return build_timers_text(mgr.list_timers()), 0
}

// 定时器统计
fn timer_cmd_stats(mgr &TimerManager) (string, int) {
	return build_timer_stats_text(mgr.get_timer_stats()), 0
}

// 定时器创建
fn timer_cmd_set(args []string, mut mgr TimerManager) (string, int) {
	if args.len < 4 {
		usage := '用法: minimax_cli cron timer set-timeout <name> <seconds> <command...>\n' +
			'       minimax_cli cron timer set-interval <name> <seconds> <command...>'
		return usage, 2
	}
	name := args[1]
	seconds := args[2].int()
	command := args[3..].join(' ')
	is_interval := args[0] == 'set-interval' || args[0] == 'interval'
	return timer_create(mut mgr, name, seconds, command, is_interval)
}

// 取消定时器
fn timer_cmd_clear(args []string, mut mgr TimerManager) (string, int) {
	if args.len < 2 {
		return '用法: minimax_cli cron timer clear <name-or-id>', 2
	}
	target := args[1]
	if mgr.clear_timer(target) {
		save_timers() or { return '✅ 已取消但保存失败: ${err}', 1 }
		return '✅ 已取消定时器: ${target}', 0
	}
	removed := mgr.clear_timer_by_name(target)
	if removed > 0 {
		save_timers() or { return '✅ 已取消 ${removed} 个但保存失败: ${err}', 1 }
		return '✅ 已取消 ${removed} 个名为 "${target}" 的定时器', 0
	}
	return '❌ 未找到定时器: ${target}', 1
}

// 显示定时器详情
fn timer_cmd_show(args []string, mgr &TimerManager) (string, int) {
	if args.len < 2 {
		return '用法: minimax_cli cron timer show <id>', 2
	}
	timer := mgr.get_timer(args[1]) or { return '❌ 定时器不存在: ${args[1]}', 1 }
	return build_timer_text(timer), 0
}

// 格式化 tick 执行结果，消除 timer_cmd_tick 和 timer_cmd_run 的重复逻辑
fn timer_format_tick_result(executed []string, had_failure bool) (string, int) {
	if executed.len == 0 {
		return '✅ Timer tick 执行完成（无到期定时器）', 0
	}
	if had_failure {
		return '✅ 已执行 ${executed.len} 个定时器，其中部分执行失败: ${executed.join(', ')}', 1
	}
	return '✅ 已执行 ${executed.len} 个定时器: ${executed.join(', ')}', 0
}

// 单次 tick
fn timer_cmd_tick(mut mgr TimerManager) (string, int) {
	executed, had_failure := mgr.tick_execute(execute_timer_job)
	save_timers() or { return '❌ 保存定时器失败: ${err}', 1 }
	return timer_format_tick_result(executed, had_failure)
}

// 持续运行
fn timer_cmd_run(mut mgr TimerManager) (string, int) {
	load_timers() or { return '❌ 加载定时器失败: ${err}', 1 }
	println('Timer runner 已启动，Ctrl+C 退出')
	for {
		executed, had_failure := mgr.tick_execute(execute_timer_job)
		if executed.len > 0 {
			msg, _ := timer_format_tick_result(executed, had_failure)
			println(msg)
		}
		save_timers() or { return '❌ 保存定时器失败: ${err}', 1 }
		time.sleep(1 * time.second)
	}
	return '', 0
}

fn execute_timer_command(args []string, mut mgr TimerManager) (string, int) {
	if args.len == 0 {
		return timer_help_text(), 0
	}

	load_timers() or { return '❌ 加载定时器失败: ${err}', 1 }

	match args[0] {
		'help' {
			return timer_cmd_help()
		}
		'list', 'ls' {
			return timer_cmd_list(mgr)
		}
		'stats' {
			return timer_cmd_stats(mgr)
		}
		'set-timeout', 'timeout', 'set-interval', 'interval' {
			return timer_cmd_set(args, mut mgr)
		}
		'clear', 'cancel' {
			return timer_cmd_clear(args, mut mgr)
		}
		'show' {
			return timer_cmd_show(args, mgr)
		}
		'tick' {
			return timer_cmd_tick(mut mgr)
		}
		'run' {
			return timer_cmd_run(mut mgr)
		}
		else {
			return '未知 timer 命令: ${args[0]}\n\n' + timer_help_text(), 2
		}
	}
}

fn timer_help_text() string {
	return [
		'用法: minimax_cli cron timer <command> [args]',
		'',
		'命令:',
		'  timer help',
		'  timer list, timer ls',
		'  timer stats',
		'  timer set-timeout <name> <seconds> <command...>',
		'  timer set-interval <name> <seconds> <command...>',
		'  timer clear <name-or-id>',
		'  timer show <id>',
		'  timer tick',
		'  timer run',
		'',
		'说明:',
		'  set-timeout: 延迟指定秒数后执行一次（类似 JS setTimeout）',
		'  set-interval: 每隔指定秒数重复执行（类似 JS setInterval）',
		'  clear: 按 ID 或名称取消定时器（名称会取消所有同名定时器）',
		'  tick: 检查并执行到期的定时器（单次）',
		'  run: 持续运行定时器，每秒检查一次',
		'  定时器持久化存储在: ${timer_storage_path()}',
		'',
		'示例:',
		'  minimax_cli cron timer set-timeout my-timeout 60 "echo hello"',
		'  minimax_cli cron timer set-interval my-interval 300 "echo heartbeat"',
		'  minimax_cli cron timer clear my-timeout',
		'  minimax_cli cron timer list',
		'  minimax_cli cron timer run',
	].join('\n')
}

fn execute_cron_cli_command(args []string) (string, int) {
	if args.len == 0 {
		return cron_help_text(), 0
	}

	mut scheduler := new_cli_cron_scheduler() or {
		return '❌ 初始化 Cron 调度器失败: ${err}', 1
	}

	match args[0] {
		'help' {
			return cron_help_text(), 0
		}
		'list' {
			return build_cron_jobs_text(scheduler.list_jobs()), 0
		}
		'add' {
			if args.len < 4 {
				return '用法: minimax_cli cron add <name> <schedule> <command...>', 2
			}
			name := args[1]
			schedule := args[2]
			command := args[3..].join(' ')
			job := scheduler.add_job(name, schedule, command) or {
				return '❌ 添加 Cron 任务失败: ${err}', 1
			}
			return '✅ Cron 任务已创建\n' + build_cron_job_text(job), 0
		}
		'delay', 'add-once' {
			if args.len < 4 {
				return '用法: minimax_cli cron delay <seconds> <name> <command...>', 2
			}
			delay_seconds := parse_delay_seconds(args[1]) or {
				return '❌ 创建一次性任务失败: ${err}', 1
			}
			name := args[2]
			command := args[3..].join(' ')
			job := build_cron_delay_job(name, delay_seconds, command, mut scheduler) or {
				return '❌ 创建一次性任务失败: ${err}', 1
			}
			return '✅ 一次性 Cron 任务已创建\n' + build_cron_job_text(job), 0
		}
		'show' {
			if args.len < 2 {
				return '用法: minimax_cli cron show <id>', 2
			}
			job := scheduler.get_job(args[1]) or { return '❌ 任务不存在: ${args[1]}', 1 }
			return build_cron_job_text(job), 0
		}
		'delete', 'remove' {
			if args.len < 2 {
				return '用法: minimax_cli cron delete <id>', 2
			}
			scheduler.delete_job(args[1]) or { return '❌ 删除 Cron 任务失败: ${err}', 1 }
			return '✅ 已删除 Cron 任务: ${args[1]}', 0
		}
		'enable' {
			if args.len < 2 {
				return '用法: minimax_cli cron enable <id>', 2
			}
			scheduler.set_job_enabled(args[1], true) or {
				return '❌ 启用 Cron 任务失败: ${err}', 1
			}
			return '✅ 已启用 Cron 任务: ${args[1]}', 0
		}
		'disable' {
			if args.len < 2 {
				return '用法: minimax_cli cron disable <id>', 2
			}
			scheduler.set_job_enabled(args[1], false) or {
				return '❌ 禁用 Cron 任务失败: ${err}', 1
			}
			return '✅ 已禁用 Cron 任务: ${args[1]}', 0
		}
		'stats' {
			return build_cron_stats_text(scheduler.get_stats()), 0
		}
		'log' {
			if args.len < 2 {
				return '用法: minimax_cli cron log <id>', 2
			}
			content := os.read_file(cron_job_log_path(args[1])) or {
				return '❌ 日志不存在: ${args[1]}', 1
			}
			return content, 0
		}
		'tick' {
			scheduler.start()
			scheduler.tick() or { return '❌ Cron tick 执行失败: ${err}', 1 }
			scheduler.stop()
			return '✅ Cron tick 执行完成', 0
		}
		'run' {
			scheduler.start()
			println('Cron runner 已启动，存储目录: ${cron_storage_path()}，检查间隔: ${cron_runner_tick_interval_seconds}s')
			for {
				scheduler.tick() or { eprintln('Cron tick 失败: ${err}') }
				time.sleep(cron_runner_tick_interval_seconds * time.second)
			}
			return '', 0
		}
		'timer' {
			return execute_timer_command(args[1..], mut g_timer_manager)
		}
		else {
			return '未知 cron 命令: ${args[0]}\n\n' + cron_help_text(), 2
		}
	}
}

fn handle_cron_cli_command(args []string) int {
	output, exit_code := execute_cron_cli_command(args)
	if output.len > 0 {
		if exit_code == 0 {
			println(output)
		} else {
			eprintln(output)
		}
	}
	return exit_code
}
