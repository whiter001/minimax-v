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
import rand
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
	jobs               map[string]CronJob
	running            bool
	storage_path       string
	callback           ?fn (job CronJob) ! // 执行回调
	daemon_start_mtime int                 // daemon 启动时的二进制 mtime，用于检测 rebuild
}

struct CronJobUpdateInput {
	name          string
	schedule      string
	command       string
	run_once      bool
	enabled       bool
	delay_seconds int
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
		jobs:               map[string]CronJob{}
		running:            false
		storage_path:       storage_path
		callback:           callback
		daemon_start_mtime: 0
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

// 更新任务
pub fn (mut scheduler CronScheduler) update_job(id string, input CronJobUpdateInput) !CronJob {
	if id !in scheduler.jobs {
		return error('任务不存在')
	}

	name := input.name.trim_space()
	if name.len == 0 {
		return error('任务名称不能为空')
	}

	command := input.command.trim_space()
	if command.len == 0 {
		return error('任务命令不能为空')
	}

	mut job := scheduler.jobs[id]
	job.name = name
	job.command = command
	job.enabled = input.enabled

	if input.run_once {
		if input.delay_seconds <= 0 {
			return error('一次性任务的延迟秒数必须大于 0')
		}
		next_run := time.now().unix() + i64(input.delay_seconds)
		job.run_once = true
		job.schedule = '@once ${time.unix(next_run).utc_to_local().format_ss()}'
		job.next_run = next_run
	} else {
		validate_cron_expression(input.schedule)!
		job.run_once = false
		job.schedule = input.schedule.trim_space()
		job.next_run = calculate_next_run(job.schedule)
	}

	scheduler.jobs[id] = job
	scheduler.save()!
	return job
}

fn default_once_delay_seconds(job CronJob) int {
	remaining := job.next_run - time.now().unix()
	if remaining <= 0 {
		return 1
	}
	return int(remaining)
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
	sync_cron_dashboard_jobs(scheduler) or {}
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

// ──────────────────────────────────────────────
// 可取消的定时器（类似 JS setTimeout/setInterval）
// ──────────────────────────────────────────────

// Timer 类型：timeout（一次）还是 interval（重复）
pub enum TimerType {
	timeout  // setTimeout，一次性
	interval // setInterval，重复执行
}

pub struct Timer {
pub mut:
	id           string // 唯一标识符
	name         string // 可读名称，用于取消
	timer_type   TimerType
	interval_sec i64    // 间隔秒数（timeout 为 0）
	next_run     i64    // 下次执行时间戳
	command      string // 待执行的命令
	enabled      bool   // 是否启用
	created_at   i64    // 创建时间
}

// Timer 管理器
// NOTE: TimerManager is not thread-safe. All operations must happen on a single
// thread. If concurrent access is needed in the future, add a sync.Mutex or use
// channel-based communication.
pub struct TimerManager {
pub mut:
	timers map[string]Timer
}

// 生成唯一 timer ID，使用 rand.uuid_v4() 确保全局唯一
fn new_timer_id() string {
	return 'timer_${rand.uuid_v4()}'
}

// 创建新的 Timer 管理器
pub fn new_timer_manager() TimerManager {
	return TimerManager{
		timers: map[string]Timer{}
	}
}

// 添加一个一次性定时器（类似 setTimeout）
pub fn (mut mgr TimerManager) set_timeout(name string, delay_seconds int, command string) !Timer {
	if delay_seconds <= 0 {
		return error('delay 秒数必须大于 0')
	}
	id := new_timer_id()
	timer := Timer{
		id:           id
		name:         name
		timer_type:   .timeout
		interval_sec: 0
		next_run:     time.now().unix() + delay_seconds
		command:      command
		enabled:      true
		created_at:   time.now().unix()
	}
	mgr.timers[id] = timer
	return timer
}

// 添加一个重复定时器（类似 setInterval）
pub fn (mut mgr TimerManager) set_interval(name string, interval_seconds int, command string) !Timer {
	if interval_seconds <= 0 {
		return error('interval 秒数必须大于 0')
	}
	id := new_timer_id()
	timer := Timer{
		id:           id
		name:         name
		timer_type:   .interval
		interval_sec: interval_seconds
		next_run:     time.now().unix() + interval_seconds
		command:      command
		enabled:      true
		created_at:   time.now().unix()
	}
	mgr.timers[id] = timer
	return timer
}

// 清除所有定时器（测试/重置用）
pub fn (mut mgr TimerManager) clear_all() {
	mgr.timers.clear()
}

// 按 ID 取消定时器
pub fn (mut mgr TimerManager) clear_timer(id string) bool {
	if id in mgr.timers {
		mgr.timers.delete(id)
		return true
	}
	return false
}

// 按名称取消定时器（取消所有同名定时器）
// 先收集后删除，避免遍历 map 时直接修改导致不稳定行为。
pub fn (mut mgr TimerManager) clear_timer_by_name(name string) int {
	mut to_remove := []string{}
	for id, timer in mgr.timers {
		if timer.name == name {
			to_remove << id
		}
	}
	for id in to_remove {
		mgr.timers.delete(id)
	}
	return to_remove.len
}

// 检查并执行到期的定时器，返回 (执行的ID列表, 是否有失败)
// 先收集待修改项，再统一应用，避免遍历 map 时直接修改导致不稳定行为。
pub fn (mut mgr TimerManager) tick_execute(execute_fn fn (Timer) !) ([]string, bool) {
	now := time.now().unix()
	mut executed := []string{}
	mut to_delete := []string{}
	mut to_update := []Timer{}
	mut any_failed := false

	for id, timer in mgr.timers {
		if !timer.enabled {
			continue
		}

		if now >= timer.next_run {
			execute_fn(timer) or {
				eprintln('Timer ${timer.id} 执行失败: ${err}')
				any_failed = true
			}

			if timer.timer_type == .timeout {
				// timeout 类型无论成功失败都只执行一次
				to_delete << id
			} else {
				// interval 类型无论成功失败都推进下次执行，避免失败时无限重试
				mut updated_timer := timer
				updated_timer.next_run = now + timer.interval_sec
				to_update << updated_timer
			}
			executed << id
		}
	}

	for id in to_delete {
		mgr.timers.delete(id)
	}
	for timer in to_update {
		mgr.timers[timer.id] = timer
	}

	return executed, any_failed
}

// 列出所有定时器
pub fn (mgr TimerManager) list_timers() []Timer {
	mut result := []Timer{}
	for _, timer in mgr.timers {
		result << timer
	}
	return result
}

// 获取单个定时器
pub fn (mgr TimerManager) get_timer(id string) ?Timer {
	return mgr.timers[id]
}

// 启用/禁用定时器
pub fn (mut mgr TimerManager) set_timer_enabled(id string, enabled bool) ! {
	if id !in mgr.timers {
		return error('定时器不存在')
	}
	mgr.timers[id].enabled = enabled
}

// 获取定时器统计
pub fn (mgr TimerManager) get_timer_stats() map[string]int {
	mut enabled := 0
	mut disabled := 0
	mut timeouts := 0
	mut intervals := 0

	for _, timer in mgr.timers {
		if timer.enabled {
			enabled++
		} else {
			disabled++
		}
		match timer.timer_type {
			.timeout { timeouts++ }
			.interval { intervals++ }
		}
	}

	return {
		'total_timers': mgr.timers.len
		'enabled':      enabled
		'disabled':     disabled
		'timeouts':     timeouts
		'intervals':    intervals
	}
}
