module main

import os
import readline
import term
import term.termios

fn should_use_basic_interactive_input(user_os string) bool {
	return match user_os {
		'windows', 'macos' { true }
		else { false }
	}
}

fn basic_input_visual_width_char(r rune) int {
	return if r > 127 { 2 } else { 1 }
}

fn basic_input_visual_width_runes(runes []rune) int {
	mut width := 0
	for r in runes {
		width += basic_input_visual_width_char(r)
	}
	return width
}

fn insert_rune_at_cursor(buffer []rune, cursor int, ch rune) ([]rune, int) {
	mut updated := buffer.clone()
	mut safe_cursor := cursor
	if safe_cursor < 0 {
		safe_cursor = 0
	} else if safe_cursor > updated.len {
		safe_cursor = updated.len
	}
	updated.insert(safe_cursor, ch)
	return updated, safe_cursor + 1
}

fn backspace_rune_at_cursor(buffer []rune, cursor int) ([]rune, int) {
	if cursor <= 0 || buffer.len == 0 {
		return buffer.clone(), if cursor < 0 {
			0
		} else {
			cursor
		}
	}
	mut updated := buffer.clone()
	updated.delete(cursor - 1)
	return updated, cursor - 1
}

fn delete_rune_at_cursor(buffer []rune, cursor int) ([]rune, int) {
	if cursor < 0 || cursor >= buffer.len || buffer.len == 0 {
		return buffer.clone(), if cursor < 0 {
			0
		} else {
			cursor
		}
	}
	mut updated := buffer.clone()
	updated.delete(cursor)
	return updated, cursor
}

fn redraw_basic_input_line(prompt string, buffer []rune, cursor int) {
	print('\r\x1b[2K${prompt}${buffer.string()}')
	suffix_width := if cursor >= 0 && cursor <= buffer.len {
		basic_input_visual_width_runes(buffer[cursor..])
	} else {
		0
	}
	if suffix_width > 0 {
		print('\x1b[${suffix_width}D')
	}
	flush_stdout()
}

fn handle_macos_escape_sequence(mut buffer []rune, cursor int, prompt string) int {
	mut next_cursor := cursor
	lead := input_character()
	if lead != `[` {
		return next_cursor
	}
	code := input_character()
	if code < 0 {
		return next_cursor
	}
	match u8(code) {
		`D` {
			if next_cursor > 0 {
				next_cursor--
				redraw_basic_input_line(prompt, buffer, next_cursor)
			}
		}
		`C` {
			if next_cursor < buffer.len {
				next_cursor++
				redraw_basic_input_line(prompt, buffer, next_cursor)
			}
		}
		`3` {
			tail := input_character()
			if u8(tail) == `~` {
				buffer, next_cursor = delete_rune_at_cursor(buffer, next_cursor)
				redraw_basic_input_line(prompt, buffer, next_cursor)
			}
		}
		else {}
	}

	return next_cursor
}

fn read_macos_interactive_input(prompt string) ?string {
	$if !macos && !linux {
		return os.input(prompt)
	}

	$if macos || linux {
		mut old_state := termios.Termios{}
		if termios.tcgetattr(0, mut old_state) != 0 {
			return os.input(prompt)
		}
		defer {
			termios.tcsetattr(0, C.TCSANOW, mut old_state)
		}

		mut state := old_state
		state.c_lflag &= termios.invert(termios.flag(C.ICANON) | termios.flag(C.ECHO))
		if termios.tcsetattr(0, C.TCSANOW, mut state) != 0 {
			return os.input(prompt)
		}

		mut buffer := []rune{}
		mut cursor := 0
		print(prompt)
		flush_stdout()

		for {
			ch := term.utf8_getchar() or {
				print('\n')
				return none
			}
			match ch {
				`\r`, `\n` {
					print('\n')
					return buffer.string()
				}
				27 {
					cursor = handle_macos_escape_sequence(mut buffer, cursor, prompt)
				}
				127, 8 {
					if cursor > 0 {
						buffer, cursor = backspace_rune_at_cursor(buffer, cursor)
						redraw_basic_input_line(prompt, buffer, cursor)
					}
				}
				4 {
					if buffer.len == 0 {
						print('\n')
						return none
					}
				}
				else {
					if ch >= 32 {
						buffer, cursor = insert_rune_at_cursor(buffer, cursor, ch)
						redraw_basic_input_line(prompt, buffer, cursor)
					}
				}
			}
		}
	}
	return none
}

fn read_interactive_input(mut rl readline.Readline, prompt string) ?string {
	// readline 在 Windows/macOS 终端下对中文输入法和部分宽字符光标定位不稳定，回退到 os.input 提升兼容性
	if should_use_basic_interactive_input(os.user_os()) {
		if os.user_os() == 'macos' {
			return read_macos_interactive_input(prompt)
		}
		return os.input(prompt)
	}
	return rl.read_line(strip_ansi_escape_sequences(prompt)) or { return none }
}

fn strip_ansi_escape_sequences(input string) string {
	mut out := []u8{cap: input.len}
	mut idx := 0
	for idx < input.len {
		if input[idx] == `\x1b` && idx + 1 < input.len && input[idx + 1] == `[` {
			idx += 2
			for idx < input.len {
				ch := input[idx]
				if (ch >= `A` && ch <= `Z`) || (ch >= `a` && ch <= `z`) {
					idx++
					break
				}
				idx++
			}
			continue
		}
		out << input[idx]
		idx++
	}
	return out.bytestr()
}
