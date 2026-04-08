module main

import encoding.hex
import os
import strings
import time
import veb

pub struct CronDashboardContext {
	veb.Context
}

pub struct CronDashboardApp {
pub:
	db_path      string
	storage_path string
	port         int
	started_at   i64
}

struct CronDashboardJobView {
	job_id          string
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

struct CronDashboardExecutionView {
	id          int
	job_id      string
	job_name    string
	schedule    string
	command     string
	started_at  i64
	finished_at i64
	duration_ms i64
	exit_code   int
	output      string
	created_at  i64
}

struct CronDashboardSnapshot {
	generated_at      i64
	db_path           string
	storage_path      string
	total_jobs        int
	enabled_jobs      int
	disabled_jobs     int
	total_executions  int
	failed_executions int
	jobs              []CronDashboardJobView
	executions        []CronDashboardExecutionView
}

struct CronDashboardMetricView {
	title  string
	value  string
	note   string
	accent string
}

struct CronDashboardJobCardView {
	job_id              string
	name                string
	schedule            string
	command             string
	run_once            bool
	enabled             bool
	last_run            string
	next_run            string
	execution_count     int
	log_path            string
	status_label        string
	status_class        string
	type_label          string
	type_class          string
	has_latest          bool
	latest_status_label string
	latest_status_class string
	latest_exit_code    int
	latest_finished_at  string
	latest_duration_ms  i64
	latest_output       string
}

struct CronDashboardExecutionCardView {
	id           int
	job_name     string
	job_id       string
	schedule     string
	command      string
	started_at   string
	finished_at  string
	duration_ms  i64
	exit_code    int
	output       string
	has_output   bool
	status_label string
	status_class string
}

fn cron_dashboard_db_path() string {
	return os.join_path(cron_storage_path(), 'dashboard.sqlite')
}

fn hex_sql(value string) string {
	return sql_quote(hex.encode(value.bytes()))
}

fn decode_dashboard_text(raw string) string {
	if raw.len == 0 {
		return ''
	}
	return (hex.decode(raw) or { raw.bytes() }).bytestr()
}

fn html_escape(input string) string {
	if input.len == 0 {
		return ''
	}
	mut escaped := strings.new_builder(input.len + 16)
	for byte in input.bytes() {
		match byte {
			`&` { escaped.write_string('&amp;') }
			`<` { escaped.write_string('&lt;') }
			`>` { escaped.write_string('&gt;') }
			`"` { escaped.write_string('&quot;') }
			`'` { escaped.write_string('&#39;') }
			else { escaped.write_u8(byte) }
		}
	}
	return escaped.str()
}

fn bool_sql(value bool) string {
	return if value { '1' } else { '0' }
}

fn execution_status_label(exit_code int) string {
	return if exit_code == 0 { '成功' } else { '失败' }
}

fn execution_status_class(exit_code int) string {
	return if exit_code == 0 { 'success' } else { 'danger' }
}

fn latest_execution_for_job(executions []CronDashboardExecutionView, job_id string) ?CronDashboardExecutionView {
	for execution in executions {
		if execution.job_id == job_id {
			return execution
		}
	}
	return none
}

fn cron_dashboard_metric_views(snapshot CronDashboardSnapshot) []CronDashboardMetricView {
	return [
		CronDashboardMetricView{
			title:  '任务总数'
			value:  snapshot.total_jobs.str()
			note:   '运行中与已停用任务的总和'
			accent: 'accent'
		},
		CronDashboardMetricView{
			title:  '已启用'
			value:  snapshot.enabled_jobs.str()
			note:   '还能继续按计划触发的任务'
			accent: 'accent'
		},
		CronDashboardMetricView{
			title:  '执行记录'
			value:  snapshot.total_executions.str()
			note:   '最近 20 条执行历史'
			accent: 'accent'
		},
		CronDashboardMetricView{
			title:  '失败记录'
			value:  snapshot.failed_executions.str()
			note:   'exit code 非 0 的执行'
			accent: 'accent'
		},
	]
}

fn cron_dashboard_job_card_views(snapshot CronDashboardSnapshot) []CronDashboardJobCardView {
	mut views := []CronDashboardJobCardView{}
	for job in snapshot.jobs {
		latest := latest_execution_for_job(snapshot.executions, job.job_id)
		mut latest_status_label := ''
		mut latest_status_class := ''
		mut latest_exit_code := 0
		mut latest_finished_at := ''
		mut latest_duration_ms := i64(0)
		mut latest_output := ''
		mut has_latest := false
		if latest_execution := latest {
			has_latest = true
			latest_status_label = execution_status_label(latest_execution.exit_code)
			latest_status_class = execution_status_class(latest_execution.exit_code)
			latest_exit_code = latest_execution.exit_code
			latest_finished_at = format_cron_timestamp(latest_execution.finished_at)
			latest_duration_ms = latest_execution.duration_ms
			latest_output = utf8_safe_truncate(latest_execution.output.trim_space(), 240)
		}
		views << CronDashboardJobCardView{
			job_id:              job.job_id
			name:                job.name
			schedule:            job.schedule
			command:             utf8_safe_truncate(job.command, 220)
			run_once:            job.run_once
			enabled:             job.enabled
			last_run:            format_cron_timestamp(job.last_run)
			next_run:            format_cron_timestamp(job.next_run)
			execution_count:     job.execution_count
			log_path:            cron_job_log_path(job.job_id)
			status_label:        if job.enabled { 'enabled' } else { 'disabled' }
			status_class:        if job.enabled { 'success' } else { 'muted' }
			type_label:          if job.run_once { 'once' } else { 'cron' }
			type_class:          if job.run_once { 'info' } else { 'brand' }
			has_latest:          has_latest
			latest_status_label: latest_status_label
			latest_status_class: latest_status_class
			latest_exit_code:    latest_exit_code
			latest_finished_at:  latest_finished_at
			latest_duration_ms:  latest_duration_ms
			latest_output:       latest_output
		}
	}
	return views
}

fn cron_dashboard_execution_card_views(snapshot CronDashboardSnapshot) []CronDashboardExecutionCardView {
	mut views := []CronDashboardExecutionCardView{}
	for execution in snapshot.executions {
		output := utf8_safe_truncate(execution.output.trim_space(), 320)
		views << CronDashboardExecutionCardView{
			id:           execution.id
			job_name:     execution.job_name
			job_id:       execution.job_id
			schedule:     execution.schedule
			command:      execution.command
			started_at:   format_cron_timestamp(execution.started_at)
			finished_at:  format_cron_timestamp(execution.finished_at)
			duration_ms:  execution.duration_ms
			exit_code:    execution.exit_code
			output:       output
			has_output:   output.len > 0
			status_label: execution_status_label(execution.exit_code)
			status_class: execution_status_class(execution.exit_code)
		}
	}
	return views
}

fn ensure_cron_dashboard_db(db_path string) ! {
	statement := '
		CREATE TABLE IF NOT EXISTS cron_jobs (
			job_id TEXT PRIMARY KEY,
			name_hex TEXT NOT NULL,
			schedule_hex TEXT NOT NULL,
			command_hex TEXT NOT NULL,
			run_once INTEGER NOT NULL,
			enabled INTEGER NOT NULL,
			last_run INTEGER NOT NULL,
			next_run INTEGER NOT NULL,
			execution_count INTEGER NOT NULL,
			created_at INTEGER NOT NULL
		);
		CREATE TABLE IF NOT EXISTS cron_executions (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			job_id TEXT NOT NULL,
			job_name_hex TEXT NOT NULL,
			schedule_hex TEXT NOT NULL,
			command_hex TEXT NOT NULL,
			started_at INTEGER NOT NULL,
			finished_at INTEGER NOT NULL,
			duration_ms INTEGER NOT NULL,
			exit_code INTEGER NOT NULL,
			output_hex TEXT NOT NULL,
			created_at INTEGER NOT NULL
		);
		CREATE INDEX IF NOT EXISTS idx_cron_executions_job_id ON cron_executions(job_id);
		CREATE INDEX IF NOT EXISTS idx_cron_executions_started_at ON cron_executions(started_at DESC);
	'
	_ = sqlite_exec(db_path, statement)!
}

fn sync_cron_dashboard_jobs(scheduler CronScheduler) ! {
	db_path := cron_dashboard_db_path()
	ensure_cron_dashboard_db(db_path)!

	mut statements := []string{}
	statements << 'BEGIN;'
	statements << 'DELETE FROM cron_jobs;'
	for job in scheduler.list_jobs() {
		statements <<
			'INSERT INTO cron_jobs (job_id, name_hex, schedule_hex, command_hex, run_once, enabled, last_run, next_run, execution_count, created_at) VALUES (' +
			sql_quote(job.id) + ', ' + hex_sql(job.name) + ', ' + hex_sql(job.schedule) + ', ' +
			hex_sql(job.command) + ', ' + bool_sql(job.run_once) + ', ' + bool_sql(job.enabled) +
			', ' + job.last_run.str() + ', ' + job.next_run.str() + ', ' +
			job.execution_count.str() + ', ' + job.created_at.str() + ');'
	}
	statements << 'COMMIT;'
	_ = sqlite_exec(db_path, statements.join('\n'))!
}

fn record_cron_dashboard_execution(job CronJob, started_at time.Time, finished_at time.Time, exit_code int, output string) ! {
	db_path := cron_dashboard_db_path()
	ensure_cron_dashboard_db(db_path)!
	duration_ms := finished_at.unix_milli() - started_at.unix_milli()
	statement :=
		'INSERT INTO cron_executions (job_id, job_name_hex, schedule_hex, command_hex, started_at, finished_at, duration_ms, exit_code, output_hex, created_at) VALUES (' +
		sql_quote(job.id) + ', ' + hex_sql(job.name) + ', ' + hex_sql(job.schedule) + ', ' +
		hex_sql(job.command) + ', ' + started_at.unix().str() + ', ' + finished_at.unix().str() +
		', ' + duration_ms.str() + ', ' + exit_code.str() + ', ' + hex_sql(output) + ', ' +
		finished_at.unix().str() + ');'
	_ = sqlite_exec(db_path, statement)!
}

fn load_cron_dashboard_jobs(db_path string) ![]CronDashboardJobView {
	output := sqlite_exec(db_path, 'SELECT job_id, name_hex, schedule_hex, command_hex, run_once, enabled, last_run, next_run, execution_count, created_at FROM cron_jobs ORDER BY enabled DESC, next_run ASC, created_at DESC;')!
	mut jobs := []CronDashboardJobView{}
	for line in output.split_into_lines() {
		trimmed := line.trim_space()
		if trimmed.len == 0 {
			continue
		}
		cols := trimmed.split('|')
		if cols.len < 10 {
			continue
		}
		jobs << CronDashboardJobView{
			job_id:          cols[0]
			name:            decode_dashboard_text(cols[1])
			schedule:        decode_dashboard_text(cols[2])
			command:         decode_dashboard_text(cols[3])
			run_once:        cols[4].trim_space() == '1'
			enabled:         cols[5].trim_space() == '1'
			last_run:        cols[6].trim_space().int()
			next_run:        cols[7].trim_space().int()
			execution_count: cols[8].trim_space().int()
			created_at:      cols[9].trim_space().int()
		}
	}
	return jobs
}

fn load_cron_dashboard_executions(db_path string, limit int) ![]CronDashboardExecutionView {
	statement := 'SELECT id, job_id, job_name_hex, schedule_hex, command_hex, started_at, finished_at, duration_ms, exit_code, output_hex, created_at FROM cron_executions ORDER BY started_at DESC, id DESC LIMIT ${limit};'
	output := sqlite_exec(db_path, statement)!
	mut executions := []CronDashboardExecutionView{}
	for line in output.split_into_lines() {
		trimmed := line.trim_space()
		if trimmed.len == 0 {
			continue
		}
		cols := trimmed.split('|')
		if cols.len < 11 {
			continue
		}
		executions << CronDashboardExecutionView{
			id:          cols[0].trim_space().int()
			job_id:      cols[1]
			job_name:    decode_dashboard_text(cols[2])
			schedule:    decode_dashboard_text(cols[3])
			command:     decode_dashboard_text(cols[4])
			started_at:  cols[5].trim_space().int()
			finished_at: cols[6].trim_space().int()
			duration_ms: cols[7].trim_space().int()
			exit_code:   cols[8].trim_space().int()
			output:      decode_dashboard_text(cols[9])
			created_at:  cols[10].trim_space().int()
		}
	}
	return executions
}

fn load_cron_dashboard_snapshot(db_path string, storage_path string) !CronDashboardSnapshot {
	jobs := load_cron_dashboard_jobs(db_path)!
	executions := load_cron_dashboard_executions(db_path, 20)!
	mut enabled_jobs := 0
	mut failed_executions := 0
	for job in jobs {
		if job.enabled {
			enabled_jobs++
		}
	}
	for execution in executions {
		if execution.exit_code != 0 {
			failed_executions++
		}
	}
	return CronDashboardSnapshot{
		generated_at:      time.now().unix()
		db_path:           db_path
		storage_path:      storage_path
		total_jobs:        jobs.len
		enabled_jobs:      enabled_jobs
		disabled_jobs:     jobs.len - enabled_jobs
		total_executions:  executions.len
		failed_executions: failed_executions
		jobs:              jobs
		executions:        executions
	}
}

fn build_cron_dashboard_page(snapshot CronDashboardSnapshot, port int) string {
	metrics := cron_dashboard_metric_views(snapshot)
	job_cards := cron_dashboard_job_card_views(snapshot)
	execution_cards := cron_dashboard_execution_card_views(snapshot)
	mut body := strings.new_builder(65536)
	body.write_string('<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Cron Dashboard</title><style>body{margin:0;padding:32px;font-family:"SF Pro Display","PingFang SC","Hiragino Sans GB","Microsoft YaHei UI",sans-serif;background:#07111f;color:#edf4ff}main{max-width:1440px;margin:0 auto}section{margin:24px 0;padding:20px;border:1px solid rgba(148,163,184,.18);border-radius:24px;background:rgba(10,18,31,.88)}.metrics{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:12px}.card{border:1px solid rgba(148,163,184,.18);border-radius:20px;padding:16px;background:rgba(9,17,31,.96)}.badge{display:inline-block;padding:4px 8px;border-radius:999px;font-size:12px}.success{color:#46d39d}.danger{color:#ff7a7a}.muted{color:#9fb2cc}.output{white-space:pre-wrap;word-break:break-word;background:rgba(1,6,17,.54);padding:10px;border-radius:12px;border:1px solid rgba(148,163,184,.14)}</style></head><body><main>')
	body.write_string(
		'<section><p style="text-transform:uppercase;letter-spacing:.22em;color:#69d2ff;font-size:.74rem;margin:0 0 8px">MiniMax Cron Dashboard</p><h1 style="margin:0;font-size:clamp(2rem,4vw,4rem)">静态任务与执行视图</h1><p style="color:#9fb2cc">本地页面通过 veb 提供服务，数据从 SQLite 读取，cron 任务和最近执行结果会自动刷新。</p><p style="color:#9fb2cc">生成于 <code>' +
		html_escape(format_cron_timestamp(snapshot.generated_at)) +
		'</code></p><div class="metrics">')
	for metric in metrics {
		body.write_string('<div class="card"><div style="color:#9fb2cc;font-size:.85rem">' +
			html_escape(metric.title) + '</div><div style="font-size:1.75rem;font-weight:700">' +
			html_escape(metric.value) + '</div><div style="color:#9fb2cc;font-size:.82rem">' +
			html_escape(metric.note) + '</div></div>')
	}
	body.write_string('</div></section>')
	body.write_string(
		'<section><h2>Cron 任务</h2><div style="color:#9fb2cc">存储目录：<code>' +
		html_escape(snapshot.storage_path) + '</code> · SQLite：<code>' +
		html_escape(snapshot.db_path) + '</code> · 端口 <code>' + port.str() + '</code></div>')
	if job_cards.len == 0 {
		body.write_string('<div class="card muted">当前没有 Cron 任务。可以先运行 <code>minimax_cli cron add ...</code> 或 <code>minimax_cli cron delay ...</code> 创建任务。</div>')
	} else {
		body.write_string('<div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(320px,1fr));gap:16px;margin-top:16px">')
		for job in job_cards {
			body.write_string(
				'<article class="card"><div style="display:flex;justify-content:space-between;gap:12px"><div><h3 style="margin:0">' +
				html_escape(job.name) + '</h3><div>')
			body.write_string('<span class="badge ' + job.status_class + '">' +
				html_escape(job.status_label) + '</span> ')
			body.write_string('<span class="badge ' + job.type_class + '">' +
				html_escape(job.type_label) +
				'</span></div></div><div style="color:#9fb2cc;word-break:break-all;text-align:right">' +
				html_escape(job.job_id) + '</div></div>')
			body.write_string('<div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:0 16px;margin-top:16px">')
			body.write_string(
				'<div><div style="color:#9fb2cc;font-size:.76rem">计划</div><strong>' +
				html_escape(job.schedule) + '</strong></div>')
			body.write_string(
				'<div><div style="color:#9fb2cc;font-size:.76rem">命令</div><strong>' +
				html_escape(job.command) + '</strong></div>')
			body.write_string(
				'<div><div style="color:#9fb2cc;font-size:.76rem">下次执行</div><strong>' +
				html_escape(job.next_run) + '</strong></div>')
			body.write_string(
				'<div><div style="color:#9fb2cc;font-size:.76rem">上次执行</div><strong>' +
				html_escape(job.last_run) + '</strong></div>')
			body.write_string(
				'<div><div style="color:#9fb2cc;font-size:.76rem">执行次数</div><strong>' +
				job.execution_count.str() + '</strong></div>')
			body.write_string(
				'<div><div style="color:#9fb2cc;font-size:.76rem">日志</div><strong>' +
				html_escape(job.log_path) + '</strong></div>')
			body.write_string('</div>')
			if job.has_latest {
				body.write_string('<div class="card ' + job.latest_status_class +
					'" style="margin-top:16px"><div style="font-weight:700">最近执行 · ' +
					html_escape(job.latest_status_label) + ' · exit ' +
					job.latest_exit_code.str() +
					'</div><div style="color:#9fb2cc;font-size:.84rem">完成于 ' +
					html_escape(job.latest_finished_at) + ' · 用时 ' +
					job.latest_duration_ms.str() + ' ms</div>')
				if job.latest_output.len > 0 {
					body.write_string('<pre class="output">' + html_escape(job.latest_output) +
						'</pre>')
				} else {
					body.write_string('<div class="output muted">无输出</div>')
				}
				body.write_string('</div>')
			} else {
				body.write_string('<div class="card muted" style="margin-top:16px">最近执行：暂无执行记录</div>')
			}
			body.write_string('</article>')
		}
		body.write_string('</div>')
	}
	body.write_string('</section>')
	body.write_string('<section><h2>最近执行</h2><div style="color:#9fb2cc">按开始时间倒序展示，最多 20 条</div>')
	if execution_cards.len == 0 {
		body.write_string('<div class="card muted">当前还没有执行历史。Cron 任务首次运行后，这里会出现详细记录。</div>')
	} else {
		body.write_string('<div style="display:grid;gap:14px;margin-top:16px">')
		for execution in execution_cards {
			body.write_string(
				'<article class="card"><div style="display:flex;justify-content:space-between;gap:12px"><div><strong>' +
				html_escape(execution.job_name) + '</strong><div style="color:#9fb2cc">' +
				html_escape(execution.job_id) + ' · ' + html_escape(execution.started_at) +
				' → ' + html_escape(execution.finished_at) +
				'</div></div><div><span class="badge ' + execution.status_class + '">' +
				html_escape(execution.status_label) + '</span></div></div>')
			body.write_string('<div style="color:#9fb2cc;margin:12px 0 10px">' +
				html_escape(execution.schedule) + ' · ' + html_escape(execution.command) + ' · ' +
				execution.duration_ms.str() + ' ms</div>')
			if execution.has_output {
				body.write_string('<pre class="output">' + html_escape(execution.output) + '</pre>')
			} else {
				body.write_string('<div class="output muted">无输出</div>')
			}
			body.write_string('</article>')
		}
		body.write_string('</div>')
	}
	body.write_string('</section>')
	body.write_string(
		'<section><div style="color:#9fb2cc">页面由 <code>veb</code> 提供，数据由 <code>sqlite3</code> CLI 写入 <code>' +
		html_escape(snapshot.db_path) +
		'</code>。你可以用 <code>minimax_cli cron list</code>、<code>minimax_cli cron stats</code>、<code>minimax_cli cron tick</code> 和 <code>minimax_cli cron dashboard</code> 持续观察变化。</div></section>')
	body.write_string('</main></body></html>')
	return body.str()
}

fn build_cron_dashboard_error_page(error_message string, db_path string) string {
	mut body := strings.new_builder(4096)
	body.write_string(
		'<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><title>Cron Dashboard</title></head><body><main style="max-width:960px;margin:0 auto;padding:32px;font-family:sans-serif;background:#08111f;color:#eef4ff"><h1>Cron Dashboard 无法加载</h1><p>' +
		html_escape(error_message) +
		'</p><p>请确认 <code>sqlite3</code> 可用且数据库目录可写：<code>' +
		html_escape(db_path) + '</code></p></main></body></html>')
	return body.str()
}

fn start_cron_dashboard_server(port int) ! {
	mut scheduler := new_cli_cron_scheduler()!
	sync_cron_dashboard_jobs(scheduler)!
	mut app := &CronDashboardApp{
		db_path:      cron_dashboard_db_path()
		storage_path: cron_storage_path()
		port:         port
		started_at:   time.now().unix()
	}
	println('Cron dashboard 已启动: http://127.0.0.1:${port}/')
	println('SQLite 数据库: ${app.db_path}')
	veb.run_at[CronDashboardApp, CronDashboardContext](mut app,
		host:                 '127.0.0.1'
		family:               .ip
		port:                 port
		show_startup_message: false
	)!
}

pub fn (app &CronDashboardApp) index(mut ctx CronDashboardContext) veb.Result {
	snapshot := load_cron_dashboard_snapshot(app.db_path, app.storage_path) or {
		ctx.res.set_status(.internal_server_error)
		return ctx.html(build_cron_dashboard_error_page(err.msg(), app.db_path))
	}
	title := 'Cron Dashboard'
	subtitle := '本地页面通过 veb 提供服务，数据从 SQLite 读取，cron 任务和最近执行结果会自动刷新。'
	refresh_seconds := 15
	port := app.port
	storage_path := snapshot.storage_path
	db_path := snapshot.db_path
	metrics := cron_dashboard_metric_views(snapshot)
	job_cards := cron_dashboard_job_card_views(snapshot)
	execution_cards := cron_dashboard_execution_card_views(snapshot)
	has_jobs := job_cards.len > 0
	has_executions := execution_cards.len > 0
	job_empty_state := '当前没有 Cron 任务。可以先运行 minimax_cli cron add ... 或 minimax_cli cron delay ... 创建任务。'
	execution_empty_state := '当前还没有执行历史。Cron 任务首次运行后，这里会出现详细记录。'
	generated_at := format_cron_timestamp(snapshot.generated_at)
	return $veb.html('templates/cron_dashboard_page.html')
}

fn api_json_success(msg string) string {
	return '{"success":true,"message":"${msg}"}'
}

fn api_json_error(msg string) string {
	return '{"success":false,"error":"${msg}"}'
}

fn cron_dashboard_job_type_label(job CronJob) string {
	return if job.run_once { 'once' } else { 'cron' }
}

@['/api/jobs'; POST]
pub fn (app &CronDashboardApp) create_job(mut ctx CronDashboardContext) veb.Result {
	name := ctx.query['name'] or { '' }
	schedule := ctx.query['schedule'] or { '' }
	command := ctx.query['command'] or { '' }
	job_type := ctx.query['type'] or { 'cron' }
	delay_seconds := ctx.query['delay_seconds'] or { '0' }.int()

	if name == '' || schedule == '' || command == '' {
		ctx.res.header.set(.content_type, 'application/json')
		return ctx.text(api_json_error('name, schedule, command are required'))
	}

	mut scheduler := new_cli_cron_scheduler() or {
		ctx.res.header.set(.content_type, 'application/json')
		return ctx.text(api_json_error('Failed to create scheduler: ${err.msg}'))
	}

	if job_type == 'once' {
		if delay_seconds <= 0 {
			ctx.res.header.set(.content_type, 'application/json')
			return ctx.text(api_json_error('delay_seconds must be > 0'))
		}
		_ := scheduler.add_once_job(name, time.now().unix() + delay_seconds, command) or {
			ctx.res.header.set(.content_type, 'application/json')
			return ctx.text(api_json_error('Failed to create job: ${err.msg}'))
		}
	} else {
		_ := scheduler.add_job(name, schedule, command) or {
			ctx.res.header.set(.content_type, 'application/json')
			return ctx.text(api_json_error('Failed to create job: ${err.msg}'))
		}
	}

	sync_cron_dashboard_jobs(scheduler) or {}
	if should_auto_start_cron_daemon() && !is_daemon_running() {
		start_cron_daemon() or {}
	}

	ctx.res.header.set(.content_type, 'application/json')
	return ctx.text(api_json_success('Job created'))
}

@['/api/jobs/:id'; PUT]
fn update_job_impl(mut ctx CronDashboardContext, id string) veb.Result {
	mut scheduler := new_cli_cron_scheduler() or {
		ctx.res.header.set(.content_type, 'application/json')
		return ctx.text(api_json_error('Failed to create scheduler: ${err.msg}'))
	}

	mut clean_id := id
	if query_idx := clean_id.index('?') {
		clean_id = clean_id[..query_idx]
	}

	current := scheduler.get_job(clean_id) or {
		ctx.res.header.set(.content_type, 'application/json')
		return ctx.text(api_json_error('Job not found'))
	}

	name := ctx.query['name'] or { current.name }
	command := ctx.query['command'] or { current.command }
	job_type := ctx.query['type'] or { cron_dashboard_job_type_label(current) }
	schedule := ctx.query['schedule'] or { current.schedule }
	delay_seconds := ctx.query['delay_seconds'] or { default_once_delay_seconds(current).str() }

	updated := scheduler.update_job(clean_id, CronJobUpdateInput{
		name:          name
		schedule:      schedule
		command:       command
		run_once:      job_type == 'once'
		enabled:       current.enabled
		delay_seconds: delay_seconds.int()
	}) or {
		ctx.res.header.set(.content_type, 'application/json')
		return ctx.text(api_json_error('Failed to update job: ${err.msg}'))
	}

	sync_cron_dashboard_jobs(scheduler) or {}

	ctx.res.header.set(.content_type, 'application/json')
	return ctx.text('{"success":true,"message":"Job updated","job_id":"${updated.id}"}')
}

@['/api/jobs/update'; POST]
pub fn (app &CronDashboardApp) update_job(mut ctx CronDashboardContext) veb.Result {
	id := ctx.query['id'] or { '' }
	if id == '' {
		ctx.res.header.set(.content_type, 'application/json')
		return ctx.text(api_json_error('Job id is required'))
	}
	return update_job_impl(mut ctx, id)
}

@['/api/jobs/:id'; DELETE]
pub fn (app &CronDashboardApp) delete_job(mut ctx CronDashboardContext, id string) veb.Result {
	mut scheduler := new_cli_cron_scheduler() or {
		ctx.res.header.set(.content_type, 'application/json')
		return ctx.text(api_json_error('Failed to create scheduler'))
	}

	scheduler.delete_job(id) or {
		ctx.res.header.set(.content_type, 'application/json')
		return ctx.text(api_json_error('Failed to delete job: ${err.msg}'))
	}
	sync_cron_dashboard_jobs(scheduler) or {}

	ctx.res.header.set(.content_type, 'application/json')
	return ctx.text(api_json_success('Job deleted'))
}

@['/api/jobs/:id/toggle'; PUT]
pub fn (app &CronDashboardApp) toggle_job(mut ctx CronDashboardContext, id string) veb.Result {
	mut scheduler := new_cli_cron_scheduler() or {
		ctx.res.header.set(.content_type, 'application/json')
		return ctx.text(api_json_error('Failed'))
	}

	job := scheduler.get_job(id) or {
		ctx.res.header.set(.content_type, 'application/json')
		return ctx.text(api_json_error('Job not found'))
	}

	new_enabled := !job.enabled
	scheduler.set_job_enabled(id, new_enabled) or {
		ctx.res.header.set(.content_type, 'application/json')
		return ctx.text(api_json_error('Failed to toggle'))
	}
	sync_cron_dashboard_jobs(scheduler) or {}

	ctx.res.header.set(.content_type, 'application/json')
	return ctx.text('{"success":true,"message":"Toggled","enabled":${new_enabled}}')
}

@['/api/jobs/:id/run'; POST]
pub fn (app &CronDashboardApp) run_job(mut ctx CronDashboardContext, id string) veb.Result {
	mut scheduler := new_cli_cron_scheduler() or {
		ctx.res.header.set(.content_type, 'application/json')
		return ctx.text(api_json_error('Failed'))
	}

	job := scheduler.get_job(id) or {
		ctx.res.header.set(.content_type, 'application/json')
		return ctx.text(api_json_error('Job not found'))
	}

	execute_cron_job(job) or {
		ctx.res.header.set(.content_type, 'application/json')
		return ctx.text(api_json_error('Failed to run: ${err.msg}'))
	}

	record_cron_dashboard_execution(job, time.now(), time.now(), 0, '') or {}

	ctx.res.header.set(.content_type, 'application/json')
	return ctx.text(api_json_success('Job executed'))
}
