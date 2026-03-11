module main

import os
import time

fn cron_test_tmp_dir(prefix string) string {
	return os.join_path(os.temp_dir(), '${prefix}_${os.getpid()}_${time.now().unix_milli()}')
}

// ──────────────────────────────────────────────
// validate_cron_expression 合法表达式
// ──────────────────────────────────────────────

fn test_validate_cron_valid_wildcard() {
	validate_cron_expression('* * * * *') or { assert false, 'wildcard 应该合法' }
}

fn test_validate_cron_valid_exact() {
	validate_cron_expression('30 8 1 1 0') or { assert false, '精确值应该合法' }
}

fn test_validate_cron_valid_range() {
	validate_cron_expression('0-30 9-17 * * 1-5') or { assert false, '范围表达式应该合法' }
}

fn test_validate_cron_valid_list() {
	validate_cron_expression('0,15,30,45 * * * *') or {
		assert false, '列表表达式应该合法'
	}
}

fn test_validate_cron_valid_step() {
	validate_cron_expression('*/5 * * * *') or { assert false, '步长表达式应该合法' }
}

fn test_validate_cron_valid_step_2() {
	validate_cron_expression('0 */2 * * *') or { assert false, '每2小时步长应该合法' }
}

// ──────────────────────────────────────────────
// validate_cron_expression 非法表达式
// ──────────────────────────────────────────────

fn test_validate_cron_too_few_fields() {
	validate_cron_expression('* * *') or { return }
	assert false, '字段数不足应该报错'
}

fn test_validate_cron_too_many_fields() {
	validate_cron_expression('* * * * * *') or { return }
	assert false, '字段数过多应该报错'
}

fn test_validate_cron_minute_out_of_range() {
	validate_cron_expression('60 * * * *') or { return }
	assert false, '分钟 60 超出范围应该报错'
}

fn test_validate_cron_hour_out_of_range() {
	validate_cron_expression('* 24 * * *') or { return }
	assert false, '小时 24 超出范围应该报错'
}

fn test_validate_cron_day_out_of_range() {
	validate_cron_expression('* * 32 * *') or { return }
	assert false, '日期 32 超出范围应该报错'
}

fn test_validate_cron_month_out_of_range() {
	validate_cron_expression('* * * 13 *') or { return }
	assert false, '月份 13 超出范围应该报错'
}

fn test_validate_cron_weekday_out_of_range() {
	validate_cron_expression('* * * * 7') or { return }
	assert false, '星期 7 超出范围应该报错'
}

fn test_validate_cron_zero_step() {
	validate_cron_expression('*/0 * * * *') or { return }
	assert false, '步长为 0 应该报错'
}

// ──────────────────────────────────────────────
// normalize_cron_preset 预设展开
// ──────────────────────────────────────────────

fn test_normalize_preset_daily() {
	result := normalize_cron_preset('@daily')
	assert result == '0 0 * * *', '@daily 应展开为 0 0 * * *'
}

fn test_normalize_preset_midnight() {
	result := normalize_cron_preset('@midnight')
	assert result == '0 0 * * *', '@midnight 与 @daily 等价'
}

fn test_normalize_preset_hourly() {
	result := normalize_cron_preset('@hourly')
	assert result == '0 * * * *', '@hourly 应展开为 0 * * * *'
}

fn test_normalize_preset_weekly() {
	result := normalize_cron_preset('@weekly')
	assert result == '0 0 * * 0', '@weekly 应展开'
}

fn test_normalize_preset_monthly() {
	result := normalize_cron_preset('@monthly')
	assert result == '0 0 1 * *', '@monthly 应展开'
}

fn test_normalize_preset_yearly() {
	result := normalize_cron_preset('@yearly')
	assert result == '0 0 1 1 *', '@yearly 应展开'
}

fn test_normalize_preset_annually() {
	result := normalize_cron_preset('@annually')
	assert result == '0 0 1 1 *', '@annually 与 @yearly 等价'
}

fn test_normalize_preset_every_30m() {
	result := normalize_cron_preset('@every-30m')
	assert result == '*/30 * * * *', '@every-30m 应展开为 */30 * * * *'
}

fn test_normalize_preset_passthrough() {
	expr := '5 4 * * 1'
	result := normalize_cron_preset(expr)
	assert result == expr, '非预设表达式应原样返回'
}

