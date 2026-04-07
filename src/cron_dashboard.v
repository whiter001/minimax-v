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

fn dashboard_badge_html(label string, class_name string) string {
	return '<span class="badge ${class_name}">${html_escape(label)}</span>'
}

fn dashboard_metric_card_html(title string, value string, note string, accent string) string {
	return '<article class="metric-card ${accent}"><div class="metric-title">${html_escape(title)}</div><div class="metric-value">${html_escape(value)}</div><div class="metric-note">${html_escape(note)}</div></article>'
}

fn dashboard_job_card_html(job CronDashboardJobView, latest_execution CronDashboardExecutionView, has_latest bool) string {
	status_label := if job.enabled { 'enabled' } else { 'disabled' }
	status_class := if job.enabled { 'success' } else { 'muted' }
	type_label := if job.run_once { 'once' } else { 'cron' }
	type_class := if job.run_once { 'info' } else { 'brand' }
	mut latest_html := ''
	if has_latest {
		latest_html = '<div class="job-latest ${execution_status_class(latest_execution.exit_code)}"><div class="job-latest-title">最近执行 · ${html_escape(execution_status_label(latest_execution.exit_code))} · exit ${latest_execution.exit_code}</div><div class="job-latest-meta">完成于 ${html_escape(format_cron_timestamp(latest_execution.finished_at))} · 用时 ${latest_execution.duration_ms}ms</div><pre class="job-output">${html_escape(utf8_safe_truncate(latest_execution.output.trim_space(),
			240))}</pre></div>'
	} else {
		latest_html = '<div class="job-latest muted"><div class="job-latest-title">最近执行</div><div class="job-latest-meta">暂无执行记录</div></div>'
	}
	return '<article class="job-card"><div class="job-card-head"><div><h3>${html_escape(job.name)}</h3><div class="badge-row">${dashboard_badge_html(status_label,
		status_class)}${dashboard_badge_html(type_label, type_class)}</div></div><div class="job-id">${html_escape(job.job_id)}</div></div><div class="job-grid"><div class="job-field"><span>计划</span><strong>${html_escape(job.schedule)}</strong></div><div class="job-field"><span>命令</span><strong>${html_escape(utf8_safe_truncate(job.command,
		220))}</strong></div><div class="job-field"><span>下次执行</span><strong>${html_escape(format_cron_timestamp(job.next_run))}</strong></div><div class="job-field"><span>上次执行</span><strong>${html_escape(format_cron_timestamp(job.last_run))}</strong></div><div class="job-field"><span>执行次数</span><strong>${job.execution_count}</strong></div><div class="job-field"><span>日志</span><strong>${html_escape(cron_job_log_path(job.job_id))}</strong></div></div>${latest_html}</article>'
}

fn dashboard_execution_card_html(execution CronDashboardExecutionView) string {
	status_label := execution_status_label(execution.exit_code)
	status_class := execution_status_class(execution.exit_code)
	output := utf8_safe_truncate(execution.output.trim_space(), 320)
	output_html := if output.len > 0 {
		'<pre class="job-output">${html_escape(output)}</pre>'
	} else {
		'<div class="job-output muted">无输出</div>'
	}
	return '<article class="execution-card"><div class="execution-head"><div><strong>${html_escape(execution.job_name)}</strong><div class="execution-meta">${html_escape(execution.job_id)} · ${html_escape(format_cron_timestamp(execution.started_at))} → ${html_escape(format_cron_timestamp(execution.finished_at))}</div></div><div class="badge-row">${dashboard_badge_html(status_label,
		status_class)}</div></div><div class="execution-stats">${html_escape(execution.schedule)} · ${html_escape(execution.command)} · ${execution.duration_ms}ms</div>${output_html}</article>'
}

