module main

import term.ui as tui
import time

struct TermUiChatItem {
	role      string
	text      string
	timestamp string
}

struct TermUiRenderLine {
	text  string
	color string
}

@[heap]
struct TermUiApp {
mut:
	ctx                  &tui.Context = unsafe { nil }
	client               ApiClient
	input                []rune
	messages             []TermUiChatItem
	current_stream       string
	current_thinking     string
	activity_log         []string
	status_line          string
	is_loading           bool
	show_sidebar         bool
	awaiting_user_answer bool
	pending_question     string
	pending_answer       string
	skill_name           string
	initial_prompt       string
}

__global g_term_ui_app = &TermUiApp(unsafe { nil })
__global g_term_ui_enabled = false

fn term_ui_is_active() bool {
	return g_term_ui_enabled && g_term_ui_app != unsafe { nil }
}

fn term_ui_set_status(text string) {
	if !term_ui_is_active() {
		return
	}
	unsafe {
		g_term_ui_app.set_status(text)
	}
}

fn term_ui_clear_status() {
	if !term_ui_is_active() {
		return
	}
	unsafe {
		g_term_ui_app.clear_status()
	}
}

fn term_ui_append_stream_text(text string) {
	if !term_ui_is_active() || text.len == 0 {
		return
	}
	unsafe {
		g_term_ui_app.append_stream_text(text)
	}
}

fn term_ui_append_thinking(text string) {
	if !term_ui_is_active() || text.len == 0 {
		return
	}
	unsafe {
		g_term_ui_app.append_thinking(text)
	}
}

fn term_ui_add_activity(text string) {
	if !term_ui_is_active() || text.len == 0 {
		return
	}
	unsafe {
		g_term_ui_app.add_activity(text)
	}
}

fn term_ui_add_tool_result(name string, result string) {
	if !term_ui_is_active() {
		return
	}
	unsafe {
		g_term_ui_app.add_tool_result(name, result)
	}
}

fn term_ui_ask_user(question string) string {
	if !term_ui_is_active() {
		return 'Error: term-ui is inactive'
	}
	unsafe {
		return g_term_ui_app.wait_for_user_answer(question)
	}
}

fn term_ui_now() string {
	return time.now().custom_format('HH:mm:ss')
}

fn term_ui_visual_width_char(r rune) int {
	return if r > 127 { 2 } else { 1 }
}

fn term_ui_visual_width(text string) int {
	mut width := 0
	for r in text.runes() {
		width += term_ui_visual_width_char(r)
	}
	return width
}

fn term_ui_truncate_by_width(text string, max_width int) string {
	if max_width <= 0 {
		return ''
	}
	mut width := 0
	mut out := []rune{}
	for r in text.runes() {
		inc := term_ui_visual_width_char(r)
		if width + inc > max_width {
			break
		}
		out << r
		width += inc
	}
	return out.string()
}

fn term_ui_tail_by_width(text string, max_width int) string {
	if max_width <= 0 {
		return ''
	}
	runes := text.runes()
	mut width := 0
	mut start := runes.len
	for i := runes.len - 1; i >= 0; i-- {
		inc := term_ui_visual_width_char(runes[i])
		if width + inc > max_width {
			break
		}
		width += inc
		start = i
	}
	return runes[start..].string()
}

fn term_ui_wrap_text(text string, width int, max_lines int) []string {
	if width <= 0 || max_lines <= 0 {
		return []string{}
	}
	mut lines := []string{}
	for raw_line in text.split('\n') {
		if raw_line.len == 0 {
			lines << ''
			if lines.len >= max_lines {
				return lines[..max_lines]
			}
			continue
		}
		mut current := []rune{}
		mut current_width := 0
		for r in raw_line.runes() {
			inc := term_ui_visual_width_char(r)
			if current_width + inc > width {
				lines << current.string()
				if lines.len >= max_lines {
					return lines[..max_lines]
				}
				current = []rune{}
				current_width = 0
			}
			current << r
			current_width += inc
		}
		lines << current.string()
		if lines.len >= max_lines {
			return lines[..max_lines]
		}
	}
	return lines[..if lines.len > max_lines {
		max_lines
	} else {
		lines.len
	}]
}

