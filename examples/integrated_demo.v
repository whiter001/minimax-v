/**
 * examples/integrated_demo.v - MiniMax-V 功能集成演示
 *
 * 演示如何在 MiniMax-V 中集成 Sessions、Canvas、Nodes、Cron 四个模块
 * 场景：股票分析和定期报告系统
 */
import os
import time

fn main() {
	println('╔══════════════════════════════════════════════╗')
	println('║  MiniMax-V Advanced Features Demo            ║')
	println('║  (Sessions + Canvas + Nodes + Cron)          ║')
	println('╚══════════════════════════════════════════════╝\n')

	// 1. Sessions 演示：创建和管理股票分析会话
	session_demo()!

	println('\n' + '━'.repeat(50) + '\n')

	// 2. Canvas 演示：可视化数据
	canvas_demo()!

	println('\n' + '━'.repeat(50) + '\n')

	// 3. Nodes 演示：构建数据处理工作流
	nodes_demo()!

	println('\n' + '━'.repeat(50) + '\n')

	// 4. Cron 演示：定时任务调度
	cron_demo()!

	println('\n✅ 所有演示完成！\n')
}

// 演示 1: Sessions 会话管理
fn session_demo() ! {
	println('📋 Sessions 演示：会话管理')
	println('━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n')

	config_dir := os.join_path(os.temp_dir(), 'minimax_demo_sessions')
	defer { os.rmdir_all(config_dir) or {} }

	// 创建会话管理器
	mut manager := new_session_manager(config_dir)!

	// 创建新会话
	session1 := manager.create_session('股票-海天味业')!
	println('✓ 创建会话: ${session1.name} (ID: ${session1.id})')

	session2 := manager.create_session('股票-贵州茅台')!
	println('✓ 创建会话: ${session2.name} (ID: ${session2.id})')

	// 添加消息到第一个会话
	manager.add_message('user', '请分析海天味业的估值')!
	manager.add_message('assistant', '根据 Gordon Growth Model，目标价格为 ¥52 元/股')!
	println('✓ 添加了 2 条消息到 "${session1.name}"')

	// 切换到第二个会话
	manager.switch_session(session2.id)!
	println('✓ 切换到会话: "${session2.name}"')

	manager.add_message('user', '茅台怎么样？')!
	manager.add_message('assistant', '茅台是优质白酒，长期投资价值较高')!

	// 更新上下文
	manager.update_context('model', 'claude-opus')!
	manager.update_context('temperature', '0.7')!
	println('✓ 更新了会话上下文')

	// 列出所有会话
	println('\n会话列表:')
	sessions := manager.list_sessions()
	for session in sessions {
		stats := manager.get_stats(session.id)!
		println('  • ${session.name}')
		println('    消息数: ${stats['total_messages']}, 上下文大小: ${stats['context_size']}')
	}
}

// 演示 2: Canvas 可视化
fn canvas_demo() ! {
	println('📊 Canvas 演示：数据可视化')
	println('━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n')

	// 创建表格
	mut canvas := new_canvas('stock_table', '蓝筹股估值对比')

	headers := ['股票名称', '当前价格', '目标价格', '上升空间', '评级']
	rows := [
		['海天味业', '¥45.50', '¥52.00', '+14.3%', '买入'],
		['贵州茅台', '¥1980.00', '¥2200.00', '+11.1%', '持有'],
		['招商银行', '¥38.45', '¥42.00', '+9.2%', '中性'],
	]

	canvas.add_table(headers, rows)
	println('✓ 创建估值对比表格\n')
	println(canvas.render())

	// 创建图表
	mut chart_canvas := new_canvas('valuation_chart', '估值倍数分布')

	data := {
		'悲观预期': 28.5
		'保守预期': 35.2
		'中性预期': 42.8
		'乐观预期': 50.1
		'激进预期': 58.6
	}

	chart_canvas.add_chart('海天味业目标价格', data)
	println('✓ 创建价格分布图表\n')
	println(chart_canvas.render())

	// 导出为 HTML
	html := chart_canvas.export_html()
	println('✓ 可导出为 HTML: ${html.len} bytes')
}

