module main

import os
import time

fn cron_dashboard_test_home_dir(prefix string) string {
	return os.join_path(os.temp_dir(), '${prefix}_${os.getpid()}_${time.now().unix_milli()}')
}

fn cron_dashboard_with_temp_home(prefix string, run fn ()) {
	tmp_home := cron_dashboard_test_home_dir(prefix)
	os.mkdir_all(tmp_home) or { panic(err) }
	old_home := os.home_dir()
	old_skip_daemon := os.getenv_opt('MINIMAX_SKIP_CRON_DAEMON_START') or { '' }
	os.setenv('HOME', tmp_home, true)
	os.setenv('MINIMAX_SKIP_CRON_DAEMON_START', '1', true)
	defer {
		os.setenv('HOME', old_home, true)
		if old_skip_daemon.len > 0 {
			os.setenv('MINIMAX_SKIP_CRON_DAEMON_START', old_skip_daemon, true)
		} else {
			os.unsetenv('MINIMAX_SKIP_CRON_DAEMON_START')
		}
		os.rmdir_all(tmp_home) or {}
	}
	run()
}

fn test_cron_dashboard_sync_and_snapshot() {
	cron_dashboard_with_temp_home('minimax_cron_dashboard_home', fn () {
		mut scheduler := new_cli_cron_scheduler() or { panic(err) }
		job := scheduler.add_job('dashboard-job', '@hourly', 'echo hello <world>') or { panic(err) }
		assert job.name == 'dashboard-job'

		snapshot := load_cron_dashboard_snapshot(cron_dashboard_db_path(), cron_storage_path()) or {
			panic(err)
		}
		assert snapshot.total_jobs == 1
		assert snapshot.enabled_jobs == 1
		assert snapshot.jobs.len == 1
		assert snapshot.jobs[0].name == 'dashboard-job'
		assert snapshot.jobs[0].command == 'echo hello <world>'
		assert snapshot.jobs[0].schedule == '@hourly'
	})
}

fn test_cron_dashboard_execution_recording() {
	cron_dashboard_with_temp_home('minimax_cron_dashboard_exec_home', fn () {
		mut scheduler := new_cli_cron_scheduler() or { panic(err) }
		job := scheduler.add_job('execution-job', '@daily', 'echo execution') or { panic(err) }
		started_at := time.unix(1_700_000_000)
		finished_at := time.unix(1_700_000_003)
		record_cron_dashboard_execution(job, started_at, finished_at, 0, 'line 1\n<done>') or {
			panic(err)
		}

		snapshot := load_cron_dashboard_snapshot(cron_dashboard_db_path(), cron_storage_path()) or {
			panic(err)
		}
		assert snapshot.total_executions == 1
		assert snapshot.failed_executions == 0
		assert snapshot.executions.len == 1
		assert snapshot.executions[0].job_name == 'execution-job'
		assert snapshot.executions[0].output == 'line 1\n<done>'
		assert snapshot.executions[0].duration_ms == 3000
	})
}

fn test_build_cron_dashboard_page_escapes_dynamic_content() {
	snapshot := CronDashboardSnapshot{
		generated_at:      time.now().unix()
		db_path:           '/tmp/cron-dashboard.sqlite'
		storage_path:      '/tmp/cron'
		total_jobs:        1
		enabled_jobs:      1
		disabled_jobs:     0
		total_executions:  1
		failed_executions: 0
		jobs:              [
			CronDashboardJobView{
				job_id:          'cron_test_1'
				name:            'dashboard <job>'
				schedule:        '@hourly'
				command:         'echo "<html>"'
				run_once:        false
				enabled:         true
				last_run:        1_700_000_000
				next_run:        1_700_000_600
				execution_count: 4
				created_at:      1_700_000_000
			},
		]
		executions:        [
			CronDashboardExecutionView{
				id:          1
				job_id:      'cron_test_1'
				job_name:    'dashboard <job>'
				schedule:    '@hourly'
				command:     'echo "<html>"'
				started_at:  1_700_000_000
				finished_at: 1_700_000_002
				duration_ms: 2000
				exit_code:   0
				output:      'line <one>'
				created_at:  1_700_000_002
			},
		]
	}
	page := build_cron_dashboard_page(snapshot, 8787)
	assert page.contains('Cron Dashboard')
	assert page.contains('静态任务与执行视图')
	assert page.contains('任务总数')
	assert page.contains('最近执行')
	assert page.contains('生成于')
	assert page.contains('dashboard &lt;job&gt;')
	assert page.contains('echo &quot;&lt;html&gt;&quot;')
	assert page.contains('line &lt;one&gt;')
	assert page.contains('SQLite')
	assert page.contains('minimax_cli cron dashboard')
}

fn test_render_cron_dashboard_error_page_escapes_dynamic_content() {
	page := build_cron_dashboard_error_page('sqlite <down>', '/tmp/cron-dashboard.sqlite')
	assert page.contains('Cron Dashboard 无法加载')
	assert page.contains('sqlite &lt;down&gt;')
	assert page.contains('/tmp/cron-dashboard.sqlite')
}