// ──────────────────────────────────────────────
// validate_cron_expression 使用预设
// ──────────────────────────────────────────────

fn test_validate_cron_preset_daily() {
	validate_cron_expression('@daily') or { assert false, '@daily 预设应合法' }
}

fn test_validate_cron_preset_hourly() {
	validate_cron_expression('@hourly') or { assert false, '@hourly 预设应合法' }
}

fn test_validate_cron_preset_every_30m() {
	validate_cron_expression('@every-30m') or { assert false, '@every-30m 预设应合法' }
}

// ──────────────────────────────────────────────
// calculate_next_run 返回值合理性
// ──────────────────────────────────────────────

fn test_calculate_next_run_is_future() {
	now := time.now().unix()
	next := calculate_next_run('* * * * *')
	assert next > now, 'next_run 应该大于当前时间'
}

fn test_calculate_next_run_daily_is_future() {
	now := time.now().unix()
	next := calculate_next_run('@daily')
	assert next > now, '@daily next_run 应该大于当前时间'
}

fn test_calculate_next_run_invalid_returns_future() {
	now := time.now().unix()
	// 非法表达式回退到 1 小时后
	next := calculate_next_run('invalid')
	assert next >= now + 3600, '非法表达式应回退到 1 小时后'
}

// ──────────────────────────────────────────────
// matches_cron_time 时间匹配
// ──────────────────────────────────────────────

fn test_matches_cron_wildcard_always_true() {
	t := time.now()
	assert matches_cron_time(t, '* * * * *') == true, '全通配符应始终返回 true'
}

fn test_matches_cron_exact_minute_match() {
	// 构造 minute=0, hour=0, day=1, month=1 的时间
	t := time.Time{
		year:   2026
		month:  1
		day:    1
		hour:   0
		minute: 0
	}
	assert matches_cron_time(t, '0 0 1 1 *') == true, '精确匹配应返回 true'
}

fn test_matches_cron_minute_no_match() {
	t := time.Time{
		year:   2026
		month:  1
		day:    1
		hour:   0
		minute: 5
	}
	// 期望 minute=0 但传入 minute=5
	assert matches_cron_time(t, '0 0 1 1 *') == false, '分钟不匹配应返回 false'
}

fn test_matches_cron_hour_no_match() {
	t := time.Time{
		year:   2026
		month:  1
		day:    1
		hour:   12
		minute: 0
	}
	assert matches_cron_time(t, '0 9 * * *') == false, '小时不匹配应返回 false'
}

fn test_matches_cron_list_minute() {
	t := time.Time{
		year:   2026
		month:  6
		day:    15
		hour:   10
		minute: 15
	}
	assert matches_cron_time(t, '0,15,30,45 * * * *') == true, '列表分钟匹配应返回 true'
}

fn test_matches_cron_step_range_and_weekday() {
	t := time.Time{
		year:   2026
		month:  3
		day:    2
		hour:   10
		minute: 15
	}
	assert matches_cron_time(t, '*/15 10 2 3 1')
	assert matches_cron_time(t, '10-20 10 2 3 1')
	assert !matches_cron_time(t, '*/20 10 2 3 1')
	assert !matches_cron_time(t, '*/15 10 2 3 0')
}

// ──────────────────────────────────────────────
// CronScheduler CRUD 操作
// ──────────────────────────────────────────────

fn test_cron_scheduler_add_and_list() {
	tmp := cron_test_tmp_dir('cron_test')
	mut sched := new_cron_scheduler(tmp, fn (job CronJob) ! {}) or {
		assert false, '创建调度器失败: ${err}'
		return
	}
	defer { os.rmdir_all(tmp) or {} }

	job := sched.add_job('test-job', '*/5 * * * *', 'echo hello') or {
		assert false, '添加任务失败: ${err}'
		return
	}
	assert job.name == 'test-job'
	assert job.schedule == '*/5 * * * *'
	assert job.enabled == true
	assert job.execution_count == 0

	jobs := sched.list_jobs()
	assert jobs.len == 1, '应该有 1 个任务'
	assert jobs[0].name == 'test-job'
}

fn test_cron_scheduler_add_invalid_schedule_fails() {
	tmp := cron_test_tmp_dir('cron_test_invalid')
	mut sched := new_cron_scheduler(tmp, fn (job CronJob) ! {}) or { return }
	defer { os.rmdir_all(tmp) or {} }

	sched.add_job('bad', 'not-a-cron', 'echo x') or { return }
	assert false, '非法 Cron 表达式添加任务应失败'
}

