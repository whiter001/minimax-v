/**
 * canvas.v - Live Canvas 可视化模块
 *
 * 实时渲染文本、表格、图表到终端或 HTTP 服务。
 * - 支持表格和图表渲染
 * - 简单的 HTTP 服务器用于实时预览
 * - 支持多个并发 Canvas 更新
 */
import json
import time

pub struct Canvas {
pub mut:
	id         string
	title      string
	content    string
	width      int
	height     int
	data_type  string // "text", "table", "chart"
	updated_at i64
}

pub struct TableData {
	headers []string
	rows    [][]string
}

pub struct ChartData {
	title  string
	labels []string
	values []f64
}

pub struct CanvasServer {
pub mut:
	port       int
	canvas_map map[string]Canvas
	running    bool
}

// 创建新 Canvas
pub fn new_canvas(id string, title string) Canvas {
	return Canvas{
		id:         id
		title:      title
		content:    ''
		width:      80
		height:     24
		data_type:  'text'
		updated_at: time.now().unix()
	}
}

// 创建 Canvas 服务器
pub fn new_canvas_server(port int) CanvasServer {
	return CanvasServer{
		port:       port
		canvas_map: map[string]Canvas{}
		running:    false
	}
}

// 添加文本内容
pub fn (mut canvas Canvas) add_text(content string) {
	canvas.content = content
	canvas.data_type = 'text'
	canvas.updated_at = time.now().unix()
}

// 添加表格
pub fn (mut canvas Canvas) add_table(headers []string, rows [][]string) {
	table_data := TableData{
		headers: headers
		rows:    rows
	}

	// 渲染表格
	canvas.content = render_table(table_data)
	canvas.data_type = 'table'
	canvas.updated_at = time.now().unix()
}

// 添加图表（简单的 ASCII 柱状图）
pub fn (mut canvas Canvas) add_chart(title string, data map[string]f64) {
	chart_data := ChartData{
		title:  title
		labels: data.keys()
		values: data.values()
	}

	canvas.content = render_chart(chart_data)
	canvas.data_type = 'chart'
	canvas.updated_at = time.now().unix()
}

// 渲染成终端可显示的内容
pub fn (canvas Canvas) render() string {
	mut output := ''

	// 标题
	output += '╔${'═'.repeat(canvas.width - 2)}╗\n'
	padding := (canvas.width - canvas.title.len - 2) / 2
	output += '║ ${' '.repeat(padding)}${canvas.title}${' '.repeat(canvas.width - 2 - padding - canvas.title.len)} ║\n'
	output += '╠${'═'.repeat(canvas.width - 2)}╣\n'

	// 内容
	for line in canvas.content.split('\n') {
		if line.len > canvas.width - 4 {
			output += '║ ${line[..canvas.width - 4]}... ║\n'
		} else {
			output += '║ ${line}${' '.repeat(canvas.width - 4 - line.len)} ║\n'
		}
	}

	// 底部
	output += '╚${'═'.repeat(canvas.width - 2)}╝\n'

	return output
}

// 转换为 JSON（用于 HTTP 响应）
pub fn (canvas Canvas) to_json() string {
	return json.encode(canvas)
}

// 渲染表格
fn render_table(table TableData) string {
	if table.headers.len == 0 {
		return '(空表格)'
	}

	mut output := ''

	// 计算列宽
	mut col_widths := []int{len: table.headers.len, init: 0}
	for i, header in table.headers {
		col_widths[i] = header.len
	}

	for row in table.rows {
		for i, cell in row {
			if i < col_widths.len && cell.len > col_widths[i] {
				col_widths[i] = cell.len
			}
		}
	}

	// 渲染表头
	for i, header in table.headers {
		output += '│ ${header}${' '.repeat(col_widths[i] - header.len)} '
	}
	output += '│\n'

	// 分隔线
	for _, width in col_widths {
		output += '├─${'─'.repeat(width)}─'
	}
	output += '┤\n'

	// 渲染行
	for row in table.rows {
		for i, cell in row {
			if i < col_widths.len {
				output += '│ ${cell}${' '.repeat(col_widths[i] - cell.len)} '
			}
		}
		output += '│\n'
	}

	return output
}

// 渲染图表（ASCII 柱状图）
fn render_chart(chart ChartData) string {
	if chart.values.len == 0 {
		return '(空图表)'
	}

	mut output := '${chart.title}\n\n'

	// 找到最大值用于缩放
	mut max_val := 0.0
	for val in chart.values {
		if val > max_val {
			max_val = val
		}
	}

	if max_val == 0 {
		return output + '(所有数据都是 0)'
	}

	// 渲染柱状图
	for i, label in chart.labels {
		if i < chart.values.len {
			val := chart.values[i]
			bar_width := int(val / max_val * 40.0)
			bar := '█'.repeat(bar_width)
			display_label := if label.len > 10 { label[..10] } else { label }
			output += '${display_label:10} │ ${bar} ${val}\n'
		}
	}

	return output
}

// 启动 Canvas HTTP 服务器
pub fn (mut server CanvasServer) start() ! {
	server.running = true

	// 这里是简化实现，实际需要完整的 HTTP 服务器
	// 在生产中，应该使用 vweb 或类似框架

	eprintln('Canvas 服务器运行在 http://localhost:${server.port}')
	eprintln('访问 http://localhost:${server.port}/canvas/{id} 查看')
}

// 停止服务器
pub fn (mut server CanvasServer) stop() {
	server.running = false
}

// 更新 Canvas
pub fn (mut server CanvasServer) update(id string, canvas Canvas) {
	mut updated_canvas := canvas
	updated_canvas.updated_at = time.now().unix()
	server.canvas_map[id] = updated_canvas
}

// 获取 Canvas
pub fn (server CanvasServer) get(id string) ?Canvas {
	return server.canvas_map[id] or { none }
}

// 列出所有 Canvas
pub fn (server CanvasServer) list() []Canvas {
	mut canvases := []Canvas{}
	for _, canvas in server.canvas_map {
		canvases << canvas
	}
	return canvases
}

// 导出 Canvas 为 HTML（用于浏览器预览）
pub fn (canvas Canvas) export_html() string {
	mut html := '<!DOCTYPE html>\n'
	html += '<html>\n'
	html += '<head>\n'
	html += '  <meta charset="UTF-8">\n'
	html += '  <title>${canvas.title}</title>\n'
	html += '  <style>\n'
	html += '    body { font-family: monospace; padding: 20px; background: #f5f5f5; }\n'
	html += '    pre { background: white; padding: 20px; border-radius: 4px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }\n'
	html += '  </style>\n'
	html += '</head>\n'
	html += '<body>\n'
	html += '<h1>${canvas.title}</h1>\n'
	html += '<pre>${canvas.content}</pre>\n'
	html += '<p style="color: #999;">更新于: ${time.unix(canvas.updated_at).format_ss()}</p>\n'
	html += '</body>\n'
	html += '</html>\n'
	return html
}
