/**
 * cron.v - 定时任务调度系统
 *
 * 支持 Cron 表达式解析和后台任务执行。
 * - 标准 5 字段 Cron 表达式（分钟 小时 日期 月份 星期）
 * - 常用预设（@daily, @hourly, @weekly）
 * - 后台调度
 * - 任务持久化
 */
import json
import time
import os

pub struct CronJob {
pub mut:
	id              string
	name            string
	schedule        string // Cron 表达式
	command         string // 待执行的命令或函数引用
	run_once        bool
	enabled         bool
	last_run        i64
	next_run        i64
	execution_count int
	created_at      i64
}

pub struct CronScheduler {
pub mut:
	jobs         map[string]CronJob
	running      bool
	storage_path string
	callback     ?fn (job CronJob) ! // 执行回调
}

pub struct CronTime {
	minute  int
	hour    int
	day     int
	month   int
	weekday int
}

// 创建新的 Cron 调度器
pub fn new_cron_scheduler(storage_path string, callback fn (job CronJob) !) !CronScheduler {
	// 创建存储目录
	if !os.is_dir(storage_path) {
		os.mkdir_all(storage_path)!
	}

	mut scheduler := CronScheduler{
		jobs:         map[string]CronJob{}
		running:      false
		storage_path: storage_path
		callback:     callback
	}

	// 加载已有任务
	scheduler.load()!

	return scheduler
}

// 添加新的定时任务
pub fn (mut scheduler CronScheduler) add_job(name string, schedule string, command string) !CronJob {
	// 验证 Cron 表达式
	validate_cron_expression(schedule)!

	id := 'cron_${time.now().unix_milli()}'

	job := CronJob{
		id:              id
		name:            name
		schedule:        schedule
		command:         command
		run_once:        false
		enabled:         true
		last_run:        0
		next_run:        calculate_next_run(schedule)
		execution_count: 0
		created_at:      time.now().unix()
	}

	scheduler.jobs[id] = job
	scheduler.save()!

	return job
}

pub fn (mut scheduler CronScheduler) add_once_job(name string, run_at i64, command string) !CronJob {
	if run_at <= time.now().unix() {
		return error('一次性任务执行时间必须晚于当前时间')
	}

	id := 'cron_${time.now().unix_milli()}'
	job := CronJob{
		id:              id
		name:            name
		schedule:        '@once ${time.unix(run_at).utc_to_local().format_ss()}'
		command:         command
		run_once:        true
		enabled:         true
		last_run:        0
		next_run:        run_at
		execution_count: 0
		created_at:      time.now().unix()
	}

	scheduler.jobs[id] = job
	scheduler.save()!
	return job
}

// 启用/禁用任务
pub fn (mut scheduler CronScheduler) set_job_enabled(id string, enabled bool) ! {
	if id !in scheduler.jobs {
		return error('任务不存在')
	}

	mut job := scheduler.jobs[id]
	job.enabled = enabled
	scheduler.jobs[id] = job
	scheduler.save()!
}

// 删除任务
pub fn (mut scheduler CronScheduler) delete_job(id string) ! {
	if id !in scheduler.jobs {
		return error('任务不存在')
	}

	scheduler.jobs.delete(id)
	scheduler.save()!
}

// 启动调度器（后台运行）
pub fn (mut scheduler CronScheduler) start() {
	scheduler.running = true
	eprintln('Cron 调度器已启动')
}

// 停止调度器
pub fn (mut scheduler CronScheduler) stop() {
	scheduler.running = false
}

// 执行一次检查（用于主循环定期调用）
pub fn (mut scheduler CronScheduler) tick() ! {
	if !scheduler.running {
		return
	}

	now := time.now().unix()

	for id, mut job in scheduler.jobs {
		if !job.enabled {
			continue
		}

		if now >= job.next_run {
			// 执行任务
			if cb := scheduler.callback {
				cb(job)!
			}

			// 更新任务记录
			job.last_run = now
			job.execution_count++
			if job.run_once {
				job.enabled = false
				job.next_run = 0
			} else {
				job.next_run = calculate_next_run(job.schedule)
			}
			scheduler.jobs[id] = job

			scheduler.save()!
		}
	}
}

