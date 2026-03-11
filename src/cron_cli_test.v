module main

import os
import time

fn cron_cli_test_home_dir(prefix string) string {
	return os.join_path(os.temp_dir(), '${prefix}_${os.getpid()}_${time.now().unix_milli()}')
}

fn cron_cli_with_temp_home(prefix string, run fn ()) {
	tmp_home := cron_cli_test_home_dir(prefix)
	os.mkdir_all(tmp_home) or { panic(err) }
	old_home := os.home_dir()
	os.setenv('HOME', tmp_home, true)
	defer {
		os.setenv('HOME', old_home, true)
		os.rmdir_all(tmp_home) or {}
	}
	run()
}

fn test_execute_cron_cli_command_help() {
	output, exit_code := execute_cron_cli_command(['help'])
	assert exit_code == 0
	assert output.contains('minimax_cli cron <command>')
	assert output.contains('cron run')
	assert output.contains('cron delay <seconds> <name> <command...>')
}

fn test_execute_cron_cli_command_add_and_show() {
	cron_cli_with_temp_home('minimax_cron_cli_home', fn () {
		add_output, add_exit := execute_cron_cli_command(['add', 'demo-job', '@hourly', 'echo',
			'hello'])
		assert add_exit == 0
		assert add_output.contains('✅ Cron 任务已创建')
		assert add_output.contains('名称: demo-job')

		mut scheduler := new_cli_cron_scheduler() or { panic(err) }
		jobs := scheduler.list_jobs()
		assert jobs.len == 1
		job_id := jobs[0].id

		show_output, show_exit := execute_cron_cli_command(['show', job_id])
		assert show_exit == 0
		assert show_output.contains('任务 ID: ${job_id}')
		assert show_output.contains('名称: demo-job')

		list_output, list_exit := execute_cron_cli_command(['list'])
		assert list_exit == 0
		assert list_output.contains('demo-job')
		assert list_output.contains('schedule: @hourly')
	})
}

fn test_execute_cron_cli_command_delay_and_tick() {
	cron_cli_with_temp_home('minimax_cron_delay_home', fn () {
		delay_output, delay_exit := execute_cron_cli_command(['delay', '1', 'once-job', 'echo',
			'delayed'])
		assert delay_exit == 0
		assert delay_output.contains('✅ 一次性 Cron 任务已创建')
		assert delay_output.contains('类型: once')

		time.sleep(1100 * time.millisecond)
		tick_output, tick_exit := execute_cron_cli_command(['tick'])
		assert tick_exit == 0
		assert tick_output.contains('✅ Cron tick 执行完成')

		mut scheduler := new_cli_cron_scheduler() or { panic(err) }
		jobs := scheduler.list_jobs()
		assert jobs.len == 1
		job_id := jobs[0].id

		log_output, log_exit := execute_cron_cli_command(['log', job_id])
		assert log_exit == 0
		assert log_output.contains('once-job')
		assert log_output.contains('exit_code: 0')
		assert log_output.contains('command: echo delayed')

		list_output, list_exit := execute_cron_cli_command(['list'])
		assert list_exit == 0
		assert list_output.contains('once-job')
		assert list_output.contains('(disabled, once)')
	})
}

fn test_execute_cron_cli_command_enable_disable_stats_and_delete() {
	cron_cli_with_temp_home('minimax_cron_manage_home', fn () {
		_, add_exit := execute_cron_cli_command(['add', 'managed-job', '@daily', 'echo', 'managed'])
		assert add_exit == 0

		mut scheduler := new_cli_cron_scheduler() or { panic(err) }
		jobs := scheduler.list_jobs()
		assert jobs.len == 1
		job_id := jobs[0].id

		disable_output, disable_exit := execute_cron_cli_command(['disable', job_id])
		assert disable_exit == 0
		assert disable_output.contains('✅ 已禁用 Cron 任务')

		enable_output, enable_exit := execute_cron_cli_command(['enable', job_id])
		assert enable_exit == 0
		assert enable_output.contains('✅ 已启用 Cron 任务')

		stats_output, stats_exit := execute_cron_cli_command(['stats'])
		assert stats_exit == 0
		assert stats_output.contains('total_jobs: 1')
		assert stats_output.contains('enabled_jobs: 1')

		delete_output, delete_exit := execute_cron_cli_command(['delete', job_id])
		assert delete_exit == 0
		assert delete_output.contains('✅ 已删除 Cron 任务')

		list_output, list_exit := execute_cron_cli_command(['list'])
		assert list_exit == 0
		assert list_output.contains('当前没有 Cron 任务')
	})
}

fn test_execute_cron_cli_command_errors() {
	cron_cli_with_temp_home('minimax_cron_error_home', fn () {
		show_output, show_exit := execute_cron_cli_command(['show'])
		assert show_exit == 2
		assert show_output.contains('用法: minimax_cli cron show <id>')

		unknown_output, unknown_exit := execute_cron_cli_command(['wat'])
		assert unknown_exit == 2
		assert unknown_output.contains('未知 cron 命令: wat')

		missing_log_output, missing_log_exit := execute_cron_cli_command(['log', 'missing'])
		assert missing_log_exit == 1
		assert missing_log_output.contains('❌ 日志不存在')
	})
}