fn test_cron_scheduler_delete_job() {
	tmp := cron_test_tmp_dir('cron_test_del')
	mut sched := new_cron_scheduler(tmp, fn (job CronJob) ! {}) or { return }
	defer { os.rmdir_all(tmp) or {} }

	job := sched.add_job('del-job', '* * * * *', 'echo del') or { return }
	assert sched.list_jobs().len == 1

	sched.delete_job(job.id) or { assert false, '删除任务失败' }
	assert sched.list_jobs().len == 0, '删除后任务列表应为空'
}

fn test_cron_scheduler_delete_nonexistent_fails() {
	tmp := cron_test_tmp_dir('cron_test_noexist')
	mut sched := new_cron_scheduler(tmp, fn (job CronJob) ! {}) or { return }
	defer { os.rmdir_all(tmp) or {} }

	sched.delete_job('nonexistent-id') or { return }
	assert false, '删除不存在的任务应失败'
}

fn test_cron_scheduler_set_enabled() {
	tmp := cron_test_tmp_dir('cron_test_enable')
	mut sched := new_cron_scheduler(tmp, fn (job CronJob) ! {}) or { return }
	defer { os.rmdir_all(tmp) or {} }

	job := sched.add_job('enable-job', '@hourly', 'echo enable') or { return }
	assert job.enabled == true

	sched.set_job_enabled(job.id, false) or { assert false, '禁用任务失败' }
	jobs := sched.list_jobs()
	assert jobs[0].enabled == false, '任务应被禁用'

	sched.set_job_enabled(job.id, true) or { assert false, '重新启用任务失败' }
	jobs2 := sched.list_jobs()
	assert jobs2[0].enabled == true, '任务应被重新启用'
}

fn test_cron_scheduler_set_enabled_nonexistent_fails() {
	tmp := cron_test_tmp_dir('cron_test_noexist_en')
	mut sched := new_cron_scheduler(tmp, fn (job CronJob) ! {}) or { return }
	defer { os.rmdir_all(tmp) or {} }

	sched.set_job_enabled('bad-id', false) or { return }
	assert false, '对不存在任务设置 enabled 应失败'
}

fn test_cron_scheduler_get_stats() {
	tmp := cron_test_tmp_dir('cron_test_stats')
	mut sched := new_cron_scheduler(tmp, fn (job CronJob) ! {}) or { return }
	defer { os.rmdir_all(tmp) or {} }

	sched.add_job('job1', '* * * * *', 'echo 1') or { return }
	time.sleep(2 * time.millisecond) // 避免 ID（unix_milli）碰撞
	job2 := sched.add_job('job2', '@daily', 'echo 2') or { return }
	sched.set_job_enabled(job2.id, false) or { return }

	stats := sched.get_stats()
	assert stats['total_jobs'] == 2
	assert stats['enabled_jobs'] == 1
	assert stats['disabled_jobs'] == 1
	assert stats['total_executions'] == 0
}

fn test_cron_scheduler_persistence() {
	tmp := cron_test_tmp_dir('cron_test_persist')
	defer { os.rmdir_all(tmp) or {} }

	// 第一个实例：写入数据
	mut sched1 := new_cron_scheduler(tmp, fn (job CronJob) ! {}) or {
		assert false, '创建调度器1失败'
		return
	}
	sched1.add_job('persist-job', '*/10 * * * *', 'echo persist') or {
		assert false, '添加任务失败'
	}

	// 第二个实例：从磁盘加载
	mut sched2 := new_cron_scheduler(tmp, fn (job CronJob) ! {}) or {
		assert false, '创建调度器2失败'
		return
	}
	jobs := sched2.list_jobs()
	assert jobs.len == 1, '持久化后重新加载应有 1 个任务'
	assert jobs[0].name == 'persist-job'
	assert jobs[0].schedule == '*/10 * * * *'
}

fn test_cron_scheduler_get_job() {
	tmp := cron_test_tmp_dir('cron_test_get')
	mut sched := new_cron_scheduler(tmp, fn (job CronJob) ! {}) or { return }
	defer { os.rmdir_all(tmp) or {} }

	job := sched.add_job('get-me', '0 9 * * 1', 'echo weekly') or { return }

	found := sched.get_job(job.id) or {
		assert false, 'get_job 应找到已添加的任务'
		return
	}
	assert found.name == 'get-me'

	_ := sched.get_job('nonexistent') or { return } // 找不到时应返回 none
}