fn term_ui_role_label(role string) string {
	return match role {
		'user' { 'YOU' }
		'assistant' { 'BOT' }
		'error' { 'ERROR' }
		'ask' { 'ASK' }
		'answer' { 'ANSWER' }
		else { role.to_upper() }
	}
}

fn term_ui_role_color(role string) string {
	return match role {
		'user' { 'green' }
		'assistant' { 'cyan' }
		'error' { 'red' }
		'ask' { 'yellow' }
		'answer' { 'green' }
		else { 'white' }
	}
}

fn (mut app TermUiApp) push_message(role string, text string) {
	app.messages << TermUiChatItem{
		role:      role
		text:      text
		timestamp: term_ui_now()
	}
	if app.messages.len > 200 {
		app.messages = app.messages[app.messages.len - 200..]
	}
}

fn (mut app TermUiApp) add_activity(text string) {
	entry := '[${term_ui_now()}] ${text}'
	app.activity_log << entry
	if app.activity_log.len > 120 {
		app.activity_log = app.activity_log[app.activity_log.len - 120..]
	}
}

fn (mut app TermUiApp) add_tool_result(name string, result string) {
	display_len := if result.len > 100 { 100 } else { result.len }
	display := result[..display_len].replace('\n', ' ').replace('\t', ' ')
	suffix := if result.len > 100 { '...' } else { '' }
	app.add_activity('${name}: ${display}${suffix}')
}

fn (mut app TermUiApp) set_status(text string) {
	app.status_line = text
}

fn (mut app TermUiApp) clear_status() {
	app.status_line = ''
}

fn (mut app TermUiApp) append_stream_text(text string) {
	app.current_stream += text
}

fn (mut app TermUiApp) append_thinking(text string) {
	app.current_thinking += text
	if app.current_thinking.len > 4000 {
		app.current_thinking = app.current_thinking[app.current_thinking.len - 4000..]
	}
}

fn (mut app TermUiApp) start_prompt(prompt string) {
	trimmed := prompt.trim_space()
	if trimmed.len == 0 {
		return
	}
	app.push_message('user', trimmed)
	app.current_stream = ''
	app.current_thinking = ''
	app.status_line = '等待模型...'
	app.is_loading = true
	go app.run_prompt(trimmed)
}

fn (mut app TermUiApp) finish_prompt(response string) {
	final_text := if app.current_stream.trim_space().len > 0 {
		app.current_stream.trim_space()
	} else {
		response.trim_space()
	}
	if final_text.len > 0 {
		app.push_message('assistant', final_text)
	}
	app.current_stream = ''
	app.current_thinking = ''
	app.status_line = ''
	app.is_loading = false
	app.add_activity('本轮对话完成')
}

fn (mut app TermUiApp) run_prompt(prompt string) {
	response := app.client.chat(prompt) or {
		app.push_message('error', '错误: ${err}')
		app.current_stream = ''
		app.current_thinking = ''
		app.status_line = ''
		app.is_loading = false
		app.add_activity('请求失败: ${err}')
		return
	}
	app.finish_prompt(response)
}

fn (mut app TermUiApp) submit_input() {
	if app.awaiting_user_answer {
		answer := app.input.string().trim_space()
		app.input = []rune{}
		app.pending_answer = if answer.len > 0 { answer } else { '(User provided no answer)' }
		app.awaiting_user_answer = false
		app.push_message('answer', app.pending_answer)
		app.add_activity('已提交 ask_user 回复')
		return
	}
	if app.is_loading {
		return
	}
	prompt := app.input.string().trim_space()
	app.input = []rune{}
	app.start_prompt(prompt)
}

fn (mut app TermUiApp) wait_for_user_answer(question string) string {
	app.pending_question = question
	app.pending_answer = ''
	app.awaiting_user_answer = true
	app.push_message('ask', question)
	app.add_activity('AI 请求补充信息')
	app.set_status('等待你的补充信息')
	for app.awaiting_user_answer {
		time.sleep(100 * time.millisecond)
	}
	answer := app.pending_answer.trim_space()
	app.pending_question = ''
	app.pending_answer = ''
	app.clear_status()
	if answer.len == 0 {
		return '(User provided no answer)'
	}
	return answer
}

