module main

fn test_term_ui_truncate_by_width_handles_cjk() {
	assert term_ui_truncate_by_width('你好abc', 4) == '你好'
	assert term_ui_truncate_by_width('hello', 3) == 'hel'
}

fn test_term_ui_visual_width_handles_cjk() {
	assert term_ui_visual_width('你好abc') == 7
	assert term_ui_visual_width('hello') == 5
}

fn test_term_ui_tail_by_width_keeps_input_end_visible() {
	assert term_ui_tail_by_width('hello world', 5) == 'world'
	assert term_ui_tail_by_width('ab你好cd', 6) == '你好cd'
}

fn test_term_ui_wrap_text_respects_width_and_line_limit() {
	wrapped := term_ui_wrap_text('hello world', 5, 3)
	assert wrapped.len == 3
	assert wrapped[0] == 'hello'
	assert wrapped[1] == ' worl'
	assert wrapped[2] == 'd'
}

fn test_term_ui_build_chat_lines_appends_stream() {
	messages := [
		TermUiChatItem{
			role:      'user'
			text:      '你好'
			timestamp: '10:00:00'
		},
	]
	lines := term_ui_build_chat_lines(messages, 'streaming', 20, 10)
	assert lines.len >= 4
	assert lines[0].text.contains('[YOU 10:00:00]')
	assert lines[1].text == '你好'
	assert lines[lines.len - 2].text.contains('[BOT ')
	assert lines[lines.len - 1].text == 'streaming'
}