// 演示 3: Nodes 计算图
fn nodes_demo() ! {
	println('⚙️ Nodes 演示：DAG 工作流')
	println('━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n')

	mut graph := new_graph()

	// 定义数据处理管道: fetch -> parse -> calculate -> format

	// 节点 1: 获取数据
	node_fetch := ComputeNode{
		id:          'fetch'
		name:        'Fetch Stock Data'
		input_type:  'string'
		output_type: 'json'
		compute:     fn (input string) string {
			return '{"name":"HAITIANWEIYE","price":45.50,"dividend":1.2}'
		}
	}

	// 节点 2: 解析数据
	node_parse := ComputeNode{
		id:          'parse'
		name:        'Parse JSON'
		input_type:  'json'
		output_type: 'map'
		compute:     fn (input string) string {
			return 'Parsed: ${input}'
		}
	}

	// 节点 3: 计算估值
	node_calc := ComputeNode{
		id:          'calculate'
		name:        'Calculate Valuation'
		input_type:  'map'
		output_type: 'valuation'
		compute:     fn (input string) string {
			// 简化的 Gordon Growth Model: P = D/(r-g)
			// 假设: D1=1.3, r=8%, g=5%
			price := 1.3 / (0.08 - 0.05)
			return 'Target Price: ¥${price:.2f}'
		}
	}

	// 节点 4: 格式化输出
	node_format := ComputeNode{
		id:          'format'
		name:        'Format Output'
		input_type:  'valuation'
		output_type: 'string'
		compute:     fn (input string) string {
			return '═══════════════\n投资建议\n═══════════════\n${input}\n评级: 买入\n'
		}
	}

	// 添加节点
	graph.add_node(node_fetch)!
	graph.add_node(node_parse)!
	graph.add_node(node_calc)!
	graph.add_node(node_format)!

	println('✓ 添加了 4 个计算节点')

	// 连接节点
	graph.add_edge('fetch', 'parse')!
	graph.add_edge('parse', 'calculate')!
	graph.add_edge('calculate', 'format')!

	println('✓ 连接了节点成管道')

	// 验证并生成执行顺序
	graph.validate()!
	graph.generate_execution_order()!

	println('✓ 验证无循环，执行顺序: ${graph.execution_order.join(' -> ')}\n')

	// 执行管道
	result := graph.execute('fetch')!
	println('执行结果:')
	println(result)

	// 查看图的可视化（Graphviz 格式）
	dot := graph.to_dot()
	println('图的 DOT 表示:')
	println(dot)
}

// 演示 4: Cron 定时任务
fn cron_demo() ! {
	println('⏰ Cron 演示：定时任务调度')
	println('━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n')

	config_dir := os.join_path(os.temp_dir(), 'minimax_demo_cron')
	defer { os.rmdir_all(config_dir) or {} }

	// 定义任务回调
	callback := fn (job CronJob) ! {
		eprintln('  → 执行任务: ${job.name}')
	}

	// 创建调度器
	mut scheduler := new_cron_scheduler(config_dir, callback)!

	println('✓ 创建 Cron 调度器\n')

	// 添加任务
	println('添加定时任务:')

	scheduler.add_job('每日数据备份', '@daily', 'backup_data.sh')!
	println('  ✓ @daily - 每日数据备份')

	scheduler.add_job('每小时日志滚动', '@hourly', 'rotate_logs.sh')!
	println('  ✓ @hourly - 每小时日志滚动')

	scheduler.add_job('每周一清理缓存', '0 0 ? * 1', 'cleanup_cache.sh')!
	println('  ✓ 0 0 ? * 1 - 每周一午夜清理缓存')

	scheduler.add_job('每天 8 点生成报告', '0 8 * * *', 'generate_report.sh')!
	println('  ✓ 0 8 * * * - 每天 8 点生成报告')

	// 启动调度器
	scheduler.start()
	println('\n✓ 调度器已启动\n')

	// 列出任务
	println('定时任务列表:')
	jobs := scheduler.list_jobs()
	for i, job in jobs {
		status := if job.enabled { '✓' } else { '✗' }
		println('  ${i + 1}. [${status}] ${job.name} (${job.schedule})')
	}

	// 模拟调度周期
	println('\n模拟调度（4 秒）:')
	for i := 0; i < 4; i++ {
		scheduler.tick()!
		print('.')
		time.sleep(1 * time.second)
	}
	println('✓\n')

	// 禁用一个任务
	if jobs.len > 0 {
		scheduler.set_job_enabled(jobs[0].id, false)!
		println('✓ 禁用了任务: "${jobs[0].name}"')
	}

	// 获取统计信息
	stats := scheduler.get_stats()
	println('\n调度统计:')
	println('  • 总任务数: ${stats['total_jobs']}')
	println('  • 启用: ${stats['enabled_jobs']}')
	println('  • 禁用: ${stats['disabled_jobs']}')
}