fn term_ui_build_chat_lines(messages []TermUiChatItem, current_stream string, width int,
	max_lines int) []TermUiRenderLine {
	mut lines := []TermUiRenderLine{}
	for item in messages {
		label := '[${term_ui_role_label(item.role)} ${item.timestamp}]'
		lines << TermUiRenderLine{
			text:  label
			color: term_ui_role_color(item.role)
		}
		for wrapped in term_ui_wrap_text(item.text, width, max_lines) {
			lines << TermUiRenderLine{
				text:  wrapped
				color: 'white'
			}
		}
		lines << TermUiRenderLine{
			text:  ''
			color: 'white'
		}
	}
	if current_stream.len > 0 {
		lines << TermUiRenderLine{
			text:  '[BOT ${term_ui_now()}]'
			color: 'cyan'
		}
		for wrapped in term_ui_wrap_text(current_stream, width, max_lines) {
			lines << TermUiRenderLine{
				text:  wrapped
				color: 'white'
			}
		}
	}
	if lines.len <= max_lines {
		return lines
	}
	return lines[lines.len - max_lines..]
}

fn term_ui_apply_color(mut ctx tui.Context, color string) {
	match color {
		'green' {
			ctx.set_color(r: 90, g: 220, b: 120)
		}
		'cyan' {
			ctx.set_color(r: 95, g: 215, b: 255)
		}
		'red' {
			ctx.set_color(r: 255, g: 110, b: 110)
		}
		'yellow' {
			ctx.set_color(r: 255, g: 215, b: 90)
		}
		'gray' {
			ctx.set_color(r: 150, g: 150, b: 150)
		}
		else {
			ctx.set_color(r: 240, g: 240, b: 240)
		}
	}
}

