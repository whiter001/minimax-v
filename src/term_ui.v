module main

import term.ui as tui
import time

// TermUiChatItem represents a single chat message in the UI.
struct TermUiChatItem {
	role      string
	text      string
	timestamp string
}

// TermUiRenderLine represents a single rendered line with color.
struct TermUiRenderLine {
	text  string
	color string
}

// TermUiApp is the terminal UI application state.
@[heap]
struct TermUiApp {
mut:
	ctx              &tui.Context = unsafe { nil }
	app_ctx          &AppContext  = unsafe { nil }
	input            []rune
	messages         []TermUiChatItem
	current_stream   string
	current_thinking string
	activity_log     []string
	status_line      string
	is_loading       bool
	show_sidebar     bool
}

// push_message adds a new chat message to the history.
fn (mut app TermUiApp) push_message(role string, text string) {
	app.messages << TermUiChatItem{
		role:      role
		text:      text
		timestamp: app.now()
	}
	if app.messages.len > 200 {
		app.messages = app.messages[app.messages.len - 200..]
	}
}

// add_activity appends an activity log entry.
fn (mut app TermUiApp) add_activity(text string) {
	entry := '[${app.now()}] ${text}'
	app.activity_log << entry
	if app.activity_log.len > 120 {
		app.activity_log = app.activity_log[app.activity_log.len - 120..]
	}
}

// set_status updates the status line text.
fn (mut app TermUiApp) set_status(text string) {
	if app.status_line == text {
		return
	}
	app.status_line = text
}

// clear_status clears the status line.
fn (mut app TermUiApp) clear_status() {
	if app.status_line.len == 0 {
		return
	}
	app.status_line = ''
}

// append_stream_text appends text to the streaming output.
fn (mut app TermUiApp) append_stream_text(text string) {
	app.current_stream += text
}

// append_thinking appends text to the thinking content.
fn (mut app TermUiApp) append_thinking(text string) {
	app.current_thinking += text
	if app.current_thinking.len > 4000 {
		app.current_thinking = app.current_thinking[app.current_thinking.len - 4000..]
	}
}

// now returns the current time formatted as HH:mm:ss.
fn (mut app TermUiApp) now() string {
	return time.now().custom_format('HH:mm:ss')
}

// visual_width_char returns the display width of a single rune.
fn visual_width_char(r rune) int {
	return if r > 127 { 2 } else { 1 }
}

// visual_width returns the total display width of a string.
fn visual_width(text string) int {
	mut width := 0
	for r in text.runes() {
		width += visual_width_char(r)
	}
	return width
}

// truncate_by_width truncates text to fit within max_width.
fn truncate_by_width(text string, max_width int) string {
	if max_width <= 0 {
		return ''
	}
	mut width := 0
	mut out := []rune{}
	for r in text.runes() {
		inc := visual_width_char(r)
		if width + inc > max_width {
			break
		}
		out << r
		width += inc
	}
	return out.string()
}

// tail_by_width keeps the last N characters by visual width.
fn tail_by_width(text string, max_width int) string {
	if max_width <= 0 {
		return ''
	}
	runes := text.runes()
	mut width := 0
	mut start := runes.len
	for i := runes.len - 1; i >= 0; i-- {
		inc := visual_width_char(runes[i])
		if width + inc > max_width {
			break
		}
		width += inc
		start = i
	}
	return runes[start..].string()
}

