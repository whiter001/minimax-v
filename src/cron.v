/**
 * cron.v - 最小化定时任务调度系统
 *
 * 支持 Cron 表达式解析和任务执行。
 * - 标准 5 字段 Cron 表达式（分钟 小时 日期 月份 星期）
 * - 常用预设（@daily, @hourly, @weekly）
 * - 任务持久化到 ~/.config/minimax/cron_jobs.json
 */
import json
import time
import os

pub struct CronJob {
pub mut:
	id              string
	name            string
	schedule        string
	command         string
	run_once        bool
	enabled         bool
	last_run        i64
	next_run        i64
	execution_count int
	created_at      i64
}

// CronService 替代全局变量 g_timer_manager
pub struct CronService {
mut:
	jobs         map[string]CronJob
	running      bool
	storage_path string
}

// 获取默认存储路径
fn default_storage_path() string {
	return os.join_path(get_minimax_config_dir(), 'cron_jobs.json')
}

// 创建新的 CronService
pub fn new_cron_service() !CronService {
	storage_path := default_storage_path()
	dir := os.dir(storage_path)
	if !os.is_dir(dir) {
		os.mkdir_all(dir)!
	}

	mut svc := CronService{
		jobs:         map[string]CronJob{}
		running:      false
		storage_path: storage_path
	}
	svc.load()!
	return svc
}

// 添加定时任务
pub fn (mut svc CronService) add_job(name string, schedule string, command string) !CronJob {
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

	svc.jobs[id] = job
	svc.save()!
	return job
}

// 删除定时任务
pub fn (mut svc CronService) delete_job(id string) ! {
	if id !in svc.jobs {
		return error('任务不存在: ${id}')
	}
	svc.jobs.delete(id)
	svc.save()!
}

// 启动调度器
pub fn (mut svc CronService) start() {
	svc.running = true
}

// 停止调度器
pub fn (mut svc CronService) stop() {
	svc.running = false
}

// 执行一次检查（主循环定期调用）
pub fn (mut svc CronService) tick(callback fn (CronJob) !) ! {
	if !svc.running {
		return
	}

	now := time.now().unix()

	for id, mut job in svc.jobs {
		if !job.enabled {
			continue
		}

		if now >= job.next_run {
			callback(job)!

			job.last_run = now
			job.execution_count++
			if job.run_once {
				job.enabled = false
				job.next_run = 0
			} else {
				job.next_run = calculate_next_run(job.schedule)
			}
			svc.jobs[id] = job
			svc.save()!
		}
	}
}

// 列出所有任务
pub fn (svc CronService) list_jobs() []CronJob {
	mut result := []CronJob{}
	for _, job in svc.jobs {
		result << job
	}
	return result
}

// 保存任务到磁盘
fn (svc CronService) save() ! {
	mut list := []CronJob{}
	for _, job in svc.jobs {
		list << job
	}
	os.write_file(svc.storage_path, json.encode(list))!
}

// 从磁盘加载任务
fn (mut svc CronService) load() ! {
	if !os.exists(svc.storage_path) {
		return
	}
	content := os.read_file(svc.storage_path) or { return }
	list := json.decode([]CronJob, content) or { return }
	for job in list {
		svc.jobs[job.id] = job
	}
}

// 验证 Cron 表达式
pub fn validate_cron_expression(expr string) ! {
	parts := normalize_preset(expr).split(' ')
	if parts.len != 5 {
		return error('Cron 表达式必须有 5 个字段')
	}
	validate_field(parts[0], 0, 59)! // 分钟
	validate_field(parts[1], 0, 23)! // 小时
	validate_field(parts[2], 1, 31)! // 日期
	validate_field(parts[3], 1, 12)! // 月份
	validate_field(parts[4], 0, 6)! // 星期
}

fn validate_field(field string, min int, max int) ! {
	if field == '*' {
		return
	}
	if field.contains('-') {
		parts := field.split('-')
		if parts.len != 2 {
			return error('无效范围: ${field}')
		}
		start := parts[0].int()
		end := parts[1].int()
		if start < min || end > max || start > end {
			return error('范围超出: ${field}')
		}
	} else if field.contains(',') {
		for item in field.split(',') {
			val := item.int()
			if val < min || val > max {
				return error('值超出范围: ${item}')
			}
		}
	} else if field.contains('/') {
		parts := field.split('/')
		if parts.len != 2 {
			return error('无效步长: ${field}')
		}
		step := parts[1].int()
		if step <= 0 {
			return error('步长必须大于 0')
		}
	} else {
		val := field.int()
		if val < min || val > max {
			return error('值超出范围: ${field}')
		}
	}
}

// 标准化预设表达式
fn normalize_preset(expr string) string {
	match expr {
		'@yearly', '@annually' { return '0 0 1 1 *' }
		'@monthly' { return '0 0 1 * *' }
		'@weekly' { return '0 0 * * 0' }
		'@daily', '@midnight' { return '0 0 * * *' }
		'@hourly' { return '0 * * * *' }
		'@every-30m' { return '*/30 * * * *' }
		'@every-15m' { return '*/15 * * * *' }
		'@every-5m' { return '*/5 * * * *' }
		else { return expr }
	}
}

// 计算下一次运行时间
fn calculate_next_run(schedule string) i64 {
	parts := normalize_preset(schedule).split(' ')
	if parts.len != 5 {
		return time.now().unix() + 3600
	}

	now := time.now()
	mut candidate := now.unix() - i64(now.second) + 60

	for _ in 0 .. 366 * 24 * 60 {
		t := time.unix(candidate).utc_to_local()
		if matches_time(t, schedule) {
			return candidate
		}
		candidate += 60
	}
	return time.now().unix() + 3600
}

// 检查时间是否匹配 Cron 表达式
fn matches_time(t time.Time, schedule string) bool {
	parts := normalize_preset(schedule).split(' ')
	if parts.len != 5 {
		return false
	}

	minute := t.minute
	hour := t.hour
	day := t.day
	month := t.month
	weekday := if t.day_of_week() == 7 { 0 } else { t.day_of_week() }

	return field_match(parts[0], minute) && field_match(parts[1], hour)
		&& field_match(parts[2], day) && field_match(parts[3], month)
		&& field_match(parts[4], weekday)
}

fn field_match(field string, value int) bool {
	trimmed := field.trim_space()
	if trimmed == '*' || trimmed == '?' {
		return true
	}
	if trimmed.contains(',') {
		for item in trimmed.split(',') {
			if field_match(item, value) {
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
		step := parts[1].trim_space().int()
		if step <= 0 {
			return false
		}
		base := parts[0].trim_space()
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
			return value >= start && value <= end && (value - start) % step == 0
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
	return trimmed.int() == value
}