// 列出所有任务
pub fn (scheduler CronScheduler) list_jobs() []CronJob {
	mut jobs := []CronJob{}
	for _, job in scheduler.jobs {
		jobs << job
	}
	return jobs
}

// 获取任务详情
pub fn (scheduler CronScheduler) get_job(id string) ?CronJob {
	return scheduler.jobs[id] or { none }
}

// 保存任务到磁盘
pub fn (scheduler CronScheduler) save() ! {
	mut job_list := []CronJob{}
	for _, job in scheduler.jobs {
		job_list << job
	}

	data := json.encode(job_list)
	file_path := os.join_path(scheduler.storage_path, 'cron_jobs.json')
	os.write_file(file_path, data)!
}

// 从磁盘加载任务
pub fn (mut scheduler CronScheduler) load() ! {
	file_path := os.join_path(scheduler.storage_path, 'cron_jobs.json')

	if !os.exists(file_path) {
		return
	}

	content := os.read_file(file_path)!
	jobs := json.decode([]CronJob, content) or { return }

	for job in jobs {
		scheduler.jobs[job.id] = job
	}
}

// 验证 Cron 表达式
pub fn validate_cron_expression(expr string) ! {
	// 处理预设
	preset_expr := normalize_cron_preset(expr)

	parts := preset_expr.split(' ')
	if parts.len != 5 {
		return error('Cron 表达式必须有 5 个字段（分钟 小时 日期 月份 星期）')
	}

	// 验证每个字段
	validate_cron_field(parts[0], 0, 59)! // 分钟
	validate_cron_field(parts[1], 0, 23)! // 小时
	validate_cron_field(parts[2], 1, 31)! // 日期
	validate_cron_field(parts[3], 1, 12)! // 月份
	validate_cron_field(parts[4], 0, 6)! // 星期（0=周日）
}

// 验证单个字段
fn validate_cron_field(field string, min int, max int) ! {
	if field == '*' {
		return
	}

	if field.contains('-') {
		// 范围表达式
		parts := field.split('-')
		if parts.len != 2 {
			return error('无效的范围表达式: ${field}')
		}

		start := parts[0].int()
		end := parts[1].int()
		if start == 0 && parts[0] != '0' {
			return error('无效的数字: ${parts[0]}')
		}
		if end == 0 && parts[1] != '0' {
			return error('无效的数字: ${parts[1]}')
		}

		if start < min || start > max || end < min || end > max || start > end {
			return error('范围 ${field} 超出有效范围 [${min}, ${max}]')
		}
	} else if field.contains(',') {
		// 列表表达式
		for item in field.split(',') {
			val := item.int()
			if val == 0 && item.trim_space() != '0' {
				return error('无效的数字: ${item}')
			}
			if val < min || val > max {
				return error('值 ${val} 超出有效范围 [${min}, ${max}]')
			}
		}
	} else if field.contains('/') {
		// 步长表达式
		parts := field.split('/')
		if parts.len != 2 {
			return error('无效的步长表达式: ${field}')
		}

		step := parts[1].int()
		if step == 0 && parts[1] != '0' {
			return error('无效的步长值: ${parts[1]}')
		}

		if step <= 0 {
			return error('步长必须大于 0')
		}
	} else {
		// 单个值
		val := field.int()
		if val == 0 && field != '0' {
			return error('无效的数字: ${field}')
		}

		if val < min || val > max {
			return error('值 ${val} 超出有效范围 [${min}, ${max}]')
		}
	}
}