// wrap_text wraps text to fit within width and limits to max_lines.
fn wrap_text(text string, width int, max_lines int) []string {
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
			inc := visual_width_char(r)
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

// role_label returns the display label for a message role.
fn role_label(role string) string {
	return match role {
		'user' { 'YOU' }
		'assistant' { 'BOT' }
		'error' { 'ERROR' }
		'ask' { 'ASK' }
		'answer' { 'ANSWER' }
		else { role.to_upper() }
	}
}

// role_color returns the display color for a message role.
fn role_color(role string) string {
	return match role {
		'user' { 'green' }
		'assistant' { 'cyan' }
		'error' { 'red' }
		'ask' { 'yellow' }
		'answer' { 'green' }
		else { 'white' }
	}
}

// build_chat_lines builds the render lines from messages and stream.
fn build_chat_lines(messages []TermUiChatItem, current_stream string, width int, max_lines int) []TermUiRenderLine {
	mut lines := []TermUiRenderLine{}
	now_str := time.now().custom_format('HH:mm:ss')
	for item in messages {
		label := '[${role_label(item.role)} ${item.timestamp}]'
		lines << TermUiRenderLine{
			text:  label
			color: role_color(item.role)
		}
		for wrapped in wrap_text(item.text, width, max_lines) {
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
			text:  '[BOT ${now_str}]'
			color: 'cyan'
		}
		for wrapped in wrap_text(current_stream, width, max_lines) {
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

// apply_color sets the foreground color on the context.
fn apply_color(mut ctx tui.Context, color string) {
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

// frame renders the terminal UI.
fn frame(x voidptr) {
	mut app := unsafe { &TermUiApp(x) }
	app.ctx.clear()
	width, height := app.ctx.window_width, app.ctx.window_height
	sidebar_width := if app.show_sidebar && width >= 110 { 36 } else { 0 }
	chat_width := if sidebar_width > 0 { width - sidebar_width - 4 } else { width - 2 }
	chat_height := height - 5

	app.ctx.set_bg_color(r: 18, g: 58, b: 96)
	mut title := ' MiniMax Term UI'
	if app.is_loading {
		title += ' | busy'
	}
	app.ctx.draw_text(1, 1, truncate_by_width(title, width - 2))
	if title.len < width {
		app.ctx.draw_text(truncate_by_width(title, width - 2).len + 1, 1, ' '.repeat(width))
	}
	app.ctx.reset()

	chat_lines := build_chat_lines(app.messages, app.current_stream, chat_width - 2, chat_height)
	mut row := 3
	for line in chat_lines {
		if row > chat_height + 1 {
			break
		}
		apply_color(mut app.ctx, line.color)
		app.ctx.draw_text(2, row, truncate_by_width(line.text, chat_width - 2))
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

		apply_color(mut app.ctx, 'yellow')
		app.ctx.draw_text(sidebar_x, 3, 'Status')
		app.ctx.reset()
		status_text := if app.status_line.len > 0 { app.status_line } else { 'Idle' }
		for idx, line in wrap_text(status_text, sidebar_width - 2, 3) {
			app.ctx.draw_text(sidebar_x, 4 + idx, line)
		}

		apply_color(mut app.ctx, 'yellow')
		app.ctx.draw_text(sidebar_x, 8, 'Thinking')
		app.ctx.reset()
		thinking_text := if app.current_thinking.len > 0 { app.current_thinking } else { '(none)' }
		for idx, line in wrap_text(thinking_text, sidebar_width - 2, 6) {
			app.ctx.draw_text(sidebar_x, 9 + idx, line)
		}

		apply_color(mut app.ctx, 'yellow')
		app.ctx.draw_text(sidebar_x, 16, 'Activity')
		app.ctx.reset()
		activity := if app.activity_log.len > 10 {
			app.activity_log[app.activity_log.len - 10..]
		} else {
			app.activity_log
		}
		mut activity_row := 17
		for item in activity {
			for _, line in wrap_text(item, sidebar_width - 2, 2) {
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

	input_label := 'you > '
	input_width := if sidebar_width > 0 {
		chat_width - input_label.len - 2
	} else {
		width - input_label.len - 4
	}
	apply_color(mut app.ctx, 'green')
	input_text := tail_by_width(app.input.string(), input_width)
	app.ctx.draw_text(2, height - 1, input_label + input_text)
	app.ctx.reset()

	footer := '[Enter] send  [Ctrl+L] clear  [Ctrl+D] sidebar  [Esc] quit'
	app.ctx.set_color(r: 140, g: 140, b: 140)
	app.ctx.draw_text(2, height, truncate_by_width(footer, width - 2))
	app.ctx.reset()
	app.ctx.show_cursor()
	app.ctx.set_cursor_position(2 + visual_width(input_label) + visual_width(input_text),
		height - 1)
	app.ctx.flush()
}

// event handles keyboard input events.
fn event(e &tui.Event, x voidptr) {
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
				app.add_activity('Chat cleared')
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

// submit_input processes the current input line.
fn (mut app TermUiApp) submit_input() {
	if app.is_loading {
		return
	}
	prompt := app.input.string().trim_space()
	app.input = []rune{}
	if prompt.len == 0 {
		return
	}
	app.push_message('user', prompt)
	app.current_stream = ''
	app.current_thinking = ''
	app.set_status('Waiting...')
	app.is_loading = true
	app.add_activity('Processing: ${prompt}')
}

// finish_prompt finalizes the prompt response.
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
	app.set_status('')
	app.is_loading = false
	app.add_activity('Response complete')
}

// start_term_ui initializes and runs the terminal UI.
pub fn start_term_ui(mut app_ctx AppContext) {
	mut app := &TermUiApp{
		app_ctx:      app_ctx
		show_sidebar: true
	}

	app.ctx = tui.init(
		user_data:      app
		event_fn:       event
		frame_fn:       frame
		frame_rate:     20
		hide_cursor:    false
		capture_events: true
		window_title:   'MiniMax Term UI'
	)

	app.add_activity('Terminal UI started')

	app.ctx.run() or { eprintln('term-ui error: ${err}') }
}
