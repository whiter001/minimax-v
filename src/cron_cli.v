module main

import os
import time

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
	return os.join_path(os.home_dir(), '.config', 'minimax', 'cron')
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
		result := os.execute('${shell_escape(actual_bash)} -lc ${shell_escape(command)}')
		return result.output, result.exit_code
	}
	result := os.execute('cmd /c ${shell_escape_windows(command)}')
	return result.output, result.exit_code
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
		'',
		'说明:',
		'  schedule 支持标准 5 字段 Cron，以及 @daily/@hourly/@weekly/@monthly/@yearly/@every-30m',
		'  delay/add-once 用于一次性延迟执行，任务执行后会自动停用',
		'  cron run 会常驻运行并每 30 秒检查一次任务',
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