fn test_cron_scheduler_start_stop() {
	tmp := cron_test_tmp_dir('cron_test_ss')
	mut sched := new_cron_scheduler(tmp, fn (job CronJob) ! {}) or { return }
	defer { os.rmdir_all(tmp) or {} }

	assert sched.running == false
	sched.start()
	assert sched.running == true
	sched.stop()
	assert sched.running == false
}

fn test_cron_scheduler_add_once_job_runs_once_and_disables() {
	tmp := cron_test_tmp_dir('cron_test_once')
	marker := os.join_path(tmp, 'once_marker.txt')
	mut sched := new_cron_scheduler(tmp, fn [marker] (job CronJob) ! {
		os.write_file(marker, job.name)!
	}) or { return }
	defer { os.rmdir_all(tmp) or {} }

	job := sched.add_once_job('once-job', time.now().unix() + 1, 'echo once') or {
		assert false, '添加一次性任务失败: ${err}'
		return
	}
	assert job.run_once
	assert job.enabled

	sched.start()
	time.sleep(1100 * time.millisecond)
	sched.tick() or {
		assert false, 'tick 执行失败: ${err}'
		return
	}

	updated := sched.get_job(job.id) or {
		assert false, '应能查询到一次性任务'
		return
	}
	assert os.read_file(marker) or { '' } == 'once-job'
	assert !updated.enabled
	assert updated.next_run == 0
	assert updated.execution_count == 1
	assert updated.last_run > 0
	assert updated.run_once
	assert updated.schedule.starts_with('@once ')

	sched.tick() or {
		assert false, '第二次 tick 执行失败: ${err}'
		return
	}
	assert os.read_file(marker) or { '' } == 'once-job'
	sched.stop()
}

fn test_cron_scheduler_add_once_job_in_past_fails() {
	tmp := cron_test_tmp_dir('cron_test_once_past')
	mut sched := new_cron_scheduler(tmp, fn (job CronJob) ! {}) or { return }
	defer { os.rmdir_all(tmp) or {} }

	sched.add_once_job('late-job', time.now().unix() - 1, 'echo nope') or { return }
	assert false, '过去时间的一次性任务应创建失败'
}

fn test_cron_scheduler_tick_when_not_running_does_nothing() {
	tmp := cron_test_tmp_dir('cron_test_idle_tick')
	marker := os.join_path(tmp, 'idle_marker.txt')
	mut sched := new_cron_scheduler(tmp, fn [marker] (job CronJob) ! {
		os.write_file(marker, job.name)!
	}) or { return }
	defer { os.rmdir_all(tmp) or {} }

	job := sched.add_once_job('idle-job', time.now().unix() + 1, 'echo idle') or { return }
	time.sleep(1100 * time.millisecond)
	sched.tick() or {
		assert false, '未启动调度器的 tick 不应报错: ${err}'
		return
	}

	assert !os.exists(marker), '调度器未启动时不应执行回调'
	updated := sched.get_job(job.id) or {
		assert false, '任务应仍然存在'
		return
	}
	assert updated.enabled, '未执行时任务仍应启用'
	assert updated.execution_count == 0, '未执行时计数应保持为 0'
}

fn test_cron_scheduler_tick_propagates_callback_error() {
	tmp := cron_test_tmp_dir('cron_test_tick_err')
	mut sched := new_cron_scheduler(tmp, fn (job CronJob) ! {
		return error('boom: ${job.name}')
	}) or { return }
	defer { os.rmdir_all(tmp) or {} }

	job := sched.add_once_job('bad-job', time.now().unix() + 1, 'echo bad') or { return }
	sched.start()
	time.sleep(1100 * time.millisecond)
	sched.tick() or {
		updated := sched.get_job(job.id) or {
			assert false, '错误后任务应仍可查询'
			return
		}
		assert updated.enabled, '回调失败时任务不应被标记为已完成'
		assert updated.execution_count == 0, '回调失败时执行次数不应递增'
		sched.stop()
		return
	}
	sched.stop()
	assert false, '回调失败时 tick 应返回错误'
}