// ============================================================================
// 以下是必要的导入和 stub 实现
// ============================================================================

// Sessions 的 stub（完整实现在 src/sessions.v）
pub struct Message {
pub:
	role      string
	content   string
	timestamp i64
}

pub struct Session {
pub:
	id         string
	name       string
mut:
	messages   []Message
	context    map[string]string
	created_at i64
	updated_at i64
}

pub struct SessionManager {
pub:
	storage_path string
mut:
	sessions          map[string]Session
	active_session_id string
}

fn new_session_manager(storage_path string) !SessionManager {
	if !os.is_dir(storage_path) {
		os.mkdir_all(storage_path)!
	}
	return SessionManager{
		sessions:          map[string]Session{}
		storage_path:      storage_path
		active_session_id: 'default'
	}
}

fn (mut manager SessionManager) create_session(name string) !Session {
	id := 'sess_${time.now().unix_milli()}'
	session := Session{
		id:         id
		name:       name
		messages:   []Message{}
		context:    map[string]string{}
		created_at: time.now().unix()
		updated_at: time.now().unix()
	}
	manager.sessions[id] = session
	manager.active_session_id = id
	return session
}

fn (mut manager SessionManager) add_message(role string, content string) ! {
	mut session := manager.sessions[manager.active_session_id] or { return error('no session') }
	session.messages << Message{
		role:      role
		content:   content
		timestamp: time.now().unix()
	}
	manager.sessions[manager.active_session_id] = session
}

fn (mut manager SessionManager) switch_session(id string) ! {
	if id !in manager.sessions {
		return error('session not found')
	}
	manager.active_session_id = id
}

fn (mut manager SessionManager) update_context(key string, value string) ! {
	mut session := manager.sessions[manager.active_session_id] or { return error('no session') }
	session.context[key] = value
	manager.sessions[manager.active_session_id] = session
}

fn (manager SessionManager) get_stats(session_id string) !map[string]int {
	session := manager.sessions[session_id] or { return error('session not found') }
	return {
		'total_messages': session.messages.len
		'context_size':   session.context.len
	}
}

fn (manager SessionManager) list_sessions() []Session {
	mut sessions := []Session{}
	for _, s in manager.sessions {
		sessions << s
	}
	return sessions
}

// Canvas 的 stub
pub struct Canvas {
pub:
	id        string
	title     string
mut:
	content   string
	data_type string
}

fn new_canvas(id string, title string) Canvas {
	return Canvas{
		id:        id
		title:     title
		content:   ''
		data_type: 'text'
	}
}

fn (mut canvas Canvas) add_table(headers []string, rows [][]string) {
	mut result := ''
	result += '  ┌' + '─'.repeat((headers.len * 15)) + '┐\n'
	for h in headers {
		result += '  │ ${h:14} '
	}
	result += '│\n'
	result += '  ├' + '─'.repeat((headers.len * 15)) + '┤\n'
	for row in rows {
		for cell in row {
			result += '  │ ${cell:14} '
		}
		result += '│\n'
	}
	result += '  └' + '─'.repeat((headers.len * 15)) + '┘\n'
	canvas.content = result
	canvas.data_type = 'table'
}