fn term_ui_frame(x voidptr) {
	mut app := unsafe { &TermUiApp(x) }
	app.ctx.clear()
	width, height := app.ctx.window_width, app.ctx.window_height
	sidebar_width := if app.show_sidebar && width >= 110 { 36 } else { 0 }
	chat_width := if sidebar_width > 0 { width - sidebar_width - 4 } else { width - 2 }
	chat_height := height - 5

	app.ctx.set_bg_color(r: 18, g: 58, b: 96)
	mut title := ' MiniMax Term UI | ${app.client.model}'
	if app.skill_name.len > 0 {
		title += ' | skill=${app.skill_name}'
	}
	if app.is_loading {
		title += ' | busy'
	}
	app.ctx.draw_text(1, 1, term_ui_truncate_by_width(title, width - 2))
	if title.len < width {
		app.ctx.draw_text(term_ui_truncate_by_width(title, width - 2).len + 1, 1, ' '.repeat(width))
	}
	app.ctx.reset()

	chat_lines := term_ui_build_chat_lines(app.messages, app.current_stream, chat_width - 2,
		chat_height)
	mut row := 3
	for line in chat_lines {
		if row > chat_height + 1 {
			break
		}
		term_ui_apply_color(mut app.ctx, line.color)
		app.ctx.draw_text(2, row, term_ui_truncate_by_width(line.text, chat_width - 2))
		app.ctx.reset()
		row++
	}

	if sidebar_width > 0 {
		sidebar_x := width - sidebar_width + 1
		app.ctx.set_color(r: 90, g: 90, b: 90)
		for i in 2 .. height {
			app.ctx.draw_text(sidebar_x - 2, i, '│')
		}
		app.ctx.reset()

		term_ui_apply_color(mut app.ctx, 'yellow')
		app.ctx.draw_text(sidebar_x, 3, 'Status')
		app.ctx.reset()
		status_text := if app.status_line.len > 0 { app.status_line } else { 'Idle' }
		for idx, line in term_ui_wrap_text(status_text, sidebar_width - 2, 3) {
			app.ctx.draw_text(sidebar_x, 4 + idx, line)
		}

		term_ui_apply_color(mut app.ctx, 'yellow')
		app.ctx.draw_text(sidebar_x, 8, 'Thinking')
		app.ctx.reset()
		thinking_text := if app.current_thinking.len > 0 { app.current_thinking } else { '(none)' }
		for idx, line in term_ui_wrap_text(thinking_text, sidebar_width - 2, 6) {
			app.ctx.draw_text(sidebar_x, 9 + idx, line)
		}

		term_ui_apply_color(mut app.ctx, 'yellow')
		app.ctx.draw_text(sidebar_x, 16, 'Activity')
		app.ctx.reset()
		activity := if app.activity_log.len > 10 {
			app.activity_log[app.activity_log.len - 10..]
		} else {
			app.activity_log
		}
		mut activity_row := 17
		for item in activity {
			for _, line in term_ui_wrap_text(item, sidebar_width - 2, 2) {
				if activity_row >= height - 3 {
					break
				}
				app.ctx.draw_text(sidebar_x, activity_row, line)
				activity_row++
			}
			if activity_row >= height - 3 {
				break
			}
		}
	}

	input_label := if app.awaiting_user_answer { 'answer > ' } else { 'you > ' }
	input_width := if sidebar_width > 0 {
		chat_width - input_label.len - 2
	} else {
		width - input_label.len - 4
	}
	term_ui_apply_color(mut app.ctx, if app.awaiting_user_answer { 'yellow' } else { 'green' })
	input_text := term_ui_tail_by_width(app.input.string(), input_width)
	app.ctx.draw_text(2, height - 1, input_label + input_text)
	app.ctx.reset()

	footer := '[Enter] 发送  [Ctrl+L] 清空  [Ctrl+D] 侧栏  [Esc] 退出'
	app.ctx.set_color(r: 140, g: 140, b: 140)
	app.ctx.draw_text(2, height, term_ui_truncate_by_width(footer, width - 2))
	app.ctx.reset()
	app.ctx.show_cursor()
	app.ctx.set_cursor_position(2 + term_ui_visual_width(input_label) +
		term_ui_visual_width(input_text), height - 1)
	app.ctx.flush()
}

fn term_ui_event(e &tui.Event, x voidptr) {
	mut app := unsafe { &TermUiApp(x) }
	if e.typ != .key_down {
		return
	}
	if e.modifiers == .ctrl {
		match e.code {
			.l {
				app.messages = []TermUiChatItem{}
				app.current_stream = ''
				app.current_thinking = ''
				app.add_activity('聊天记录已清空')
				app.client.clear_messages()
				return
			}
			.d {
				app.show_sidebar = !app.show_sidebar
				return
			}
			else {}
		}
	}
	match e.code {
		.escape {
			exit(0)
		}
		.enter {
			app.submit_input()
		}
		.backspace {
			if app.input.len > 0 {
				app.input.delete_last()
			}
		}
		else {
			if e.utf8.len > 0 {
				for r in e.utf8.runes() {
					if r >= 32 {
						app.input << r
					}
				}
			}
		}
	}
}

fn start_term_ui(mut client ApiClient, skill_name string, initial_prompt string) {
	client.interactive_mode = true
	client.use_streaming = true
	mut app := &TermUiApp{
		client:         client
		show_sidebar:   true
		skill_name:     skill_name
		initial_prompt: initial_prompt.trim_space()
	}
	unsafe {
		g_term_ui_app = app
	}
	g_term_ui_enabled = true
	defer {
		g_term_ui_enabled = false
		g_term_ui_app = unsafe { nil }
	}

	app.ctx = tui.init(
		user_data:      app
		event_fn:       term_ui_event
		frame_fn:       term_ui_frame
		frame_rate:     20
		hide_cursor:    false
		capture_events: true
		window_title:   'MiniMax Term UI'
	)

	if app.initial_prompt.len > 0 {
		app.start_prompt(app.initial_prompt)
	}

	app.ctx.run() or { eprintln('term-ui error: ${err}') }
}