// 标准化 Cron 预设
fn normalize_cron_preset(expr string) string {
	match expr {
		'@yearly' { return '0 0 1 1 *' }
		'@annually' { return '0 0 1 1 *' }
		'@monthly' { return '0 0 1 * *' }
		'@weekly' { return '0 0 * * 0' }
		'@daily' { return '0 0 * * *' }
		'@midnight' { return '0 0 * * *' }
		'@hourly' { return '0 * * * *' }
		'@every-30m' { return '*/30 * * * *' }
		else { return expr }
	}
}

// 计算下一次运行时间
pub fn calculate_next_run(schedule string) i64 {
	preset_expr := normalize_cron_preset(schedule)
	parts := preset_expr.split(' ')

	if parts.len != 5 {
		// 无效表达式，返回 1 小时后
		return time.now().unix() + 3600
	}

	now := time.now()
	mut candidate_unix := now.unix() - i64(now.second) + 60
	for _ in 0 .. 366 * 24 * 60 {
		candidate := time.unix(candidate_unix).utc_to_local()
		if matches_cron_time(candidate, schedule) {
			return candidate_unix
		}
		candidate_unix += 60
	}

	return time.now().unix() + 3600
}

// 检查时间是否匹配 Cron 表达式
pub fn matches_cron_time(t time.Time, schedule string) bool {
	preset_expr := normalize_cron_preset(schedule)
	parts := preset_expr.split(' ')

	if parts.len != 5 {
		return false
	}

	// 提取时间分量
	minute := t.minute
	hour := t.hour
	day := t.day
	month := t.month

	// 简化检查（完整实现应该处理范围、列表、步长等）
	// 这里只演示基本逻辑

	if !field_matches(parts[0], minute) {
		return false
	}
	if !field_matches(parts[1], hour) {
		return false
	}
	if !field_matches(parts[2], day) {
		return false
	}
	if !field_matches(parts[3], month) {
		return false
	}
	weekday := if t.day_of_week() == 7 { 0 } else { t.day_of_week() }
	if !field_matches(parts[4], weekday) {
		return false
	}

	return true
}

// 检查字段是否匹配
fn field_matches(field string, value int) bool {
	trimmed := field.trim_space()
	if trimmed.len == 0 {
		return false
	}
	if trimmed == '*' || trimmed == '?' {
		return true
	}

	if trimmed.contains(',') {
		for item in trimmed.split(',') {
			if field_matches(item, value) {
				return true
			}
		}
		return false
	}

	if trimmed.contains('/') {
		parts := trimmed.split('/')
		if parts.len != 2 {
			return false
		}
		base := parts[0].trim_space()
		step := parts[1].trim_space().int()
		if step <= 0 {
			return false
		}
		if base == '*' || base == '?' || base.len == 0 {
			return value % step == 0
		}
		if base.contains('-') {
			range_parts := base.split('-')
			if range_parts.len != 2 {
				return false
			}
			start := range_parts[0].trim_space().int()
			end := range_parts[1].trim_space().int()
			if value < start || value > end {
				return false
			}
			return (value - start) % step == 0
		}
		start := base.int()
		return value >= start && (value - start) % step == 0
	}

	if trimmed.contains('-') {
		parts := trimmed.split('-')
		if parts.len != 2 {
			return false
		}
		start := parts[0].trim_space().int()
		end := parts[1].trim_space().int()
		return value >= start && value <= end
	}

	val := trimmed.int()
	if val == value {
		return true
	}

	return false
}

// 获取任务统计
pub fn (scheduler CronScheduler) get_stats() map[string]int {
	mut enabled := 0
	mut disabled := 0
	mut total_executions := 0

	for _, job in scheduler.jobs {
		if job.enabled {
			enabled++
		} else {
			disabled++
		}
		total_executions += job.execution_count
	}

	return {
		'total_jobs':       scheduler.jobs.len
		'enabled_jobs':     enabled
		'disabled_jobs':    disabled
		'total_executions': total_executions
	}
}