fn (mut canvas Canvas) add_chart(title string, data map[string]f64) {
	mut result := '${title}\n\n'
	for label, value in data {
		bar_width := int(value / 60.0 * 30.0)
		result += '${label:8} │ ${'█'.repeat(bar_width)} ${value:.1f}\n'
	}
	canvas.content = result
	canvas.data_type = 'chart'
}

fn (canvas Canvas) render() string {
	return '╭─ ${canvas.title} ─╮\n│\n${canvas.content}│\n╰${'─'.repeat(
		canvas.title.len + 8)}╯\n'
}

fn (canvas Canvas) export_html() string {
	return '<html><body><pre>${canvas.content}</pre></body></html>'
}

// Nodes 的 stub
pub type ComputeFn = fn (string) string

pub struct ComputeNode {
pub:
	id          string
	name        string
	input_type  string
	output_type string
mut:
	compute     ?ComputeFn
}

pub struct ComputeGraph {
mut:
	nodes           map[string]ComputeNode
	edges           []string
	execution_order []string
}

fn new_graph() ComputeGraph {
	return ComputeGraph{
		nodes:           map[string]ComputeNode{}
		edges:           []
		execution_order: []
	}
}

fn (mut graph ComputeGraph) add_node(node ComputeNode) ! {
	graph.nodes[node.id] = node
}

fn (mut graph ComputeGraph) add_edge(from string, to string) ! {
	graph.edges << '${from}->${to}'
}

fn (mut graph ComputeGraph) validate() ! {}

fn (mut graph ComputeGraph) generate_execution_order() ! {
	for id, _ in graph.nodes {
		graph.execution_order << id
	}
}

fn (graph ComputeGraph) execute(input string) !string {
	mut result := input
	for node_id in graph.execution_order {
		node := graph.nodes[node_id] or { continue }
		if c := node.compute {
			result = c(result)
		}
	}
	return result
}

fn (graph ComputeGraph) to_dot() string {
	return 'digraph { ${graph.edges.join('; ')} }'
}

// Cron 的 stub
pub struct CronJob {
pub:
	id              string
	name            string
	schedule        string
	command         string
mut:
	enabled         bool
	execution_count int
	last_run        i64
}

pub type CronCallback = fn (CronJob) !

pub struct CronScheduler {
pub:
	storage_path string
mut:
	jobs         map[string]CronJob
	running      bool
	callback     ?CronCallback
}

fn new_cron_scheduler(storage_path string, callback CronCallback) !CronScheduler {
	return CronScheduler{
		jobs:         map[string]CronJob{}
		running:      false
		callback:     callback
		storage_path: storage_path
	}
}

fn (mut scheduler CronScheduler) add_job(name string, schedule string, command string) !CronJob {
	id := 'cron_${time.now().unix_milli()}'
	job := CronJob{
		id:              id
		name:            name
		schedule:        schedule
		command:         command
		enabled:         true
		execution_count: 0
		last_run:        0
	}
	scheduler.jobs[id] = job
	return job
}

fn (mut scheduler CronScheduler) start() {
	scheduler.running = true
}

fn (mut scheduler CronScheduler) tick() ! {
	// 模拟执行
	for id, mut job in scheduler.jobs {
		if job.enabled {
			if cb := scheduler.callback {
				cb(job)!
			}
			job.execution_count++
			job.last_run = time.now().unix()
			scheduler.jobs[id] = job
		}
	}
}

fn (mut scheduler CronScheduler) set_job_enabled(id string, enabled bool) ! {
	mut job := scheduler.jobs[id] or { return error('job not found') }
	job.enabled = enabled
	scheduler.jobs[id] = job
}

fn (scheduler CronScheduler) get_stats() map[string]int {
	mut enabled := 0
	mut disabled := 0
	for _, job in scheduler.jobs {
		if job.enabled {
			enabled++
		} else {
			disabled++
		}
	}
	return {
		'total_jobs':    scheduler.jobs.len
		'enabled_jobs':  enabled
		'disabled_jobs': disabled
	}
}

fn (scheduler CronScheduler) list_jobs() []CronJob {
	mut jobs := []CronJob{}
	for _, j in scheduler.jobs {
		jobs << j
	}
	return jobs
}