fn build_cron_dashboard_page(snapshot CronDashboardSnapshot, port int) string {
	mut body := strings.new_builder(65536)
	body.write_string('<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta http-equiv="refresh" content="15"><title>Cron Dashboard</title><style>')
	body.write_string(':root{--bg:#07111f;--bg2:#0d1930;--panel:rgba(11,20,36,.84);--panel-strong:rgba(9,17,31,.96);--border:rgba(148,163,184,.18);--text:#edf4ff;--muted:#9fb2cc;--accent:#69d2ff;--good:#46d39d;--bad:#ff7a7a;--info:#7aa7ff;--warn:#ffcb6b;--shadow:0 24px 90px rgba(1,6,17,.45);font-synthesis:none}*{box-sizing:border-box}html,body{min-height:100%}body{margin:0;color:var(--text);font-family:"SF Pro Display","PingFang SC","Hiragino Sans GB","Microsoft YaHei UI","Segoe UI",sans-serif;background:radial-gradient(circle at top left,rgba(105,210,255,.22),transparent 28%),radial-gradient(circle at 86% 8%,rgba(70,211,157,.18),transparent 24%),linear-gradient(160deg,var(--bg) 0%,#0a1324 42%,#050812 100%)}body:before{content:"";position:fixed;inset:0;background-image:linear-gradient(rgba(255,255,255,.028) 1px,transparent 1px),linear-gradient(90deg,rgba(255,255,255,.028) 1px,transparent 1px);background-size:48px 48px;mask-image:linear-gradient(180deg,rgba(0,0,0,.95),transparent 85%);pointer-events:none}.shell{max-width:1400px;margin:0 auto;padding:32px 22px 56px;position:relative;z-index:1}.hero{display:flex;flex-wrap:wrap;gap:24px;align-items:flex-start;justify-content:space-between;padding:30px 32px;border:1px solid var(--border);border-radius:28px;background:linear-gradient(180deg,rgba(14,26,46,.94),rgba(8,14,27,.86));box-shadow:var(--shadow);backdrop-filter:blur(18px)}.eyebrow{text-transform:uppercase;letter-spacing:.22em;font-size:.74rem;color:var(--accent);margin:0 0 8px}.hero h1{margin:0;font-size:clamp(2.2rem,4vw,4.2rem);line-height:1.02}.hero p{margin:12px 0 0;color:var(--muted);max-width:64ch;line-height:1.65}.hero-meta{display:grid;grid-template-columns:repeat(2,minmax(160px,1fr));gap:12px;min-width:min(100%,420px)}.metric-card{padding:18px 18px 16px;border-radius:22px;background:var(--panel);border:1px solid var(--border);box-shadow:0 12px 30px rgba(1,6,16,.22)}.metric-card.accent{background:linear-gradient(180deg,rgba(20,34,60,.96),rgba(12,20,37,.96))}.metric-title{color:var(--muted);font-size:.85rem;margin-bottom:10px}.metric-value{font-size:1.85rem;font-weight:700;letter-spacing:-.03em}.metric-note{margin-top:8px;color:var(--muted);font-size:.82rem;line-height:1.5}.section{margin-top:26px;padding:24px;border-radius:28px;border:1px solid var(--border);background:linear-gradient(180deg,rgba(10,18,31,.88),rgba(8,13,24,.76));box-shadow:var(--shadow)}.section-head{display:flex;flex-wrap:wrap;justify-content:space-between;gap:12px;align-items:end;margin-bottom:18px}.section-head h2{margin:0;font-size:1.35rem}.section-head .section-note{color:var(--muted);font-size:.88rem}.job-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(320px,1fr));gap:16px}.job-card,.execution-card{border:1px solid var(--border);border-radius:24px;background:var(--panel-strong);padding:18px;box-shadow:0 10px 26px rgba(0,0,0,.22)}.job-card-head,.execution-head{display:flex;justify-content:space-between;gap:16px;align-items:flex-start}.job-card h3{margin:0;font-size:1.2rem}.job-id{color:var(--muted);font-size:.8rem;word-break:break-all;text-align:right}.badge-row{display:flex;flex-wrap:wrap;gap:8px;margin-top:10px}.badge{display:inline-flex;align-items:center;padding:6px 10px;border-radius:999px;font-size:.74rem;font-weight:700;letter-spacing:.02em;text-transform:uppercase}.badge.success{background:rgba(70,211,157,.14);color:var(--good);border:1px solid rgba(70,211,157,.28)}.badge.danger{background:rgba(255,122,122,.14);color:var(--bad);border:1px solid rgba(255,122,122,.28)}.badge.info{background:rgba(122,167,255,.14);color:var(--info);border:1px solid rgba(122,167,255,.28)}.badge.brand{background:rgba(105,210,255,.14);color:var(--accent);border:1px solid rgba(105,210,255,.28)}.badge.muted{background:rgba(148,163,184,.12);color:var(--muted);border:1px solid rgba(148,163,184,.24)}.job-grid,.execution-list{animation:fade-in .45s ease both}@keyframes fade-in{from{opacity:0;transform:translateY(6px)}to{opacity:1;transform:translateY(0)}}.job-grid{margin-top:16px}.job-field{padding:12px 0;border-top:1px solid rgba(148,163,184,.12)}.job-field:first-child,.job-field:nth-child(2){border-top:0;padding-top:0}.job-field span{display:block;color:var(--muted);font-size:.76rem;margin-bottom:6px;letter-spacing:.06em;text-transform:uppercase}.job-field strong{display:block;line-height:1.6;word-break:break-word}.job-latest{margin-top:16px;padding:14px;border-radius:18px;border:1px solid var(--border);background:rgba(8,14,25,.84)}.job-latest.success{border-color:rgba(70,211,157,.24);background:rgba(70,211,157,.08)}.job-latest.danger{border-color:rgba(255,122,122,.24);background:rgba(255,122,122,.08)}.job-latest.muted{background:rgba(148,163,184,.08)}.job-latest-title{font-weight:700;margin-bottom:4px}.job-latest-meta{color:var(--muted);font-size:.84rem;line-height:1.5;margin-bottom:10px}.job-output{margin:0;padding:12px;border-radius:14px;background:rgba(1,6,17,.54);border:1px solid rgba(148,163,184,.14);white-space:pre-wrap;word-break:break-word;color:#d8e6ff;font-family:"SFMono-Regular","Menlo","Monaco","Consolas","Liberation Mono",monospace;font-size:.82rem;line-height:1.55}.job-output.muted{color:var(--muted)}.execution-list{display:grid;grid-template-columns:1fr;gap:14px}.execution-card{padding:18px}.execution-meta,.execution-stats{color:var(--muted);font-size:.84rem;line-height:1.55}.execution-stats{margin:12px 0 10px}.empty-state{padding:28px;border-radius:22px;border:1px dashed rgba(148,163,184,.24);background:rgba(8,14,25,.7);color:var(--muted);line-height:1.7}.footer{margin-top:18px;color:var(--muted);font-size:.82rem;line-height:1.6}.footer code{color:#e6f2ff;background:rgba(148,163,184,.12);padding:2px 6px;border-radius:6px}</style></head><body><main class="shell"><section class="hero"><div><p class="eyebrow">MiniMax Cron Dashboard</p><h1>静态任务与执行视图</h1><p>本地页面通过 veb 提供服务，数据从 SQLite 读取，cron 任务和最近执行结果会自动刷新。页面默认每 15 秒重载一次，便于在后台观察任务状态变化。</p></div><div class="hero-meta">')
	body.write_string(dashboard_metric_card_html('任务总数', snapshot.total_jobs.str(),
		'运行中与已停用任务的总和', 'accent'))
	body.write_string(dashboard_metric_card_html('已启用', snapshot.enabled_jobs.str(),
		'还能继续按计划触发的任务', 'accent'))
	body.write_string(dashboard_metric_card_html('执行记录', snapshot.total_executions.str(),
		'最近 20 条执行历史', 'accent'))
	body.write_string(dashboard_metric_card_html('失败记录', snapshot.failed_executions.str(),
		'exit code 非 0 的执行', 'accent'))
	body.write_string('</div></section><section class="section"><div class="section-head"><div><h2>Cron 任务</h2><div class="section-note">存储目录：<code>${html_escape(snapshot.storage_path)}</code></div></div><div class="section-note">SQLite：<code>${html_escape(snapshot.db_path)}</code> · 端口 <code>${port}</code></div></div>')
	if snapshot.jobs.len == 0 {
		body.write_string('<div class="empty-state">当前没有 Cron 任务。可以先运行 <code>minimax_cli cron add ...</code> 或 <code>minimax_cli cron delay ...</code> 创建任务。</div>')
	} else {
		body.write_string('<div class="job-grid">')
		for job in snapshot.jobs {
			if exec := latest_execution_for_job(snapshot.executions, job.job_id) {
				body.write_string(dashboard_job_card_html(job, exec, true))
			} else {
				body.write_string(dashboard_job_card_html(job, CronDashboardExecutionView{},
					false))
			}
		}
		body.write_string('</div>')
	}
	body.write_string('</section><section class="section"><div class="section-head"><div><h2>最近执行</h2><div class="section-note">按开始时间倒序展示，最多 20 条</div></div></div>')
	if snapshot.executions.len == 0 {
		body.write_string('<div class="empty-state">当前还没有执行历史。Cron 任务首次运行后，这里会出现详细记录。</div>')
	} else {
		body.write_string('<div class="execution-list">')
		for execution in snapshot.executions {
			body.write_string(dashboard_execution_card_html(execution))
		}
		body.write_string('</div>')
	}
	body.write_string('</section><div class="footer">页面由 <code>veb</code> 提供，数据由 <code>sqlite3</code> CLI 写入 <code>${html_escape(snapshot.db_path)}</code>。你可以用 <code>minimax_cli cron list</code>、<code>minimax_cli cron stats</code>、<code>minimax_cli cron tick</code> 和 <code>minimax_cli cron dashboard</code> 持续观察变化。</div></main></body></html>')
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
		return ctx.html('<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><title>Cron Dashboard</title><style>body{margin:0;padding:32px;font-family:"SF Pro Display","PingFang SC","Hiragino Sans GB","Microsoft YaHei UI",sans-serif;background:#08111f;color:#eef4ff}main{max-width:960px;margin:0 auto;padding:28px;border:1px solid rgba(148,163,184,.22);border-radius:24px;background:rgba(9,16,30,.94)}code{background:rgba(148,163,184,.12);padding:2px 6px;border-radius:6px}</style></head><body><main><h1>Cron Dashboard 无法加载</h1><p>${html_escape(err.msg())}</p><p>请确认 <code>sqlite3</code> 可用且数据库目录可写：<code>${html_escape(app.db_path)}</code></p></main></body></html>')
	}
	return ctx.html(build_cron_dashboard_page(snapshot, app.port))
}
