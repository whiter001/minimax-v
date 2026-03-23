module main

import net.http
import net.smtp
import os
import strings
import time

const understand_image_downsample_threshold_bytes = i64(1200000)
const understand_image_downsample_max_dimension = 1600
const minimax_image_generation_api_url = 'https://api.minimaxi.com/v1/image_generation'
const image_generation_prompt_max_chars = 1500
const image_generation_supported_models = ['image-01', 'image-01-live']
const image_generation_supported_response_formats = ['url', 'base64']
const image_generation_supported_aspect_ratios = ['1:1', '16:9', '4:3', '3:2', '2:3', '3:4', '9:16',
	'21:9']

__global bash_session = BashSession{}
__global allow_desktop_control = false
__global allow_screen_capture = false

pub struct ToolDefinition {
pub mut:
	name        string
	description string
}

fn set_tool_capabilities(enable_desktop_control bool, enable_screen_capture bool) {
	allow_desktop_control = enable_desktop_control
	allow_screen_capture = enable_screen_capture
}

// --- Windows Reserved Name Check ---

fn is_windows_reserved_name(path string) bool {
	// Reference: https://learn.microsoft.com/en-us/windows/win32/fileio/naming-a-file
	base := os.file_name(path).to_upper().split('.')[0]
	reserved := ['CON', 'PRN', 'AUX', 'NUL', 'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7',
		'COM8', 'COM9', 'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9']
	return base in reserved
}

// --- Persistent Bash Session ---
// Maintains working directory and environment state across tool calls

struct BashSession {
mut:
	cwd     string
	env     map[string]string
	timeout int // seconds
}

fn new_bash_session(workspace string) BashSession {
	initial_cwd := if workspace.len > 0 && os.is_dir(workspace) { workspace } else { os.getwd() }
	return BashSession{
		cwd:     initial_cwd
		env:     {}
		timeout: 120
	}
}

fn find_bash_path() string {
	// Try to find bash in common locations
	possible_paths := [
		'bash', // Already in PATH
		'C:\\Program Files\\Git\\bin\\bash.exe',
		'C:\\Program Files (x86)\\Git\\bin\\bash.exe',
		'D:\\Program Files\\Git\\bin\\bash.exe',
		'/usr/bin/bash',
		'/bin/bash',
	]

	for path in possible_paths {
		if os.exists(path) {
			return path
		}
		// Try to execute to see if it's in PATH
		if path == 'bash' {
			result := os.execute('bash --version')
			if result.exit_code == 0 {
				return 'bash'
			}
		}
	}
	return ''
}

fn find_pwsh_path() string {
	possible_paths := [
		'pwsh',
		'C:\\Program Files\\PowerShell\\7\\pwsh.exe',
		'C:\\Program Files\\PowerShell\\7-preview\\pwsh.exe',
	]
	for path in possible_paths {
		if os.exists(path) {
			return path
		}
		if path == 'pwsh' {
			result := os.execute('pwsh -Version')
			if result.exit_code == 0 {
				return 'pwsh'
			}
		}
	}
	return ''
}

fn should_use_windows_direct_command(command string) bool {
	if os.user_os() != 'windows' {
		return false
	}
	head := extract_tool_command_head(command).to_lower()
	return head in ['pueue', 'pueue.exe', 'pwsh', 'pwsh.exe', 'nu', 'nu.exe']
		|| head.ends_with('\\pueue.exe') || head.ends_with('/pueue.exe')
		|| head.ends_with('\\pwsh.exe') || head.ends_with('/pwsh.exe') || head.ends_with('\\nu.exe')
		|| head.ends_with('/nu.exe')
}

fn escape_powershell_single_quoted(s string) string {
	return s.replace("'", "''")
}

fn extract_pwsh_cwd(output string) (string, string) {
	if cwd_idx := output.index('__PWSH_CWD__=') {
		cwd_line := output[cwd_idx + 13..]
		newline_idx := cwd_line.index('\n') or { cwd_line.len }
		new_cwd := cwd_line[..newline_idx].trim_space()
		clean_output := output[..cwd_idx].trim_right('\n ')
		return new_cwd, clean_output
	}
	return '', output
}

fn (mut s BashSession) execute_with_windows_pwsh(command string) string {
	pwsh_path := find_pwsh_path()
	if pwsh_path.len == 0 {
		return ''
	}
	actual_pwsh := if pwsh_path == 'pwsh' {
		os.find_abs_path_of_executable('pwsh') or { 'pwsh' }
	} else {
		pwsh_path
	}
	ts := time.now().unix_milli()
	tmp_ps := os.join_path(os.temp_dir(), 'minimax_bash_pwsh_${ts}.ps1')
	mut lines := [
		"Set-Location -LiteralPath '${escape_powershell_single_quoted(s.cwd)}'",
	]
	for key, val in s.env {
		lines << r'$env:' + key + " = '${escape_powershell_single_quoted(val)}'"
	}
	lines << command
	lines << 'Write-Output "__PWSH_CWD__=$((Get-Location).Path)"'
	os.write_file(tmp_ps, lines.join('\n')) or {
		return 'Error: 无法写入临时 PowerShell 脚本: ${err}'
	}
	defer {
		os.rm(tmp_ps) or {}
	}
	result := os.execute('"${actual_pwsh}" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "${tmp_ps}"')
	mut output := result.output
	exit_code := result.exit_code

	new_cwd, clean_output := extract_pwsh_cwd(output)
	if new_cwd.len > 0 && os.is_dir(new_cwd) {
		s.cwd = new_cwd
	}
	if exit_code != 0 {
		return 'Exit code: ${exit_code}\n[cwd: ${s.cwd}]\n${clean_output}'
	}
	return '${clean_output}\n[cwd: ${s.cwd}]'
}

fn (mut s BashSession) execute(command string) string {
	if command.len == 0 {
		return 'Error: command is required'
	}

	// Windows-specific dangerous commands
	windows_dangerous := ['rmdir /s /q', 'del /s /q', 'format', 'cipher /w', 'cipher.exe /w']
	// Universal dangerous commands
	dangerous := ['rm -rf', 'rm /', 'mkfs', 'dd if=', ':(){:|:&};:', 'chmod -R 777 /',
		'chmod -R 000 /', '> /dev/sda', 'mv /* ', 'mv / ']

	for d in dangerous {
		if command.contains(d) {
			return 'Error: ⚠️  拒绝执行危险命令'
		}
	}
	for d in windows_dangerous {
		if command.contains(d) {
			return 'Error: ⚠️  拒绝执行危险命令'
		}
	}

	// Windows reserved name check for redirects (e.g. > nul, > con)
	u_cmd := command.to_upper()
	if u_cmd.contains('> NUL') || u_cmd.contains('> CON') || u_cmd.contains('> PRN')
		|| u_cmd.contains('> AUX') || u_cmd.contains('>> NUL') || u_cmd.contains('>> CON')
		|| u_cmd.contains('>> PRN') || u_cmd.contains('>> AUX') {
		return 'Error: ⚠️ 禁止重定向到 Windows 保留设备 (NUL, CON, PRN, AUX)'
	}

	if should_use_windows_direct_command(command) {
		result := s.execute_with_windows_pwsh(command)
		if result.len > 0 {
			return result
		}
	}

	// Find bash if available
	bash_path := find_bash_path()
	use_bash := bash_path.len > 0

	if use_bash {
		// Use os.Process (not os.execute) to avoid Windows restrictions on &&, ;, ||
		// set_work_folder handles cwd without needing cd && chaining
		mut env_exports := ''
		for key, val in s.env {
			escaped_val := val.replace("'", "'\\''")
			env_exports += "export ${key}='${escaped_val}'; "
		}

		// Append cwd tracker so we can update s.cwd if the command uses cd
		full_cmd := env_exports + command + '; echo __CWD_MARKER__=$(pwd)'
		bash_c_arg := if os.user_os() == 'windows' { full_cmd.replace('"', '\\"') } else { full_cmd }

		// Resolve full path when bash is only 'bash' (in PATH), since os.Process needs full path on Windows
		actual_bash := if bash_path == 'bash' {
			os.find_abs_path_of_executable('bash') or { 'bash' }
		} else {
			bash_path
		}
		mut p := os.new_process(actual_bash)
		p.set_args(['-c', bash_c_arg])
		p.set_work_folder(s.cwd)
		p.use_stdio_ctl = true
		p.run()
		mut output := p.stdout_slurp()
		output += p.stderr_slurp()
		p.wait()
		exit_code := p.code
		p.close()

		// Extract and update cwd from marker
		if cwd_idx := output.index('__CWD_MARKER__=') {
			cwd_line := output[cwd_idx + 15..]
			newline_idx := cwd_line.index('\n') or { cwd_line.len }
			new_cwd_raw := cwd_line[..newline_idx].trim_space()
			// Convert bash /d/path to Windows D:\path if needed
			new_cwd := if new_cwd_raw.starts_with('/') && new_cwd_raw.len >= 3
				&& new_cwd_raw[2] == `/` {
				new_cwd_raw[1..2].to_upper() + ':' + new_cwd_raw[2..].replace('/', '\\')
			} else {
				new_cwd_raw
			}
			if new_cwd.len > 0 && os.is_dir(new_cwd) {
				s.cwd = new_cwd
			}
			output = output[..cwd_idx].trim_right('\n ')
		}

		if exit_code != 0 {
			return 'Exit code: ${exit_code}\n[cwd: ${s.cwd}]\n${output}'
		}
		return '${output}\n[cwd: ${s.cwd}]'
	} else {
		// Fallback: Windows cmd.exe
		mut parts := []string{}
		parts << 'cd /d "${s.cwd}"'
		for key, val in s.env {
			parts << 'set ${key}=${val}'
		}
		parts << command
		parts << 'echo __CMD_CWD__=%cd%'
		full_cmd := parts.join(' & ')

		result := os.execute('cmd /c ${shell_escape_windows(full_cmd)}')
		mut output := result.output

		// Extract new cwd from output
		if cwd_idx := output.index('__CMD_CWD__=') {
			cwd_line := output[cwd_idx + 12..]
			newline_idx := cwd_line.index('\n') or { cwd_line.len }
			new_cwd := cwd_line[..newline_idx].trim_space()
			if new_cwd.len > 0 && os.is_dir(new_cwd) {
				s.cwd = new_cwd
			}
			output = output[..cwd_idx].trim_right('\n ')
		}

		if result.exit_code != 0 {
			return 'Exit code: ${result.exit_code}\n[cwd: ${s.cwd}]\n${output}'
		}
		return '${output}\n[cwd: ${s.cwd}]'
	}
}

fn shell_escape(s string) string {
	// Wrap in single quotes and escape any internal single quotes
	return "'" + s.replace("'", "'\\''") + "'"
}

fn shell_escape_windows(s string) string {
	// Windows cmd.exe escaping: use double quotes and escape special chars
	return '"' + s.replace('"', '""') + '"'
}

fn parse_bool_input(input map[string]string, key string, default_value bool) bool {
	val := (input[key] or { '' }).trim_space().to_lower()
	if val.len == 0 {
		return default_value
	}
	return val in ['true', '1', 'yes', 'on']
}

fn parse_int_input(input map[string]string, key string, default_value int) int {
	val := (input[key] or { '' }).trim_space()
	if val.len == 0 {
		return default_value
	}
	return val.int()
}

fn escape_powershell_double_quoted(s string) string {
	return s.replace('`', '``').replace('"', '`"').replace('$', '`$')
}

fn escape_windows_sendkeys_literal(s string) string {
	mut out := strings.new_builder(s.len * 2)
	for ch in s.runes() {
		match ch {
			`{` { out.write_string('{{}') }
			`}` { out.write_string('{}}') }
			`+` { out.write_string('{+}') }
			`^` { out.write_string('{^}') }
			`%` { out.write_string('{%}') }
			`~` { out.write_string('{~}') }
			`(` { out.write_string('{(}') }
			`)` { out.write_string('{)}') }
			`[` { out.write_string('{[}') }
			`]` { out.write_string('{]}') }
			else { out.write_rune(ch) }
		}
	}
	return out.str()
}

fn escape_applescript_string(s string) string {
	return s.replace('\\', '\\\\').replace('"', '\\"')
}

fn build_macos_screencapture_command(output_path string, x int, y int, width int, height int) string {
	mut parts := ['screencapture', '-x']
	if width > 0 && height > 0 {
		parts << '-R${x},${y},${width},${height}'
	}
	parts << shell_escape(output_path)
	return parts.join(' ')
}

fn run_powershell_script(script string) !string {
	if os.user_os() != 'windows' {
		return error('当前仅支持 Windows 平台')
	}
	ts := time.now().unix_milli()
	tmp_ps := os.join_path(os.temp_dir(), 'minimax_tool_${ts}.ps1')
	os.write_file(tmp_ps, script) or {
		return error('无法写入临时 PowerShell 脚本: ${err}')
	}
	defer {
		os.rm(tmp_ps) or {}
	}
	result := os.execute('pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "${tmp_ps}"')
	if result.exit_code != 0 {
		return error('PowerShell 执行失败 (exit ${result.exit_code}): ${result.output}')
	}
	return result.output.trim_space()
}

fn run_macos_applescript(script string) !string {
	if os.user_os() != 'macos' {
		return error('当前仅支持 macOS 平台')
	}
	ts := time.now().unix_milli()
	tmp_scpt := os.join_path(os.temp_dir(), 'minimax_tool_${ts}.applescript')
	os.write_file(tmp_scpt, script) or {
		return error('无法写入临时 AppleScript 脚本: ${err}')
	}
	defer {
		os.rm(tmp_scpt) or {}
	}
	result := os.execute('osascript ${shell_escape(tmp_scpt)}')
	if result.exit_code != 0 {
		return error('AppleScript 执行失败，请检查辅助功能权限: ${result.output}')
	}
	return result.output.trim_space()
}

fn run_macos_swift_script(script string) !string {
	if os.user_os() != 'macos' {
		return error('当前仅支持 macOS 平台')
	}
	ts := time.now().unix_milli()
	tmp_swift := os.join_path(os.temp_dir(), 'minimax_tool_${ts}.swift')
	os.write_file(tmp_swift, script) or { return error('无法写入临时 Swift 脚本: ${err}') }
	defer {
		os.rm(tmp_swift) or {}
	}
	result := os.execute('xcrun swift ${shell_escape(tmp_swift)}')
	if result.exit_code != 0 {
		return error('Swift 执行失败，请检查辅助功能权限与开发工具链: ${result.output}')
	}
	return result.output.trim_space()
}

struct MacKeySend {
	modifiers []string
	keystroke string
	key_code  int = -1
}

struct DoctorCheck {
	name   string
	status string
	detail string
}

fn doctor_status_icon(status string) string {
	return match status {
		'ok' { '✅' }
		'warn' { '⚠️' }
		'fail' { '❌' }
		else { 'ℹ️' }
	}
}

fn build_doctor_report(title string, checks []DoctorCheck, notes []string) string {
	mut lines := ['🩺 ${title}']
	for check in checks {
		lines << '  ${doctor_status_icon(check.status)} ${check.name}: ${check.detail}'
	}
	if notes.len > 0 {
		lines << ''
		lines << '建议:'
		for note in notes {
			lines << '  - ${note}'
		}
	}
	return lines.join('\n')
}

fn command_available(cmd string) bool {
	return os.find_abs_path_of_executable(cmd) or { '' } != ''
}

fn macos_accessibility_doctor_check() DoctorCheck {
	if os.user_os() != 'macos' {
		return DoctorCheck{'辅助功能权限', 'info', '仅在 macOS 上检查'}
	}
	if !command_available('xcrun') {
		return DoctorCheck{'辅助功能权限', 'fail', '缺少 xcrun，无法执行 Quartz 权限检测'}
	}
	result := run_macos_swift_script('import ApplicationServices\nprint(AXIsProcessTrusted() ? "trusted" : "untrusted")') or {
		return DoctorCheck{'辅助功能权限', 'warn', err.msg()}
	}
	return if result.trim_space() == 'trusted' {
		DoctorCheck{'辅助功能权限', 'ok', '已授予'}
	} else {
		DoctorCheck{'辅助功能权限', 'warn', '未授予或尚未确认'}
	}
}

// --- Mail Tool ---

fn send_mail_tool(config Config, mailserver string, mailport int, username string, password string, from string, to string, subject string, body string) string {
	// Use config defaults when tool parameters are empty
	final_server := if mailserver.len > 0 { mailserver } else { config.smtp_server }
	final_port := if mailport > 0 { mailport } else { config.smtp_port }
	final_username := if username.len > 0 { username } else { config.smtp_username }
	final_password := if password.len > 0 { password } else { config.smtp_password }
	final_from := if from.len > 0 {
		from
	} else if config.smtp_from.len > 0 {
		config.smtp_from
	} else {
		final_username
	}
	final_to := if to.len > 0 { to } else { config.smtp_to }

	if final_server.len == 0 {
		return 'Error: smtp server is required (set via MINIMAX_SMTP_SERVER or tool parameter)'
	}
	if final_username.len == 0 {
		return 'Error: smtp username is required (set via MINIMAX_SMTP_USERNAME or tool parameter)'
	}
	if final_password.len == 0 {
		return 'Error: smtp password is required (set via MINIMAX_SMTP_PASSWORD or tool parameter)'
	}
	if final_from.len == 0 {
		return 'Error: smtp from address is required (set via MINIMAX_SMTP_FROM or tool parameter)'
	}
	if final_to.len == 0 {
		return 'Error: recipient (to) is required (set via MINIMAX_SMTP_TO or tool parameter)'
	}
	if subject.len == 0 {
		return 'Error: subject is required'
	}
	if body.len == 0 {
		return 'Error: body is required'
	}
	if final_from.contains('\r') || final_from.contains('\n') || final_to.contains('\r')
		|| final_to.contains('\n') || subject.contains('\r') || subject.contains('\n') {
		return 'Error: email headers must not contain CR/LF characters'
	}
	// Port 465 uses implicit SSL, port 587 uses STARTTLS
	use_ssl := final_port == 465
	client_cfg := smtp.Client{
		server:   final_server
		from:     final_from
		port:     final_port
		username: final_username
		password: final_password
		ssl:      use_ssl
	}
	send_cfg := smtp.Mail{
		to:        final_to
		subject:   subject
		body_type: .html
		body:      body
	}
	mut client := smtp.new_client(client_cfg) or {
		return 'Error: failed to connect to mail server: ${err.msg()}'
	}
	client.send(send_cfg) or { return 'Error: failed to send mail: ${err.msg()}' }
	return 'Mail sent successfully to ${final_to}'
}

fn build_image_generation_request_json(input map[string]string) !string {
	prompt := (input['prompt'] or { '' }).trim_space()
	if prompt.len == 0 {
		return error('prompt is required')
	}
	if prompt.len > image_generation_prompt_max_chars {
		return error('prompt must be at most ${image_generation_prompt_max_chars} characters')
	}

	model := (input['model'] or { 'image-01' }).trim_space()
	if model !in image_generation_supported_models {
		return error('unsupported model "${model}". Use image-01 or image-01-live')
	}

	aspect_ratio := (input['aspect_ratio'] or { '' }).trim_space()
	if aspect_ratio.len > 0 && aspect_ratio !in image_generation_supported_aspect_ratios {
		return error('unsupported aspect_ratio "${aspect_ratio}"')
	}
	if model == 'image-01-live' && aspect_ratio == '21:9' {
		return error('aspect_ratio 21:9 is only supported by image-01')
	}

	response_format := (input['response_format'] or { 'url' }).trim_space().to_lower()
	if response_format !in image_generation_supported_response_formats {
		return error('unsupported response_format "${response_format}"')
	}

	n_raw := (input['n'] or { '' }).trim_space()
	if n_raw.len > 0 && !is_integer_string(n_raw) {
		return error('n must be an integer')
	}
	n := parse_int_input(input, 'n', 1)
	if n < 1 || n > 9 {
		return error('n must be between 1 and 9')
	}

	seed_raw := (input['seed'] or { '' }).trim_space()
	if seed_raw.len > 0 && !is_integer_string(seed_raw) {
		return error('seed must be an integer')
	}

	width_raw := (input['width'] or { '' }).trim_space()
	if width_raw.len > 0 && !is_integer_string(width_raw) {
		return error('width must be an integer')
	}
	height_raw := (input['height'] or { '' }).trim_space()
	if height_raw.len > 0 && !is_integer_string(height_raw) {
		return error('height must be an integer')
	}
	width := parse_int_input(input, 'width', 0)
	height := parse_int_input(input, 'height', 0)
	if model == 'image-01-live' && (width > 0 || height > 0) {
		return error('width and height are only supported by image-01')
	}
	if (width > 0 || height > 0) && (width <= 0 || height <= 0) {
		return error('width and height must be set together')
	}
	if width > 0 && height > 0 {
		if width < 512 || width > 2048 || height < 512 || height > 2048 {
			return error('width and height must be between 512 and 2048')
		}
		if width % 8 != 0 || height % 8 != 0 {
			return error('width and height must be multiples of 8')
		}
	}

	prompt_optimizer := parse_bool_input(input, 'prompt_optimizer', false)
	aigc_watermark := parse_bool_input(input, 'aigc_watermark', false)
	style := (input['style'] or { '' }).trim_space()
	if style.len > 0 && model != 'image-01-live' {
		return error('style is only supported by image-01-live')
	}

	mut body_parts := []string{}
	body_parts << '"model":${detect_jq_value(model)}'
	body_parts << '"prompt":${detect_jq_value(prompt)}'
	body_parts << '"response_format":${detect_jq_value(response_format)}'
	body_parts << '"n":${n}'
	body_parts << '"prompt_optimizer":${if prompt_optimizer { 'true' } else { 'false' }}'
	body_parts << '"aigc_watermark":${if aigc_watermark { 'true' } else { 'false' }}'
	if aspect_ratio.len > 0 {
		body_parts << '"aspect_ratio":${detect_jq_value(aspect_ratio)}'
	}
	if width > 0 && height > 0 {
		body_parts << '"width":${width}'
		body_parts << '"height":${height}'
	}
	if seed_raw.len > 0 {
		body_parts << '"seed":${detect_jq_value(seed_raw)}'
	}
	if style.len > 0 {
		body_parts << '"style":${detect_jq_value(style)}'
	}

	return '{' + body_parts.join(',') + '}'
}

fn image_generation_tool(config Config, input map[string]string) string {
	if config.api_key.trim_space().len == 0 {
		return 'Error: image generation requires an API key'
	}

	request_body := build_image_generation_request_json(input) or { return 'Error: ${err.msg()}' }

	mut headers := http.new_header()
	headers.add(.authorization, 'Bearer ${config.api_key}')
	headers.add(.content_type, 'application/json')
	headers.add(.connection, 'close')
	mut req := http.Request{
		method:        .post
		url:           minimax_image_generation_api_url
		header:        headers
		data:          request_body
		read_timeout:  180 * time.second
		write_timeout: 60 * time.second
	}
	response := req.do() or { return 'Error: image generation request failed: ${err}' }
	if response.status_code != 200 {
		return 'Error: image generation API ${response.status_code}: ${response.body}'
	}
	return summarize_image_generation_response(response.body)
}

fn extract_all_json_string_values(json_str string, key string) []string {
	mut values := []string{}
	mut search_pos := 0
	pattern := '"${key}"'
	for search_pos < json_str.len {
		remaining := json_str[search_pos..]
		if idx := remaining.index(pattern) {
			abs_pos := search_pos + idx
			mut p := abs_pos + pattern.len
			for p < json_str.len && json_str[p] in [u8(` `), `\t`, `\n`, `\r`] {
				p++
			}
			if p >= json_str.len || json_str[p] != `:` {
				search_pos = abs_pos + pattern.len
				continue
			}
			p++
			for p < json_str.len && json_str[p] in [u8(` `), `\t`, `\n`, `\r`] {
				p++
			}
			if p >= json_str.len || json_str[p] != `"` {
				search_pos = p
				continue
			}
			p++
			end := find_json_string_terminator(json_str, p)
			if end > p {
				values << decode_json_string(json_str[p..end])
				search_pos = end + 1
				continue
			}
			search_pos = p
		} else {
			break
		}
	}
	return values
}

fn summarize_image_generation_response(body string) string {
	trimmed := body.trim_space()
	if trimmed.len == 0 {
		return 'Error: empty image generation response'
	}
	mut lines := ['🖼️ 文生图请求已完成']
	task_id := extract_json_string_value(body, 'id')
	if task_id.len > 0 {
		lines << 'task_id: ${task_id}'
	}
	urls := extract_all_json_string_values(body, 'url')
	if urls.len > 0 {
		lines << 'urls:'
		for url in urls {
			lines << '- ${url}'
		}
	}
	image_urls := extract_all_json_string_values(body, 'image_url')
	if image_urls.len > 0 {
		lines << 'image_urls:'
		for url in image_urls {
			lines << '- ${url}'
		}
	}
	base64_images := extract_all_json_string_values(body, 'base64')
	if base64_images.len > 0 {
		lines << 'base64_images: ${base64_images.len}'
		for i, img in base64_images {
			lines << '- image ${i + 1}: ${img.len} chars'
		}
	}
	if lines.len == 1 {
		lines << 'raw_response:'
		lines << utf8_safe_truncate(trimmed, 4000)
	}
	return lines.join('\n')
}

fn is_integer_string(value string) bool {
	if value.len == 0 {
		return false
	}
	mut start := 0
	if value[0] == `-` {
		if value.len == 1 {
			return false
		}
		start = 1
	}
	for i in start .. value.len {
		if value[i] < `0` || value[i] > `9` {
			return false
		}
	}
	return true
}

fn macos_screen_recording_doctor_check() DoctorCheck {
	if os.user_os() != 'macos' {
		return DoctorCheck{'屏幕录制权限', 'info', '仅在 macOS 上检查'}
	}
	if !command_available('screencapture') {
		return DoctorCheck{'屏幕录制权限', 'fail', '缺少 screencapture 命令'}
	}
	tmp_png := os.join_path(os.temp_dir(), 'minimax_doctor_capture_${time.now().unix_milli()}.png')
	defer {
		os.rm(tmp_png) or {}
	}
	result := os.execute(build_macos_screencapture_command(tmp_png, 0, 0, 0, 0))
	if result.exit_code != 0 {
		return DoctorCheck{'屏幕录制权限', 'warn', '截图失败，请检查屏幕录制权限'}
	}
	if !os.exists(tmp_png) {
		return DoctorCheck{'屏幕录制权限', 'warn', '未生成截图文件，请检查屏幕录制权限'}
	}
	return DoctorCheck{'屏幕录制权限', 'ok', '截图命令可用'}
}

fn desktop_doctor_report() string {
	mut checks := []DoctorCheck{}
	checks << DoctorCheck{'当前平台', if os.user_os() == 'macos' { 'ok' } else { 'info' }, os.user_os()}
	checks << DoctorCheck{'enable_desktop_control', if allow_desktop_control { 'ok' } else { 'warn' }, if allow_desktop_control {
		'已开启'
	} else {
		'未开启'
	}}
	checks << DoctorCheck{'enable_screen_capture', if allow_screen_capture { 'ok' } else { 'warn' }, if allow_screen_capture {
		'已开启'
	} else {
		'未开启'
	}}
	checks << DoctorCheck{'osascript', if command_available('osascript') { 'ok' } else { 'fail' }, if command_available('osascript') {
		'可用'
	} else {
		'未找到'
	}}
	checks << DoctorCheck{'screencapture', if command_available('screencapture') {
		'ok'
	} else {
		'fail'
	}, if command_available('screencapture') {
		'可用'
	} else {
		'未找到'
	}}
	checks << DoctorCheck{'xcrun', if command_available('xcrun') { 'ok' } else { 'fail' }, if command_available('xcrun') {
		'可用'
	} else {
		'未找到'
	}}
	if os.user_os() == 'macos' {
		xcode_select := os.execute('xcode-select -p 2>/dev/null')
		checks << DoctorCheck{'Xcode Command Line Tools', if xcode_select.exit_code == 0 {
			'ok'
		} else {
			'warn'
		}, if xcode_select.exit_code == 0 {
			xcode_select.output.trim_space()
		} else {
			'未检测到'
		}}
		checks << macos_accessibility_doctor_check()
		checks << macos_screen_recording_doctor_check()
	}
	mut notes := []string{}
	if os.user_os() == 'macos' {
		notes << '系统设置 -> 隐私与安全性 -> 辅助功能：给当前终端或 minimax_cli 授权'
		notes << '系统设置 -> 隐私与安全性 -> 屏幕录制：给当前终端或 minimax_cli 授权'
		notes << '如缺少 xcrun，请执行 xcode-select --install 安装 Command Line Tools'
	}
	return build_doctor_report('桌面能力自检', checks, notes)
}

fn doctor_command_usage() string {
	return [
		'用法:',
		'  doctor',
		'  doctor desktop',
		'  doctor help',
		'  doctor test screen [path]',
		'  doctor test mouse move <x> <y>',
		'  doctor test mouse scroll <delta>',
		'  doctor test keyboard type <text>',
		'  doctor test keyboard send <keys>',
	].join('\n')
}

fn handle_doctor_command(input string) string {
	trimmed := input.trim_space()
	if trimmed == 'doctor' || trimmed == 'doctor desktop' {
		return desktop_doctor_report()
	}
	if trimmed == 'doctor help' {
		return doctor_command_usage()
	}
	if trimmed.starts_with('doctor test screen') {
		mut output_path := ''
		if trimmed.len > 'doctor test screen'.len {
			output_path = trimmed['doctor test screen'.len..].trim_space()
		}
		return capture_screen_tool(output_path, 0, 0, 0, 0)
	}
	if trimmed.starts_with('doctor test mouse move ') {
		args := trimmed['doctor test mouse move '.len..].split(' ').filter(it.trim_space().len > 0)
		if args.len != 2 {
			return '用法: doctor test mouse move <x> <y>'
		}
		return mouse_control_tool('move', args[0].int(), args[1].int(), 'left', 1, 120)
	}
	if trimmed.starts_with('doctor test mouse scroll ') {
		args := trimmed['doctor test mouse scroll '.len..].split(' ').filter(it.trim_space().len > 0)
		if args.len != 1 {
			return '用法: doctor test mouse scroll <delta>'
		}
		return mouse_control_tool('scroll', 0, 0, 'left', 1, args[0].int())
	}
	if trimmed == 'doctor test keyboard type' || trimmed.starts_with('doctor test keyboard type ') {
		text := if trimmed.len > 'doctor test keyboard type'.len {
			trimmed['doctor test keyboard type'.len..].trim_space()
		} else {
			''
		}
		if text.len == 0 {
			return '用法: doctor test keyboard type <text>'
		}
		return keyboard_control_tool('type', text, '')
	}
	if trimmed == 'doctor test keyboard send' || trimmed.starts_with('doctor test keyboard send ') {
		keys := if trimmed.len > 'doctor test keyboard send'.len {
			trimmed['doctor test keyboard send'.len..].trim_space()
		} else {
			''
		}
		if keys.len == 0 {
			return '用法: doctor test keyboard send <keys>'
		}
		return keyboard_control_tool('send', '', keys)
	}
	if trimmed.starts_with('doctor test ') {
		return doctor_command_usage()
	}
	return ''
}

fn normalize_macos_modifier(token string) !string {
	return match token.trim_space().to_lower() {
		'cmd', 'command' { 'command down' }
		'ctrl', 'control', '^' { 'control down' }
		'alt', 'option', '%' { 'option down' }
		'shift', '+' { 'shift down' }
		else { return error('unsupported modifier: ${token}') }
	}
}

fn macos_special_key_code(token string) !int {
	return match token.trim_space().to_upper() {
		'ENTER', 'RETURN' { 36 }
		'TAB' { 48 }
		'SPACE' { 49 }
		'ESC', 'ESCAPE' { 53 }
		'BACKSPACE', 'DELETE' { 51 }
		'UP' { 126 }
		'DOWN' { 125 }
		'LEFT' { 123 }
		'RIGHT' { 124 }
		else { return error('unsupported special key: ${token}') }
	}
}

fn unique_macos_modifiers(modifiers []string) []string {
	mut out := []string{}
	for modifier in modifiers {
		if modifier !in out {
			out << modifier
		}
	}
	return out
}

fn build_macos_key_send(target string, modifiers []string) !MacKeySend {
	trimmed := target.trim_space()
	if trimmed.len == 0 {
		return error('missing key target')
	}
	if trimmed.starts_with('{') && trimmed.ends_with('}') && trimmed.len > 2 {
		return MacKeySend{
			modifiers: unique_macos_modifiers(modifiers)
			key_code:  macos_special_key_code(trimmed[1..trimmed.len - 1])!
		}
	}
	if code := macos_special_key_code(trimmed) {
		return MacKeySend{
			modifiers: unique_macos_modifiers(modifiers)
			key_code:  code
		}
	}
	if trimmed.runes().len != 1 {
		return error('send action 仅支持单字符或特殊键')
	}
	return MacKeySend{
		modifiers: unique_macos_modifiers(modifiers)
		keystroke: trimmed
	}
}

fn parse_macos_send_keys(keys string) !MacKeySend {
	trimmed := keys.trim_space()
	if trimmed.len == 0 {
		return error('send action requires keys')
	}
	if trimmed.contains('+') && !trimmed.starts_with('^') && !trimmed.starts_with('%')
		&& !trimmed.starts_with('#') && !trimmed.starts_with('+') {
		parts := trimmed.split('+').map(it.trim_space()).filter(it.len > 0)
		if parts.len == 0 {
			return error('invalid key sequence')
		}
		mut modifiers := []string{}
		for idx, part in parts {
			if idx == parts.len - 1 {
				return build_macos_key_send(part, modifiers)
			}
			modifiers << normalize_macos_modifier(part)!
		}
	}
	mut modifiers := []string{}
	mut idx := 0
	for idx < trimmed.len {
		ch := trimmed[idx]
		if ch == `^` || ch == `%` || ch == `+` || ch == `#` {
			modifiers << normalize_macos_modifier(trimmed[idx..idx + 1])!
			idx++
			continue
		}
		break
	}
	return build_macos_key_send(trimmed[idx..], modifiers)
}

fn build_macos_keyboard_script(action string, text string, keys string) !string {
	if action == 'type' {
		return 'tell application "System Events" to keystroke "${escape_applescript_string(text)}"'
	}
	send := parse_macos_send_keys(keys)!
	mut command := if send.key_code >= 0 {
		'key code ${send.key_code}'
	} else {
		'keystroke "${escape_applescript_string(send.keystroke)}"'
	}
	if send.modifiers.len > 0 {
		command += ' using {' + send.modifiers.join(', ') + '}'
	}
	return 'tell application "System Events" to ${command}'
}

fn build_macos_mouse_swift_script(action string, x int, y int, button string, clicks int, delta int) string {
	mut script := r'
import ApplicationServices
import Foundation

if !AXIsProcessTrusted() {
	FileHandle.standardError.write(Data("Accessibility permission required".utf8))
	exit(1)
}

let action = "__ACTION__"
let buttonName = "__BUTTON__"
let x = Double(__X__)
let y = Double(__Y__)
let clicks = __CLICKS__
let delta = __DELTA__

func mouseButton(_ name: String) -> CGMouseButton {
	switch name {
	case "right": return .right
	case "middle": return .center
	default: return .left
	}
}

func mouseTypes(_ name: String) -> (CGEventType, CGEventType) {
	switch name {
	case "right": return (.rightMouseDown, .rightMouseUp)
	case "middle": return (.otherMouseDown, .otherMouseUp)
	default: return (.leftMouseDown, .leftMouseUp)
	}
}

let point = CGPoint(x: x, y: y)

if action == "move" {
	CGWarpMouseCursorPosition(point)
} else if action == "click" {
	if x >= 0 && y >= 0 {
		CGWarpMouseCursorPosition(point)
	}
	let button = mouseButton(buttonName)
	let types = mouseTypes(buttonName)
	for _ in 0..<clicks {
		if let down = CGEvent(mouseEventSource: nil, mouseType: types.0, mouseCursorPosition: point, mouseButton: button),
		   let up = CGEvent(mouseEventSource: nil, mouseType: types.1, mouseCursorPosition: point, mouseButton: button) {
			down.post(tap: .cghidEventTap)
			up.post(tap: .cghidEventTap)
		}
		usleep(10000)
	}
} else if action == "scroll" {
	if let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: Int32(delta), wheel2: 0, wheel3: 0) {
		event.post(tap: .cghidEventTap)
	}
}

print("ok")
'
	script = script.replace('__ACTION__', action)
	script = script.replace('__BUTTON__', button)
	script = script.replace('__X__', x.str())
	script = script.replace('__Y__', y.str())
	script = script.replace('__CLICKS__', clicks.str())
	script = script.replace('__DELTA__', delta.str())
	return script
}

fn (s BashSession) get_status() string {
	return 'Bash session: cwd=${s.cwd} env_vars=${s.env.len} timeout=${s.timeout}s'
}

fn read_file_tool(path string) !string {
	if path.len == 0 {
		return error('文件路径不能为空')
	}
	content := os.read_file(path)!
	return content
}

fn write_file_tool(path string, content string) !string {
	if path.len == 0 {
		return error('文件路径不能为空')
	}
	if is_windows_reserved_name(path) {
		return error('⚠️ 禁止写入 Windows 保留设备名 (如 CON, PRN, AUX, NUL, COM1-9, LPT1-9): ${path}')
	}
	os.write_file(path, content)!
	return '✅ 文件已写入: ${path} (${content.len} 字符)'
}

fn wildcard_match(pattern string, target string) bool {
	p := pattern.bytes()
	t := target.bytes()
	mut p_idx := 0
	mut t_idx := 0
	mut star_idx := -1
	mut match_idx := 0

	for t_idx < t.len {
		if p_idx < p.len && (p[p_idx] == `?` || p[p_idx] == t[t_idx]) {
			p_idx++
			t_idx++
			continue
		}
		if p_idx < p.len && p[p_idx] == `*` {
			star_idx = p_idx
			match_idx = t_idx
			p_idx++
			continue
		}
		if star_idx != -1 {
			p_idx = star_idx + 1
			match_idx++
			t_idx = match_idx
			continue
		}
		return false
	}

	for p_idx < p.len && p[p_idx] == `*` {
		p_idx++
	}
	return p_idx == p.len
}

fn collect_files_recursive(path string, depth int, max_depth int, mut out []string) {
	if !os.exists(path) {
		return
	}
	if os.is_file(path) {
		out << path
		return
	}
	entries := os.ls(path) or { return }
	for entry in entries {
		if entry == '.git' || entry == 'node_modules' {
			continue
		}
		full := os.join_path(path, entry)
		if os.is_dir(full) {
			if max_depth < 0 || depth < max_depth {
				collect_files_recursive(full, depth + 1, max_depth, mut out)
			}
		} else {
			out << full
		}
	}
}

fn expand_glob_files(pattern_path string, max_depth int) []string {
	dir_part := os.dir(pattern_path)
	base_pattern := os.base(pattern_path)
	mut root := dir_part
	if root.len == 0 || root == '.' {
		root = '.'
	}
	mut candidates := []string{}
	collect_files_recursive(root, 0, max_depth, mut candidates)
	mut matches := []string{}
	for file in candidates {
		if wildcard_match(base_pattern, os.base(file)) {
			matches << file
		}
	}
	matches.sort()
	return matches
}

// Read multiple files at once, supports comma-separated paths and glob patterns
fn read_many_files_tool(paths_str string, workspace string) string {
	if paths_str.trim_space().len == 0 {
		return 'Error: paths is required (comma-separated file paths or glob pattern)'
	}
	// Split by comma and collect all resolved paths
	mut all_paths := []string{}
	raw_parts := paths_str.split(',')
	for part in raw_parts {
		p := part.trim_space()
		if p.len == 0 {
			continue
		}
		resolved := resolve_workspace_path(p, workspace)
		// Check if it's a glob pattern
		if p.contains('*') || p.contains('?') {
			matches := expand_glob_files(resolved, 3)
			for m in matches {
				if os.is_file(m) {
					all_paths << m
				}
			}
		} else if os.is_file(resolved) {
			all_paths << resolved
		} else {
			all_paths << resolved // will produce error below
		}
	}

	if all_paths.len == 0 {
		return 'Error: No files matched the given paths/patterns'
	}

	// Cap at 20 files to avoid huge output
	if all_paths.len > 20 {
		return 'Error: Too many files (${all_paths.len}). Max 20 at once. Please narrow your pattern.'
	}

	mut results := []string{}
	mut total_chars := 0
	max_per_file := 30000
	for fpath in all_paths {
		if !os.is_file(fpath) {
			results << '--- ${fpath} ---\nError: File not found\n--- End ---'
			continue
		}
		content := os.read_file(fpath) or {
			results << '--- ${fpath} ---\nError: ${err.msg}\n--- End ---'
			continue
		}
		display := if content.len > max_per_file {
			content[..max_per_file] + '\n... (truncated, ${content.len} chars total)'
		} else {
			content
		}
		total_chars += display.len
		if total_chars > 200000 {
			results << '--- ${fpath} ---\n(skipped: output size limit reached)\n--- End ---'
			continue
		}
		results << '--- ${fpath} (${content.len} chars) ---\n${display}\n--- End: ${fpath} ---'
	}
	return '📄 Read ${all_paths.len} files:\n\n${results.join('\n\n')}'
}

// --- AGENTS.md Context Loading ---
// Loads project-level and user-level AGENTS.md files for context injection

fn load_agents_md(workspace string) string {
	mut parts := []string{}

	// 1. User-level: ~/.config/minimax/AGENTS.md
	user_path := os.join_path(get_minimax_config_dir(), 'AGENTS.md')
	if os.exists(user_path) {
		if content := os.read_file(user_path) {
			if content.trim_space().len > 0 {
				parts << '# User AGENTS.md\n' + content.trim_space()
			}
		}
	}

	// 2. Project-level: .agents/AGENTS.md (relative to workspace or cwd)
	base_dir := if workspace.len > 0 && os.is_dir(workspace) { workspace } else { os.getwd() }
	project_path := os.join_path(base_dir, '.agents', 'AGENTS.md')
	if os.exists(project_path) {
		if content := os.read_file(project_path) {
			if content.trim_space().len > 0 {
				parts << '# Project AGENTS.md\n' + content.trim_space()
			}
		}
	}

	if parts.len == 0 {
		return ''
	}
	return parts.join('\n\n')
}

// --- Session Note Tool (persistent memory across sessions) ---

fn get_session_notes_path() string {
	config_dir := get_minimax_config_dir()
	if !os.is_dir(config_dir) {
		os.mkdir_all(config_dir) or {}
	}
	return os.join_path(config_dir, 'session_notes.md')
}

fn session_note_read() string {
	path := get_session_notes_path()
	if !os.exists(path) {
		return '(No session notes yet)'
	}
	content := os.read_file(path) or { return '(Failed to read notes)' }
	if content.len == 0 {
		return '(Session notes file is empty)'
	}
	return content
}

fn session_note_write(content string) string {
	path := get_session_notes_path()
	os.write_file(path, content) or { return 'Error: Failed to write session notes: ${err.msg}' }
	return '✅ Session notes saved (${content.len} chars)'
}

fn session_note_append(content string) string {
	path := get_session_notes_path()
	existing := os.read_file(path) or { '' }
	new_content := if existing.len > 0 {
		'${existing}\n${content}'
	} else {
		content
	}
	os.write_file(path, new_content) or {
		return 'Error: Failed to append to session notes: ${err.msg}'
	}
	return '✅ Appended to session notes (total: ${new_content.len} chars)'
}

fn session_note_tool(action string, content string) string {
	match action {
		'read' { return session_note_read() }
		'write' { return session_note_write(content) }
		'append' { return session_note_append(content) }
		else { return 'Error: Unknown action "${action}". Use read, write, or append.' }
	}
}

// --- Working Checkpoint Tool (short-term working memory) ---

struct WorkingCheckpoint {
mut:
	key_info    string
	related_sop string
}

__global working_checkpoint = WorkingCheckpoint{}
__global working_checkpoint_loaded = false

fn get_working_checkpoint_path() string {
	config_dir := get_minimax_config_dir()
	if !os.is_dir(config_dir) {
		os.mkdir_all(config_dir) or {}
	}
	return os.join_path(config_dir, 'working_checkpoint.md')
}

fn parse_working_checkpoint(content string) WorkingCheckpoint {
	mut cp := WorkingCheckpoint{}
	key_marker := '[KEY_INFO]'
	sop_marker := '[RELATED_SOP]'
	key_idx := content.index(key_marker) or { -1 }
	sop_idx := content.index(sop_marker) or { -1 }
	if key_idx >= 0 && sop_idx >= 0 && key_idx < sop_idx {
		cp.key_info = content[key_idx + key_marker.len..sop_idx].trim_space()
		cp.related_sop = content[sop_idx + sop_marker.len..].trim_space()
		return cp
	}
	cp.key_info = content.trim_space()
	return cp
}

fn serialize_working_checkpoint(cp WorkingCheckpoint) string {
	return '[KEY_INFO]\n${cp.key_info.trim_space()}\n\n[RELATED_SOP]\n${cp.related_sop.trim_space()}\n'
}

fn load_working_checkpoint_once() {
	if working_checkpoint_loaded {
		return
	}
	working_checkpoint_loaded = true
	path := get_working_checkpoint_path()
	if !os.exists(path) {
		return
	}
	content := os.read_file(path) or { return }
	working_checkpoint = parse_working_checkpoint(content)
}

fn save_working_checkpoint() ! {
	path := get_working_checkpoint_path()
	os.write_file(path, serialize_working_checkpoint(working_checkpoint))!
}

fn format_working_checkpoint(cp WorkingCheckpoint) string {
	mut sections := []string{}
	if cp.key_info.trim_space().len > 0 {
		sections << '<key_info>\n${cp.key_info.trim_space()}\n</key_info>'
	}
	if cp.related_sop.trim_space().len > 0 {
		sections << '<related_sop>\n${cp.related_sop.trim_space()}\n</related_sop>'
	}
	return sections.join('\n')
}

fn get_working_checkpoint_context() string {
	load_working_checkpoint_once()
	formatted := format_working_checkpoint(working_checkpoint)
	if formatted.len == 0 {
		return ''
	}
	return 'Working checkpoint (keep this updated with update_working_checkpoint):\n${formatted}'
}

fn update_working_checkpoint_tool(key_info string, related_sop string) string {
	load_working_checkpoint_once()
	trimmed_key := key_info.trim_space()
	trimmed_sop := related_sop.trim_space()
	if trimmed_key.len == 0 && trimmed_sop.len == 0 {
		current := format_working_checkpoint(working_checkpoint)
		if current.len == 0 {
			return '(No working checkpoint yet)'
		}
		return current
	}
	if trimmed_key.len > 0 {
		working_checkpoint.key_info = trimmed_key
	}
	if trimmed_sop.len > 0 {
		working_checkpoint.related_sop = trimmed_sop
	}
	save_working_checkpoint() or { return 'Error: Failed to save working checkpoint: ${err.msg()}' }
	current := format_working_checkpoint(working_checkpoint)
	return '✅ Working checkpoint updated\n${current}'
}

// --- Checkpointing System ---
// File modification snapshots using git stash or file-level backup

struct CheckpointManager {
mut:
	workspace   string
	is_git      bool
	checkpoints []Checkpoint
	backup_dir  string
}

struct Checkpoint {
	id        int
	label     string
	timestamp string
	is_git    bool     // true = git stash, false = file backup
	files     []string // tracked files (for non-git mode)
}

fn new_checkpoint_manager(workspace string) CheckpointManager {
	is_git := os.exists(os.join_path(workspace, '.git'))
	backup_dir := os.join_path(get_minimax_config_dir(), 'checkpoints')
	if !os.is_dir(backup_dir) {
		os.mkdir_all(backup_dir) or {}
	}
	return CheckpointManager{
		workspace:   workspace
		is_git:      is_git
		checkpoints: []
		backup_dir:  backup_dir
	}
}

fn (mut cm CheckpointManager) create_checkpoint(label string) string {
	cp_id := cm.checkpoints.len + 1
	now := os.execute('date "+%Y-%m-%d %H:%M:%S"').output.trim_space()
	cp_label := if label.len > 0 { label } else { 'checkpoint-${cp_id}' }

	if cm.is_git {
		// Use git stash for git repos
		stash_msg := 'minimax-checkpoint-${cp_id}: ${cp_label}'
		// Stage all changes first, then stash
		os.execute('cd "${cm.workspace}" && git add -A 2>/dev/null')
		result := os.execute('cd "${cm.workspace}" && git stash push -m "${stash_msg}" --include-untracked 2>&1')
		if result.exit_code != 0 || result.output.contains('No local changes') {
			// Nothing to stash - create an empty checkpoint marker
			cm.checkpoints << Checkpoint{
				id:        cp_id
				label:     cp_label
				timestamp: now
				is_git:    true
				files:     []
			}
			return '📌 Checkpoint #${cp_id} "${cp_label}" (no changes to save)'
		}
		// Pop the stash back so working dir stays unchanged, but record it
		os.execute('cd "${cm.workspace}" && git stash pop 2>/dev/null')
		// Now create a real stash that we keep
		os.execute('cd "${cm.workspace}" && git add -A 2>/dev/null')
		// Use git stash create to create a stash commit without removing changes
		create_result := os.execute('cd "${cm.workspace}" && git stash create "${stash_msg}"')
		stash_ref := create_result.output.trim_space()
		if stash_ref.len > 0 {
			// Store the stash ref
			os.execute('cd "${cm.workspace}" && git stash store -m "${stash_msg}" ${stash_ref} 2>/dev/null')
		}
		cm.checkpoints << Checkpoint{
			id:        cp_id
			label:     cp_label
			timestamp: now
			is_git:    true
			files:     [stash_ref]
		}
		return '📌 Checkpoint #${cp_id} "${cp_label}" created (git stash) at ${now}'
	} else {
		// File-level backup for non-git directories
		cp_dir := os.join_path(cm.backup_dir, 'cp-${cp_id}')
		os.mkdir_all(cp_dir) or { return 'Error: Failed to create checkpoint dir: ${err.msg}' }

		// Copy all non-hidden files in workspace (shallow)
		files := os.ls(cm.workspace) or { return 'Error: ${err.msg}' }
		mut backed_up := []string{}
		for f in files {
			if f.starts_with('.') {
				continue
			}
			src := os.join_path(cm.workspace, f)
			dst := os.join_path(cp_dir, f)
			if os.is_file(src) {
				content := os.read_file(src) or { continue }
				os.write_file(dst, content) or { continue }
				backed_up << f
			}
		}
		cm.checkpoints << Checkpoint{
			id:        cp_id
			label:     cp_label
			timestamp: now
			is_git:    false
			files:     backed_up
		}
		return '📌 Checkpoint #${cp_id} "${cp_label}" created (${backed_up.len} files backed up) at ${now}'
	}
}

fn (mut cm CheckpointManager) restore_checkpoint(target_id int) string {
	if cm.checkpoints.len == 0 {
		return 'Error: No checkpoints available'
	}
	// find target
	mut cp_idx := -1
	if target_id <= 0 {
		// restore latest
		cp_idx = cm.checkpoints.len - 1
	} else {
		for i, cp in cm.checkpoints {
			if cp.id == target_id {
				cp_idx = i
				break
			}
		}
	}
	if cp_idx < 0 {
		return 'Error: Checkpoint #${target_id} not found'
	}
	cp := cm.checkpoints[cp_idx]

	if cp.is_git {
		// Git restore: use git stash to save current state, then restore
		// First, discard current changes and apply the checkpoint stash
		if cp.files.len > 0 && cp.files[0].len > 0 {
			stash_ref := cp.files[0]
			// Save current state first
			os.execute('cd "${cm.workspace}" && git add -A && git stash push -m "pre-restore-save" --include-untracked 2>/dev/null')
			// Apply the checkpoint
			result := os.execute('cd "${cm.workspace}" && git stash apply ${stash_ref} 2>&1')
			if result.exit_code != 0 {
				// Try to recover
				os.execute('cd "${cm.workspace}" && git checkout -- . 2>/dev/null')
				os.execute('cd "${cm.workspace}" && git stash pop 2>/dev/null')
				return 'Error: Failed to restore checkpoint #${cp.id}: ${result.output}'
			}
			return '✅ Restored to checkpoint #${cp.id} "${cp.label}" (${cp.timestamp})'
		}
		return '⚠️  Checkpoint #${cp.id} had no changes to restore'
	} else {
		// File restore
		cp_dir := os.join_path(cm.backup_dir, 'cp-${cp.id}')
		if !os.is_dir(cp_dir) {
			return 'Error: Checkpoint backup not found at ${cp_dir}'
		}
		mut restored := 0
		for f in cp.files {
			src := os.join_path(cp_dir, f)
			dst := os.join_path(cm.workspace, f)
			content := os.read_file(src) or { continue }
			os.write_file(dst, content) or { continue }
			restored++
		}
		return '✅ Restored ${restored} files from checkpoint #${cp.id} "${cp.label}" (${cp.timestamp})'
	}
}

fn (cm CheckpointManager) list_checkpoints() string {
	if cm.checkpoints.len == 0 {
		return '📌 No checkpoints yet. Use "checkpoint" command to create one.'
	}
	mut result := '📌 Checkpoints:\n'
	for cp in cm.checkpoints {
		mode := if cp.is_git { 'git' } else { 'file' }
		result += '  #${cp.id} "${cp.label}" [${mode}] — ${cp.timestamp}\n'
	}
	return result
}

__global checkpoint_mgr = CheckpointManager{}
__global checkpoint_mgr_initialized = false

fn ensure_checkpoint_manager(workspace string) {
	if !checkpoint_mgr_initialized {
		effective_ws := if workspace.len > 0 { workspace } else { os.getwd() }
		checkpoint_mgr = new_checkpoint_manager(effective_ws)
		checkpoint_mgr_initialized = true
	}
}

// Auto-checkpoint: call before file-modifying operations
fn auto_checkpoint_before_modify(filepath string, workspace string) {
	ensure_checkpoint_manager(workspace)
	// Only auto-checkpoint in git repos (lightweight)
	if checkpoint_mgr.is_git && checkpoint_mgr.checkpoints.len == 0 {
		// Create initial checkpoint on first file modification
		checkpoint_mgr.create_checkpoint('auto-initial')
	}
}

// --- TODO Task Manager ---
// AI-managed task list for tracking subtask progress

struct TodoItem {
	id     int
	title  string
	status string // 'pending', 'in-progress', 'done'
}

struct TodoManager {
mut:
	items []TodoItem
}

__global todo_mgr = TodoManager{}
__global todo_mgr_loaded = false

fn get_todo_store_path() string {
	config_dir := get_minimax_config_dir()
	if !os.is_dir(config_dir) {
		os.mkdir_all(config_dir) or {}
	}
	return os.join_path(config_dir, 'todos.db.txt')
}

fn sanitize_todo_title(title string) string {
	return title.replace('\r', ' ').replace('\n', ' ').replace('\t', ' ').trim_space()
}

fn normalize_todo_status(status string) string {
	normalized := status.trim_space().to_lower().replace('_', '-')
	return match normalized {
		'pending', 'in-progress', 'done' { normalized }
		else { 'pending' }
	}
}

fn next_todo_id() int {
	mut max_id := 0
	for item in todo_mgr.items {
		if item.id > max_id {
			max_id = item.id
		}
	}
	return max_id + 1
}

fn todo_manager_load_once() {
	if todo_mgr_loaded {
		return
	}
	todo_mgr_loaded = true
	path := get_todo_store_path()
	if !os.exists(path) {
		return
	}
	content := os.read_file(path) or { return }
	if content.trim_space().len == 0 {
		return
	}
	mut loaded := []TodoItem{}
	for line in content.split('\n') {
		trimmed := line.trim_space()
		if trimmed.len == 0 {
			continue
		}
		parts := line.split('\t')
		if parts.len < 3 {
			continue
		}
		id := parts[0].trim_space().int()
		if id <= 0 {
			continue
		}
		status := normalize_todo_status(parts[1])
		title := parts[2..].join('\t').trim_space()
		if title.len == 0 {
			continue
		}
		loaded << TodoItem{
			id:     id
			title:  title
			status: status
		}
	}
	todo_mgr.items = loaded
}

fn save_todo_manager_state() ! {
	path := get_todo_store_path()
	mut lines := []string{}
	for item in todo_mgr.items {
		title := sanitize_todo_title(item.title)
		if title.len == 0 {
			continue
		}
		status := normalize_todo_status(item.status)
		lines << '${item.id}\t${status}\t${title}'
	}
	os.write_file(path, lines.join('\n'))!
}

fn todo_manager_tool(action string, items_json string, id int, title string, status string) string {
	todo_manager_load_once()
	match action {
		'list' {
			return todo_list_items()
		}
		'set' {
			// Set the entire todo list from JSON-like format
			// Parse items from the title field: "1. item one\n2. item two"
			if title.len > 0 {
				result := todo_set_from_text(title)
				save_todo_manager_state() or {
					return 'Error: Failed to persist TODO list: ${err.msg()}'
				}
				return result
			}
			return 'Error: provide title with tasks (one per line, format: "1. Task title")'
		}
		'add' {
			if title.len == 0 {
				return 'Error: title is required'
			}
			new_id := next_todo_id()
			todo_mgr.items << TodoItem{
				id:     new_id
				title:  sanitize_todo_title(title)
				status: 'pending'
			}
			save_todo_manager_state() or {
				return 'Error: Failed to persist TODO list: ${err.msg()}'
			}
			return '✅ Added TODO #${new_id}: ${title}'
		}
		'update' {
			if id <= 0 {
				return 'Error: id is required'
			}
			new_status := if status.len > 0 { normalize_todo_status(status) } else { 'done' }
			for i, item in todo_mgr.items {
				if item.id == id {
					todo_mgr.items[i] = TodoItem{
						id:     item.id
						title:  if title.len > 0 { sanitize_todo_title(title) } else { item.title }
						status: new_status
					}
					save_todo_manager_state() or {
						return 'Error: Failed to persist TODO list: ${err.msg()}'
					}
					return '✅ Updated TODO #${id}: status → ${new_status}'
				}
			}
			return 'Error: TODO #${id} not found'
		}
		'clear' {
			todo_mgr.items = []
			save_todo_manager_state() or {
				return 'Error: Failed to persist TODO list: ${err.msg()}'
			}
			return '✅ TODO list cleared'
		}
		else {
			return 'Error: Unknown action "${action}". Use list, set, add, update, or clear.'
		}
	}
}

fn todo_set_from_text(text string) string {
	lines := text.split('\n')
	todo_mgr.items = []
	mut count := 0
	for line in lines {
		trimmed := line.trim_space()
		if trimmed.len == 0 {
			continue
		}
		count++
		// Strip leading number + dot (e.g., "1. Task")
		mut task_title := trimmed
		if dot_idx := trimmed.index('. ') {
			if dot_idx <= 3 {
				task_title = trimmed[dot_idx + 2..]
			}
		}
		safe_title := sanitize_todo_title(task_title)
		if safe_title.len == 0 {
			continue
		}
		todo_mgr.items << TodoItem{
			id:     next_todo_id()
			title:  safe_title
			status: 'pending'
		}
	}
	return '✅ Set ${count} TODO items\n${todo_list_items()}'
}

fn todo_list_items() string {
	todo_manager_load_once()
	if todo_mgr.items.len == 0 {
		return '📋 No TODO items. Use action="add" to create tasks.'
	}
	mut result := '📋 TODO List:\n'
	mut done := 0
	mut total := todo_mgr.items.len
	for item in todo_mgr.items {
		icon := match item.status {
			'done' { '✅' }
			'in-progress' { '🔄' }
			else { '⬜' }
		}
		if item.status == 'done' {
			done++
		}
		result += '  ${icon} #${item.id} ${item.title} [${item.status}]\n'
	}
	result += '  Progress: ${done}/${total}'
	return result
}

// --- str_replace_editor: Precise file editing tool ---
// Inspired by Trae Agent's str_replace_based_edit_tool

fn str_replace_editor(command string, path string, old_str string, new_str string, insert_line int, file_text string, view_range_start int, view_range_end int, workspace string) string {
	resolved := resolve_workspace_path(path, workspace)
	match command {
		'view' { return editor_view(resolved, view_range_start, view_range_end) }
		'create' { return editor_create(resolved, file_text) }
		'str_replace' { return editor_str_replace(resolved, old_str, new_str) }
		'insert' { return editor_insert(resolved, insert_line, new_str) }
		else { return 'Error: Unknown command "${command}". Use view, create, str_replace, or insert.' }
	}
}

fn editor_view(path string, range_start int, range_end int) string {
	if path.len == 0 {
		return 'Error: path is required'
	}
	// If path is a directory, list contents
	if os.is_dir(path) {
		files := os.ls(path) or { return 'Error: ${err.msg}' }
		mut result := '📂 Directory: ${path}\n'
		for file in files {
			full := os.join_path(path, file)
			if os.is_dir(full) {
				result += '  [DIR]  ${file}\n'
			} else {
				result += '  [FILE] ${file}\n'
			}
		}
		return result
	}
	if !os.exists(path) {
		return 'Error: File not found: ${path}'
	}
	content := os.read_file(path) or { return 'Error: ${err.msg}' }
	lines := content.split('\n')
	// Determine range
	mut start := 1
	mut end := lines.len
	if range_start > 0 {
		start = range_start
	}
	if range_end > 0 {
		end = range_end
	}
	if start < 1 {
		start = 1
	}
	if end > lines.len {
		end = lines.len
	}
	if start > end {
		return 'Error: Invalid range: ${start}-${end}'
	}
	// Build numbered output
	mut result := ''
	for i in start - 1 .. end {
		line_num := i + 1
		result += '${line_num:6d} | ${lines[i]}\n'
	}
	if range_start > 0 || range_end > 0 {
		result = '📄 ${path} (lines ${start}-${end} of ${lines.len}):\n${result}'
	} else {
		result = '📄 ${path} (${lines.len} lines):\n${result}'
	}
	return result
}

fn editor_create(path string, content string) string {
	if path.len == 0 {
		return 'Error: path is required'
	}
	if os.exists(path) {
		return 'Error: File already exists: ${path}. Use str_replace to edit or view to read.'
	}
	auto_checkpoint_before_modify(path, '')
	// Create parent directories if needed
	dir := os.dir(path)
	if dir.len > 0 && !os.is_dir(dir) {
		os.mkdir_all(dir) or { return 'Error: Failed to create directory: ${err.msg}' }
	}
	os.write_file(path, content) or { return 'Error: ${err.msg}' }
	lines := content.split('\n')
	return '✅ Created file: ${path} (${lines.len} lines, ${content.len} chars)'
}

fn editor_str_replace(path string, old_str string, new_str string) string {
	if path.len == 0 {
		return 'Error: path is required'
	}
	if old_str.len == 0 {
		return 'Error: old_str is required for str_replace'
	}
	if !os.exists(path) {
		return 'Error: File not found: ${path}'
	}
	auto_checkpoint_before_modify(path, '')
	content := os.read_file(path) or { return 'Error: ${err.msg}' }
	// Count occurrences
	count := content.count(old_str)
	if count == 0 {
		return 'Error: old_str not found in ${path}. Make sure it matches exactly (including whitespace).'
	}
	if count > 1 {
		return 'Error: old_str found ${count} times in ${path}. It must match exactly once. Add more context to make it unique.'
	}
	new_content := content.replace(old_str, new_str)
	os.write_file(path, new_content) or { return 'Error: ${err.msg}' }
	new_lines := new_content.split('\n')
	return '✅ Replaced in ${path} (${new_lines.len} lines total)'
}

fn editor_insert(path string, line_num int, text string) string {
	if path.len == 0 {
		return 'Error: path is required'
	}
	if !os.exists(path) {
		return 'Error: File not found: ${path}'
	}
	auto_checkpoint_before_modify(path, '')
	content := os.read_file(path) or { return 'Error: ${err.msg}' }
	mut lines := content.split('\n')
	if line_num < 0 || line_num > lines.len {
		return 'Error: insert_line ${line_num} out of range (0-${lines.len}). Use 0 to insert at the beginning.'
	}
	new_lines_to_add := text.split('\n')
	// Insert after line_num (0 = before first line)
	mut new_lines := []string{}
	for i in 0 .. line_num {
		new_lines << lines[i]
	}
	for nl in new_lines_to_add {
		new_lines << nl
	}
	for i in line_num .. lines.len {
		new_lines << lines[i]
	}
	new_content := new_lines.join('\n')
	os.write_file(path, new_content) or { return 'Error: ${err.msg}' }
	return '✅ Inserted ${new_lines_to_add.len} lines after line ${line_num} in ${path} (${new_lines.len} lines total)'
}

fn list_dir_tool(path string) !string {
	if path.len == 0 {
		return error('目录路径不能为空')
	}
	if !os.is_dir(path) {
		return error('${path} 不是一个有效的目录')
	}
	files := os.ls(path)!
	mut result := '📂 目录内容 (${path}):\n'
	for file in files {
		full_path := path + '/' + file
		if os.is_dir(full_path) {
			result += '  [DIR]  ${file}\n'
		} else {
			result += '  [FILE] ${file}\n'
		}
	}
	return result
}

fn run_command(cmd string) !string {
	return run_command_in_dir(cmd, '')
}

fn run_command_in_dir(cmd string, workdir string) !string {
	if cmd.len == 0 {
		return error('命令不能为空')
	}
	dangerous := ['rm -rf', 'rm /', 'mkfs', 'dd if=', ':(){:|:&};:', 'chmod -R 777 /',
		'chmod -R 000 /', '> /dev/sda', 'mv /* ', 'mv / ']
	for d in dangerous {
		if cmd.contains(d) {
			return error('⚠️  拒绝执行危险命令')
		}
	}

	// Find bash if available
	bash_path := find_bash_path()
	use_bash := bash_path.len > 0
	mut output := ''
	mut exit_code := 0

	if use_bash {
		actual_bash := if bash_path == 'bash' {
			os.find_abs_path_of_executable('bash') or { 'bash' }
		} else {
			bash_path
		}
		mut p := os.new_process(actual_bash)
		p.set_args(['-c', cmd])
		if workdir.len > 0 && os.is_dir(workdir) {
			p.set_work_folder(workdir)
		}
		p.use_stdio_ctl = true
		p.run()
		mut cmd_output := p.stdout_slurp()
		cmd_output += p.stderr_slurp()
		p.wait()
		exit_code = p.code
		p.close()
		output = cmd_output
	} else {
		actual_cmd := if workdir.len > 0 && os.is_dir(workdir) {
			'cd /d "${workdir}" & ${cmd}'
		} else {
			cmd
		}
		result := os.execute('cmd /c ${shell_escape_windows(actual_cmd)}')
		output = result.output
		exit_code = result.exit_code
	}

	if exit_code != 0 {
		return error('命令执行失败 (exit ${exit_code}): ${output}')
	}
	return '✅ 命令执行结果:\n${output}'
}

fn mouse_control_tool(action string, x int, y int, button string, clicks int, delta int) string {
	if !allow_desktop_control {
		return 'Error: 桌面控制能力未开启，请设置 enable_desktop_control=true 或使用 --enable-desktop-control'
	}
	safe_action := action.trim_space().to_lower()
	if safe_action !in ['move', 'click', 'scroll'] {
		return 'Error: unsupported action. Use move/click/scroll'
	}
	if safe_action == 'move' && (x < 0 || y < 0) {
		return 'Error: move action requires x and y >= 0'
	}
	if (safe_action == 'move' || (safe_action == 'click' && x >= 0 && y >= 0))
		&& (x < 0 || y < 0 || x > 10000 || y > 10000) {
		return 'Error: x/y out of safe range (0-10000)'
	}
	safe_button := if button.trim_space().len == 0 { 'left' } else { button.trim_space().to_lower() }
	if safe_button !in ['left', 'right', 'middle'] {
		return 'Error: unsupported button. Use left/right/middle'
	}
	safe_clicks := if clicks < 1 {
		1
	} else if clicks > 5 {
		5
	} else {
		clicks
	}
	safe_delta := if delta == 0 {
		120
	} else if delta > 1200 {
		1200
	} else if delta < -1200 {
		-1200
	} else {
		delta
	}
	if os.user_os() == 'macos' {
		swift_script := build_macos_mouse_swift_script(safe_action, x, y, safe_button,
			safe_clicks, safe_delta)
		_ := run_macos_swift_script(swift_script) or { return 'Error: ${err.msg()}' }
		return '✅ mouse_control: ${safe_action} completed'
	}
	if os.user_os() != 'windows' {
		return 'Error: mouse_control 当前仅支持 Windows 和 macOS'
	}

	mut ps_script := r'
__D__ErrorActionPreference = "Stop"
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class MiniMaxInput {
	[DllImport("user32.dll")]
	public static extern bool SetCursorPos(int X, int Y);
	[DllImport("user32.dll")]
	public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);
}
"@
__D__action = "__ACTION__"
__D__button = "__BUTTON__"
__D__x = __X__
__D__y = __Y__
__D__clicks = __CLICKS__
__D__delta = __DELTA__

if (__D__action -eq "move") {
	[MiniMaxInput]::SetCursorPos(__D__x, __D__y) | Out-Null
} elseif (__D__action -eq "click") {
	if (__D__x -ge 0 -and __D__y -ge 0) {
		[MiniMaxInput]::SetCursorPos(__D__x, __D__y) | Out-Null
	}
	__D__down = 0x0002
	__D__up = 0x0004
	if (__D__button -eq "right") { __D__down = 0x0008; __D__up = 0x0010 }
	elseif (__D__button -eq "middle") { __D__down = 0x0020; __D__up = 0x0040 }
	for (__D__i = 0; __D__i -lt __D__clicks; __D__i++) {
		[MiniMaxInput]::mouse_event(__D__down, 0, 0, 0, [UIntPtr]::Zero)
		[MiniMaxInput]::mouse_event(__D__up, 0, 0, 0, [UIntPtr]::Zero)
	}
} elseif (__D__action -eq "scroll") {
	[MiniMaxInput]::mouse_event(0x0800, 0, 0, [uint32]__D__delta, [UIntPtr]::Zero)
}
Write-Output "ok"
'
	ps_script = ps_script.replace('__ACTION__', safe_action)
	ps_script = ps_script.replace('__BUTTON__', safe_button)
	ps_script = ps_script.replace('__X__', x.str())
	ps_script = ps_script.replace('__Y__', y.str())
	ps_script = ps_script.replace('__CLICKS__', safe_clicks.str())
	ps_script = ps_script.replace('__DELTA__', safe_delta.str())
	ps_script = ps_script.replace('__D__', '$')
	_ := run_powershell_script(ps_script) or { return 'Error: ${err.msg()}' }
	return '✅ mouse_control: ${safe_action} completed'
}

fn keyboard_control_tool(action string, text string, keys string) string {
	if !allow_desktop_control {
		return 'Error: 桌面控制能力未开启，请设置 enable_desktop_control=true 或使用 --enable-desktop-control'
	}
	safe_action := action.trim_space().to_lower()
	if safe_action !in ['type', 'send'] {
		return 'Error: unsupported action. Use type/send'
	}
	if safe_action == 'type' && text.len == 0 {
		return 'Error: type action requires text'
	}
	if safe_action == 'send' && keys.len == 0 {
		return 'Error: send action requires keys'
	}
	if text.len > 500 || keys.len > 128 {
		return 'Error: keyboard payload too large'
	}
	if text.contains('\n') || text.contains('\r') {
		return 'Error: type action does not support newline text'
	}
	if os.user_os() == 'macos' {
		script := build_macos_keyboard_script(safe_action, text, keys) or {
			return 'Error: ${err.msg()}'
		}
		_ := run_macos_applescript(script) or { return 'Error: ${err.msg()}' }
		return '✅ keyboard_control: ${safe_action} completed'
	}
	if os.user_os() != 'windows' {
		return 'Error: keyboard_control 当前仅支持 Windows 和 macOS'
	}

	mut ps_script := r'
__D__ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
__D__action = "__ACTION__"
__D__text = "__TEXT__"
__D__keys = "__KEYS__"

if (__D__action -eq "type") {
	[System.Windows.Forms.SendKeys]::SendWait(__D__text)
} elseif (__D__action -eq "send") {
	[System.Windows.Forms.SendKeys]::SendWait(__D__keys)
}
Write-Output "ok"
'
	ps_script = ps_script.replace('__ACTION__', safe_action)
	ps_script = ps_script.replace('__TEXT__', escape_powershell_double_quoted(escape_windows_sendkeys_literal(text)))
	ps_script = ps_script.replace('__KEYS__', escape_powershell_double_quoted(keys))
	ps_script = ps_script.replace('__D__', '$')
	_ := run_powershell_script(ps_script) or { return 'Error: ${err.msg()}' }
	return '✅ keyboard_control: ${safe_action} completed'
}

fn capture_screen_file(path string, x int, y int, width int, height int) !string {
	if !allow_screen_capture {
		return error('屏幕截图能力未开启，请设置 enable_screen_capture=true 或使用 --enable-screen-capture')
	}
	if (width > 0 && height <= 0) || (width <= 0 && height > 0) {
		return error('width 和 height 需同时设置为正数，或同时省略')
	}
	if (width > 0 && height > 0) && (x < 0 || y < 0) {
		return error('区域截图要求 x 和 y >= 0')
	}
	if width > 10000 || height > 10000 || x > 10000 || y > 10000 {
		return error('截图参数超出安全范围')
	}
	mut output_path := path.trim_space()
	if output_path.len == 0 {
		output_path = os.join_path(os.temp_dir(), 'minimax_capture_${time.now().unix_milli()}.png')
	}
	if !output_path.to_lower().ends_with('.png') {
		output_path += '.png'
	}
	parent := os.dir(output_path)
	if parent.len > 0 {
		os.mkdir_all(parent) or { return error('创建截图目录失败: ${err}') }
	}

	if os.user_os() == 'macos' {
		cmd := build_macos_screencapture_command(output_path, x, y, width, height)
		result := os.execute(cmd)
		if result.exit_code != 0 {
			return error('macOS screencapture 执行失败，请检查屏幕录制权限: ${result.output}')
		}
		if !os.exists(output_path) {
			return error('截图文件未生成，请检查屏幕录制权限')
		}
		return output_path
	}

	if os.user_os() != 'windows' {
		return error('capture_screen 当前仅支持 Windows 和 macOS')
	}

	mut ps_script := r'
__D__ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
__D__out = "__OUT__"
__D__x = __X__
__D__y = __Y__
__D__w = __W__
__D__h = __H__

if (__D__w -le 0 -or __D__h -le 0) {
	__D__bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
	__D__x = __D__bounds.X
	__D__y = __D__bounds.Y
	__D__w = __D__bounds.Width
	__D__h = __D__bounds.Height
}

__D__bitmap = New-Object System.Drawing.Bitmap __D__w, __D__h
__D__graphics = [System.Drawing.Graphics]::FromImage(__D__bitmap)
__D__graphics.CopyFromScreen(__D__x, __D__y, 0, 0, __D__bitmap.Size)
__D__bitmap.Save(__D__out, [System.Drawing.Imaging.ImageFormat]::Png)
__D__graphics.Dispose()
__D__bitmap.Dispose()
Write-Output __D__out
'
	ps_script = ps_script.replace('__OUT__', escape_powershell_double_quoted(output_path))
	ps_script = ps_script.replace('__X__', x.str())
	ps_script = ps_script.replace('__Y__', y.str())
	ps_script = ps_script.replace('__W__', width.str())
	ps_script = ps_script.replace('__H__', height.str())
	ps_script = ps_script.replace('__D__', '$')

	output := run_powershell_script(ps_script) or { return error(err.msg()) }
	if output.len == 0 {
		return error('截图命令未返回文件路径')
	}
	return output
}

fn build_macos_sips_resize_command(input_path string, output_path string, max_dimension int) string {
	return 'sips -Z ${max_dimension} ${shell_escape(input_path)} --out ${shell_escape(output_path)}'
}

fn maybe_prepare_image_for_understand_image(image_path string) string {
	if os.user_os() != 'macos' {
		return image_path
	}
	if !os.exists(image_path) {
		return image_path
	}
	if os.file_size(image_path) <= understand_image_downsample_threshold_bytes {
		return image_path
	}
	if !os.exists('/usr/bin/sips') {
		return image_path
	}
	resized_path := os.join_path(os.temp_dir(), 'minimax_understand_image_${time.now().unix_milli()}.png')
	cmd := build_macos_sips_resize_command(image_path, resized_path, understand_image_downsample_max_dimension)
	result := os.execute(cmd)
	if result.exit_code != 0 || !os.exists(resized_path) {
		return image_path
	}
	return resized_path
}

fn capture_screen_tool(path string, x int, y int, width int, height int) string {
	output := capture_screen_file(path, x, y, width, height) or { return 'Error: ${err.msg()}' }
	return '✅ 截图已保存: ${output}'
}

struct UnderstandImageAttempt {
	path_key   string
	prompt_key string
}

fn add_understand_image_attempt(mut attempts []UnderstandImageAttempt, path_key string, prompt_key string) {
	if path_key.len == 0 {
		return
	}
	for attempt in attempts {
		if attempt.path_key == path_key && attempt.prompt_key == prompt_key {
			return
		}
	}
	attempts << UnderstandImageAttempt{
		path_key:   path_key
		prompt_key: prompt_key
	}
}

fn discover_understand_image_attempts(mut mcp McpManager) []UnderstandImageAttempt {
	mut attempts := []UnderstandImageAttempt{}
	mut discovered_path := ''
	mut discovered_prompt := 'prompt'
	for tool in mcp.get_all_tools() {
		if tool.name != 'understand_image' {
			continue
		}
		for param in tool.params {
			name_lower := param.name.to_lower()
			if discovered_path.len == 0
				&& (name_lower.contains('image') || name_lower == 'path' || name_lower == 'file') {
				discovered_path = param.name
			}
			if name_lower.contains('prompt') || name_lower.contains('question')
				|| name_lower.contains('query') {
				discovered_prompt = param.name
			}
			if discovered_path.len == 0
				&& (name_lower.contains('path') || name_lower.contains('file')) {
				discovered_path = param.name
			}
		}
		break
	}
	if discovered_path.len > 0 {
		add_understand_image_attempt(mut attempts, discovered_path, discovered_prompt)
	}
	add_understand_image_attempt(mut attempts, 'image_source', 'prompt')
	add_understand_image_attempt(mut attempts, 'image_path', 'prompt')
	add_understand_image_attempt(mut attempts, 'path', 'prompt')
	add_understand_image_attempt(mut attempts, 'file', 'prompt')
	add_understand_image_attempt(mut attempts, 'image_source', 'question')
	add_understand_image_attempt(mut attempts, 'image_path', 'question')
	add_understand_image_attempt(mut attempts, 'path', 'question')
	add_understand_image_attempt(mut attempts, 'file', 'question')
	return attempts
}

fn call_understand_image_with_fallback(mut mcp McpManager, image_path string, prompt string) !string {
	attempts := discover_understand_image_attempts(mut mcp)
	mut last_err := 'understand_image 调用失败'
	prepared_image_path := maybe_prepare_image_for_understand_image(image_path)
	for attempt in attempts {
		mut args_json := '{"${attempt.path_key}":${detect_jq_value(prepared_image_path)}'
		if prompt.len > 0 && attempt.prompt_key.len > 0 {
			args_json += ',"${attempt.prompt_key}":${detect_jq_value(prompt)}'
		}
		args_json += '}'
		result := mcp.call_tool('understand_image', args_json) or {
			last_err = err.msg()
			continue
		}
		return result
	}
	return error(last_err)
}

fn screen_analyze_tool_with_mcp(mut mcp McpManager, input map[string]string, workspace string) string {
	if !allow_screen_capture {
		return 'Error: 屏幕截图能力未开启，请设置 enable_screen_capture=true 或使用 --enable-screen-capture'
	}
	mut has_understand_image := false
	for tool in mcp.get_all_tools() {
		if tool.name == 'understand_image' {
			has_understand_image = true
			break
		}
	}
	if !has_understand_image {
		return 'Error: MCP 工具 understand_image 不可用，请先使用 --mcp 启动'
	}

	mut image_path := input['image_path'] or { '' }
	if image_path.len == 0 {
		image_path = input['image_source'] or { '' }
	}
	if image_path.len == 0 {
		image_path = input['path'] or { '' }
	}
	image_path = resolve_workspace_path(image_path, workspace)
	x := parse_int_input(input, 'x', 0)
	y := parse_int_input(input, 'y', 0)
	width := parse_int_input(input, 'width', 0)
	height := parse_int_input(input, 'height', 0)

	mut used_capture := false
	if image_path.trim_space().len == 0 {
		captured := capture_screen_file('', x, y, width, height) or { return 'Error: ${err.msg()}' }
		image_path = captured
		used_capture = true
	} else if !os.exists(image_path) {
		return 'Error: image file not found: ${image_path}'
	}

	mut prompt := input['prompt'] or { '' }
	if prompt.trim_space().len == 0 {
		prompt = input['question'] or { '' }
	}
	if prompt.trim_space().len == 0 {
		prompt = '请描述图像内容并提取关键文本。'
	}

	analysis := call_understand_image_with_fallback(mut mcp, image_path, prompt) or {
		return 'Error: ${err.msg()}'
	}
	if used_capture {
		return '🖼️ 已截图并识别: ${image_path}\n${analysis}'
	}
	return '🖼️ 已识别图片: ${image_path}\n${analysis}'
}

// Resolve a path relative to workspace directory
fn resolve_workspace_path(path string, workspace string) string {
	if workspace.len == 0 || path.len == 0 {
		return path
	}
	// Already absolute path
	if is_abs_path(path) || path.starts_with('~') {
		return path
	}
	// Avoid double joining if path already contains workspace prefix
	normalized_workspace := workspace.replace('/', '\\')
	if path.contains(normalized_workspace) || path.contains(workspace.replace('\\', '/')) {
		return path
	}
	return os.join_path(workspace, path)
}

fn get_available_tools() []ToolDefinition {
	return [
		ToolDefinition{'str_replace_editor', '精确文件编辑 - view/create/str_replace/insert'},
		ToolDefinition{'bash', '持久化Bash会话 - 保持cwd/env状态'},
		ToolDefinition{'read_file', '读取文件内容 - 用法: #read <path>'},
		ToolDefinition{'write_file', '写入文件 - 用法: #write <path> <content>'},
		ToolDefinition{'list_dir', '列出目录 - 用法: #ls <path>'},
		ToolDefinition{'run_command', '执行命令 - 用法: #run <command>'},
		ToolDefinition{'mouse_control', '鼠标控制（需 enable_desktop_control）'},
		ToolDefinition{'keyboard_control', '键盘控制（需 enable_desktop_control）'},
		ToolDefinition{'capture_screen', '屏幕截图（需 enable_screen_capture）'},
		ToolDefinition{'screen_analyze', '截图并调用 understand_image 识别（需 --mcp）'},
		ToolDefinition{'match_sop', 'SOP 匹配 - 根据当前任务匹配最相关的全局 SOP'},
		ToolDefinition{'record_experience', '经验沉淀 - 记录经验并自动同步全局 skill/SOP'},
		ToolDefinition{'session_note', '持久化记忆 - read/write/append 跨会话笔记'},
		ToolDefinition{'update_working_checkpoint', '短期工作记忆 - 记录进度/约束/SOP'},
		ToolDefinition{'todo_manager', '任务管理 - list/set/add/update/clear'},
		ToolDefinition{'send_mail', '发送邮件 - 需 smtp 服务器和账号密码'},
		ToolDefinition{'generate_image', '文生成图 - 调用 MiniMax 图像生成 API'},
	]
}

fn handle_builtin_command(input string) string {
	if input.starts_with('doctor') {
		result := handle_doctor_command(input)
		if result.len > 0 {
			return result
		}
	}

	if input.starts_with('#read ') {
		path := input[6..].trim_space()
		if result := read_file_tool(path) {
			return result
		} else {
			return 'ERROR: ${err.msg()}'
		}
	}

	if input.starts_with('#write ') {
		parts := input[7..].split(' ')
		if parts.len < 2 {
			return '用法: #write <path> <content>'
		}
		path := parts[0]
		content := input[8 + path.len..].trim_space()
		if result := write_file_tool(path, content) {
			return result
		} else {
			return 'ERROR: ${err.msg()}'
		}
	}

	if input.starts_with('#ls ') {
		path := input[4..].trim_space()
		if result := list_dir_tool(path) {
			return result
		} else {
			return 'ERROR: ${err.msg()}'
		}
	}

	if input.starts_with('#run ') {
		cmd := input[5..].trim_space()
		if result := run_command(cmd) {
			return result
		} else {
			return 'ERROR: ${err.msg()}'
		}
	}

	return ''
}

// --- Sequential Thinking Tool ---

fn sequentialthinking_tool(thought string, thought_number int, total_thoughts int, next_thought_needed bool, is_revision bool, revises_thought int, branch_from int) string {
	mut prefix := ''
	if is_revision && revises_thought > 0 {
		prefix = '🔄 Revision of thought ${revises_thought}'
	} else if branch_from > 0 {
		prefix = '🌿 Branch from thought ${branch_from}'
	} else {
		prefix = '💭 Thought'
	}
	status := if next_thought_needed { 'continuing...' } else { 'complete ✅' }
	if !runtime_is_acp_mode() {
		println('\x1b[92m  ${prefix} ${thought_number}/${total_thoughts}: ${thought}\x1b[0m')
		println('\x1b[92m  [${status}]\x1b[0m')
	}
	return '${prefix} ${thought_number}/${total_thoughts} recorded. ${status}'
}

// --- JSON Edit Tool ---

fn dot_path_to_jq(path string) string {
	if path.len == 0 {
		return '.'
	}
	mut jq_path := '.'
	parts := path.split('.')
	for part in parts {
		if part.contains('[') {
			// e.g. items[0] -> .items[0]
			jq_path += '.${part}'
		} else {
			jq_path += '.${part}'
		}
	}
	return jq_path
}

fn json_edit_tool(action string, file_path string, path string, value string) string {
	if file_path.len == 0 {
		return 'Error: file path is required'
	}
	if !os.exists(file_path) && action != 'add' && action != 'set' {
		return 'Error: file not found: ${file_path}'
	}

	match action {
		'view' {
			if !os.exists(file_path) {
				return 'Error: file not found: ${file_path}'
			}
			jq_path := dot_path_to_jq(path)
			result := os.execute('jq "${jq_path}" "${file_path}" 2>&1')
			if result.exit_code != 0 {
				// Fallback: read file directly
				content := os.read_file(file_path) or { return 'Error: cannot read file: ${err}' }
				return content
			}
			return result.output.trim_space()
		}
		'set' {
			jq_path := dot_path_to_jq(path)
			if path.len == 0 {
				return 'Error: path is required for set action'
			}
			jq_val := detect_jq_value(value)
			result := os.execute('jq \'${jq_path} = ${jq_val}\' "${file_path}" 2>&1')
			if result.exit_code != 0 {
				return 'Error: jq failed: ${result.output}'
			}
			os.write_file(file_path, result.output) or { return 'Error: cannot write file: ${err}' }
			return 'Set ${path} = ${value}'
		}
		'add' {
			if path.len == 0 {
				return 'Error: path is required for add action'
			}
			jq_path := dot_path_to_jq(path)
			jq_val := detect_jq_value(value)
			// If target is array, append; otherwise set
			if !os.exists(file_path) {
				// Create new JSON file
				os.write_file(file_path, '{}') or { return 'Error: cannot create file: ${err}' }
			}
			// Check if path ends with [] for array append
			if path.ends_with('[]') {
				arr_path := dot_path_to_jq(path[..path.len - 2])
				result := os.execute('jq \'${arr_path} += [${jq_val}]\' "${file_path}" 2>&1')
				if result.exit_code != 0 {
					return 'Error: jq failed: ${result.output}'
				}
				os.write_file(file_path, result.output) or {
					return 'Error: cannot write file: ${err}'
				}
				return 'Appended ${value} to ${path[..path.len - 2]}'
			}
			result := os.execute('jq \'${jq_path} = ${jq_val}\' "${file_path}" 2>&1')
			if result.exit_code != 0 {
				return 'Error: jq failed: ${result.output}'
			}
			os.write_file(file_path, result.output) or { return 'Error: cannot write file: ${err}' }
			return 'Added ${path} = ${value}'
		}
		'remove' {
			if path.len == 0 {
				return 'Error: path is required for remove action'
			}
			jq_path := dot_path_to_jq(path)
			result := os.execute('jq \'del(${jq_path})\' "${file_path}" 2>&1')
			if result.exit_code != 0 {
				return 'Error: jq failed: ${result.output}'
			}
			os.write_file(file_path, result.output) or { return 'Error: cannot write file: ${err}' }
			return 'Removed ${path}'
		}
		else {
			return 'Error: unknown action "${action}". Use: view, set, add, remove'
		}
	}
}

fn detect_jq_value(val string) string {
	// Auto-detect JSON scalar/object/array value from plain text
	if val == 'true' || val == 'false' || val == 'null' {
		return val
	}
	// Check if number (int or float)
	// Must have at least one digit to be a valid number
	mut is_num := true
	mut has_dot := false
	mut has_digit := false
	for i, c in val {
		if c == `-` && i == 0 {
			continue
		}
		if c == `.` && !has_dot {
			has_dot = true
			continue
		}
		if c >= `0` && c <= `9` {
			has_digit = true
			continue
		}
		// Any other character means it's not a number
		is_num = false
		break
	}
	if is_num && has_digit && val.len > 0 {
		return val
	}
	// Check if already a JSON object/array
	if (val.starts_with('{') && val.ends_with('}')) || (val.starts_with('[') && val.ends_with(']')) {
		return val
	}
	// String: wrap in quotes with JSON escaping
	escaped := escape_json_string(val)
	return '"${escaped}"'
}

// --- Code Search Tools ---

// --- ask_user Tool: AI asks user for clarification ---

fn ask_user_tool(question string) string {
	if question.len == 0 {
		return 'Error: question is required'
	}
	if runtime_is_acp_mode() {
		return 'Error: ask_user is unavailable in ACP mode'
	}
	if term_ui_is_active() {
		return term_ui_ask_user(question)
	}
	println('\x1b[1;33m\u2753 AI \u63d0\u95ee:\x1b[0m ${question}')
	print('\x1b[1;34myou >\x1b[0m ')
	answer := os.input('')
	if answer.trim_space().len == 0 {
		return '(User provided no answer)'
	}
	return answer.trim_space()
}

fn grep_search_tool(pattern string, search_path string, include string) string {
	if pattern.len == 0 {
		return 'Error: pattern is required'
	}
	if os.user_os() == 'windows' {
		mut files := []string{}
		target := if search_path.len > 0 { search_path } else { '.' }
		if os.is_file(target) {
			files << target
		} else {
			collect_files_recursive(target, 0, -1, mut files)
		}
		mut lines := []string{}
		for file in files {
			if include.len > 0 && !wildcard_match(include, os.base(file)) {
				continue
			}
			content := os.read_file(file) or { continue }
			mut line_num := 1
			for line in content.split('\n') {
				if line.contains(pattern) {
					lines << '${file}:${line_num}:${line}'
					if lines.len >= 200 {
						return lines.join('\n') + '\n\n[... more lines, refine your search]'
					}
				}
				line_num++
			}
		}
		if lines.len == 0 {
			return 'No matches found.'
		}
		return lines.join('\n')
	}
	mut args := ['-rn', '--color=never']
	if include.len > 0 {
		args << '--include=${include}'
	}
	args << '-E'
	args << shell_escape(pattern)
	args << shell_escape(search_path)
	result := os.execute('grep ' + args.join(' '))
	if result.exit_code == 1 {
		return 'No matches found.'
	}
	if result.exit_code != 0 {
		return 'Error: grep failed (exit ${result.exit_code}): ${result.output}'
	}
	lines := result.output.split('\n')
	if lines.len > 200 {
		return lines[..200].join('\n') +
			'\n\n[... ${lines.len - 200} more lines, refine your search]'
	}
	return result.output
}

fn find_files_tool(pattern string, search_path string) string {
	if pattern.len == 0 {
		return 'Error: pattern is required'
	}
	target := if search_path.len > 0 { search_path } else { '.' }
	mut candidates := []string{}
	if os.is_file(target) {
		candidates << target
	} else {
		collect_files_recursive(target, 0, -1, mut candidates)
	}
	mut matches := []string{}
	for file in candidates {
		if wildcard_match(pattern, os.base(file)) {
			matches << file
			if matches.len >= 200 {
				break
			}
		}
	}
	if matches.len == 0 {
		return 'No files found matching "${pattern}"'
	}
	matches.sort()
	return matches.join('\n')
}

// --- AI Tool Calling ---

pub struct ToolUse {
pub mut:
	id    string
	name  string
	input map[string]string
}

fn get_tools_schema_json() string {
	return '[' +
		'{"name":"str_replace_editor","description":"A powerful file editor for viewing, creating, and editing files. Commands: view (show file with line numbers, supports line range), create (create new file), str_replace (precisely replace one occurrence of old_str with new_str), insert (insert text after a specific line number).","input_schema":{"type":"object","properties":{"command":{"type":"string","description":"The command to run: view, create, str_replace, or insert","enum":["view","create","str_replace","insert"]},"path":{"type":"string","description":"File or directory path"},"old_str":{"type":"string","description":"(str_replace only) The exact string to replace. Must match exactly once."},"new_str":{"type":"string","description":"(str_replace) Replacement string. (insert) Text to insert."},"insert_line":{"type":"integer","description":"(insert only) Line number after which to insert. Use 0 for beginning."},"file_text":{"type":"string","description":"(create only) Content for the new file."},"view_range":{"type":"array","items":{"type":"integer"},"description":"(view only) Optional [start_line, end_line] to view a range."}},"required":["command","path"]}},' +
		'{"name":"bash","description":"A persistent bash shell session. Working directory and environment variables are preserved between calls. Use this instead of run_command for multi-step operations.","input_schema":{"type":"object","properties":{"command":{"type":"string","description":"The bash command to execute"},"restart":{"type":"boolean","description":"Set to true to restart the bash session (reset cwd and env)"}},"required":["command"]}},' +
		'{"name":"read_file","description":"Read the contents of a file at the given path. Returns the full file content as text.","input_schema":{"type":"object","properties":{"path":{"type":"string","description":"The file path to read"}},"required":["path"]}},' +
		'{"name":"write_file","description":"Write content to a file at the given path. Creates the file if it does not exist, overwrites if it does.","input_schema":{"type":"object","properties":{"path":{"type":"string","description":"The file path to write to"},"content":{"type":"string","description":"The content to write to the file"}},"required":["path","content"]}},' +
		'{"name":"list_dir","description":"List the contents of a directory, showing files and subdirectories.","input_schema":{"type":"object","properties":{"path":{"type":"string","description":"The directory path to list"}},"required":["path"]}},' +
		'{"name":"run_command","description":"Run a shell command and return its output. Dangerous commands like rm -rf are blocked.","input_schema":{"type":"object","properties":{"command":{"type":"string","description":"The shell command to execute"}},"required":["command"]}},' +
		'{"name":"mouse_control","description":"Control mouse movement/click/scroll on desktop. Requires desktop control to be explicitly enabled.","input_schema":{"type":"object","properties":{"action":{"type":"string","description":"Action: move, click, or scroll","enum":["move","click","scroll"]},"x":{"type":"integer","description":"X coordinate for move/click"},"y":{"type":"integer","description":"Y coordinate for move/click"},"button":{"type":"string","description":"Mouse button for click","enum":["left","right","middle"]},"clicks":{"type":"integer","description":"Click count (1-5) for click action"},"delta":{"type":"integer","description":"Scroll delta for scroll action (positive/negative)"}},"required":["action"]}},' +
		'{"name":"keyboard_control","description":"Control keyboard input on desktop. Requires desktop control to be explicitly enabled.","input_schema":{"type":"object","properties":{"action":{"type":"string","description":"Action: type literal text or send raw keys","enum":["type","send"]},"text":{"type":"string","description":"Literal text for type action"},"keys":{"type":"string","description":"Raw SendKeys pattern for send action (e.g. ^l, {ENTER})"}},"required":["action"]}},' +
		'{"name":"capture_screen","description":"Capture desktop screenshot and save to a PNG file. Requires screen capture to be explicitly enabled.","input_schema":{"type":"object","properties":{"path":{"type":"string","description":"Output file path (.png). If omitted, temp path is used."},"x":{"type":"integer","description":"Region X (optional)"},"y":{"type":"integer","description":"Region Y (optional)"},"width":{"type":"integer","description":"Region width (optional, with height)"},"height":{"type":"integer","description":"Region height (optional, with width)"}},"required":[]}},' +
		'{"name":"screen_analyze","description":"Capture screen (or use existing image path) then call MCP understand_image to analyze it.","input_schema":{"type":"object","properties":{"image_path":{"type":"string","description":"Existing image file path. If omitted, screen is captured first."},"image_source":{"type":"string","description":"Alias of image_path for understand_image compatibility."},"prompt":{"type":"string","description":"Analysis instruction sent to understand_image"},"x":{"type":"integer","description":"Region X for capture when image_path omitted"},"y":{"type":"integer","description":"Region Y for capture when image_path omitted"},"width":{"type":"integer","description":"Region width for capture when image_path omitted"},"height":{"type":"integer","description":"Region height for capture when image_path omitted"}},"required":[]}},' +
		'{"name":"match_sop","description":"Find the best matching global SOP for the current task before taking action. Returns the top matching SOP name, file path, score, and matched terms so you can read the SOP file next.","input_schema":{"type":"object","properties":{"task":{"type":"string","description":"The user task, subtask, or current objective to match against available SOPs."},"limit":{"type":"integer","description":"Optional number of top matches to return. Default 3."}},"required":["task"]}},' +
		'{"name":"record_experience","description":"Record an experience into the local knowledge base and trigger configured automation such as syncing global skills and SOPs. You can either pass payload using the same formats as experience add, or provide structured fields directly.","input_schema":{"type":"object","properties":{"payload":{"type":"string","description":"Optional full payload in JSON, key=value, or pipe format."},"skill":{"type":"string","description":"Skill or domain name."},"title":{"type":"string","description":"Short title of the experience."},"scenario":{"type":"string","description":"Context or triggering scenario."},"action":{"type":"string","description":"Action taken."},"action_taken":{"type":"string","description":"Alias for action."},"outcome":{"type":"string","description":"Observed result."},"tags":{"type":"string","description":"Comma-separated tags."},"confidence":{"type":"integer","description":"Confidence from 1 to 5."},"source":{"type":"string","description":"Optional source label."}},"required":[]}},' +
		'{"name":"session_note","description":"Persistent memory across sessions. Use this to save important context, decisions, project info, or user preferences that should be remembered in future sessions. Actions: read (get all notes), write (overwrite notes), append (add to notes).","input_schema":{"type":"object","properties":{"action":{"type":"string","description":"The action: read, write, or append","enum":["read","write","append"]},"content":{"type":"string","description":"Content to write/append (required for write and append actions)"}},"required":["action"]}},' +
		'{"name":"task_done","description":"Signal that the current task is complete. Call this tool when you have finished the user\'s request and want to provide a final summary. Before calling this, consider if you should update session_note with mid-project decisions, progress, or temporary constraints to help future sessions.","input_schema":{"type":"object","properties":{"result":{"type":"string","description":"A concise summary of what was accomplished"}},"required":["result"]}},' +
		'{"name":"grep_search","description":"Search for a pattern in file contents using regex. Searches recursively in the given directory. Returns matching lines with file paths and line numbers.","input_schema":{"type":"object","properties":{"pattern":{"type":"string","description":"The regex pattern to search for"},"path":{"type":"string","description":"Directory or file to search in (default: current workspace)"},"include":{"type":"string","description":"Only search files matching this glob pattern (e.g. *.v, *.go)"}},"required":["pattern"]}},' +
		'{"name":"find_files","description":"Find files by name pattern. Searches recursively in the given directory. Returns matching file paths.","input_schema":{"type":"object","properties":{"pattern":{"type":"string","description":"File name pattern with wildcards (e.g. *.v, test_*, *.{js,ts})"},"path":{"type":"string","description":"Directory to search in (default: current workspace)"}},"required":["pattern"]}},' +
		'{"name":"sequentialthinking","description":"A tool for structured step-by-step reasoning. Use this to break down complex problems, plan approaches, analyze options, or reason through multi-step tasks before taking action. Each thought can be a revision or branch of a previous thought. The thought process is displayed to the user.","input_schema":{"type":"object","properties":{"thought":{"type":"string","description":"Your current thinking step content"},"thought_number":{"type":"integer","description":"Current thought number (starting from 1)"},"total_thoughts":{"type":"integer","description":"Estimated total number of thoughts needed (can adjust as thinking progresses)"},"next_thought_needed":{"type":"boolean","description":"Whether another thought step is needed after this one"},"is_revision":{"type":"boolean","description":"Whether this revises a previous thought"},"revises_thought":{"type":"integer","description":"If is_revision=true, which thought number this revises"},"branch_from_thought":{"type":"integer","description":"If branching, which thought to branch from"}},"required":["thought","thought_number","total_thoughts","next_thought_needed"]}},' +
		'{"name":"json_edit","description":"View or edit JSON files using dot-notation paths. Actions: view (show JSON content, optionally at a path), set (set or update a value at a path), add (add a new key/value or append to array), remove (delete a key or array element). Examples: path=\\"server.port\\", path=\\"items[0].name\\".","input_schema":{"type":"object","properties":{"action":{"type":"string","description":"The action: view, set, add, or remove","enum":["view","set","add","remove"]},"file":{"type":"string","description":"Path to the JSON file"},"path":{"type":"string","description":"Dot-notation path to the target (e.g. server.port, items[0]). Empty for root."},"value":{"type":"string","description":"(set/add only) The value to set. Will auto-detect type: numbers, booleans, null, or strings."}},"required":["action","file"]}},' +
		'{"name":"ask_user","description":"Ask the user a question to clarify requirements, get preferences, or request missing information. The user\'s response will be returned. Use this when you need more context or the task is ambiguous.","input_schema":{"type":"object","properties":{"question":{"type":"string","description":"The question to ask the user"}},"required":["question"]}},' +
		'{"name":"update_working_checkpoint","description":"Maintain short-term working memory for long tasks. Store key constraints, progress, pitfalls, and related SOP names for later rounds.","input_schema":{"type":"object","properties":{"key_info":{"type":"string","description":"Compact working notes: requirements, progress, pitfalls, and next step."},"related_sop":{"type":"string","description":"Related SOP names or paths."}},"required":[]}},' +
		'{"name":"todo_manager","description":"Manage a TODO task list to track progress on multi-step work. Actions: list (show all tasks), set (replace entire list from text, one task per line), add (add a task), update (change task status by id), clear (remove all tasks). Statuses: pending, in-progress, done.","input_schema":{"type":"object","properties":{"action":{"type":"string","description":"The action: list, set, add, update, or clear","enum":["list","set","add","update","clear"]},"title":{"type":"string","description":"Task title (for add) or full task list text (for set, one task per line)"},"id":{"type":"integer","description":"Task ID (for update)"},"status":{"type":"string","description":"New status for update: pending, in-progress, or done"}},"required":["action"]}},' +
		'{"name":"read_many_files","description":"Read multiple files at once. Supports comma-separated file paths and glob patterns (e.g. *.v, src/*.ts). Returns the concatenated contents of all matched files. Max 20 files per call.","input_schema":{"type":"object","properties":{"paths":{"type":"string","description":"Comma-separated file paths or glob patterns (e.g. src/main.v,src/tools.v or src/*.v)"}},"required":["paths"]}},' +
		'{"name":"activate_skill","description":"Activate a specialized skill to gain expert-level instructions for a specific domain. This loads the full skill prompt into your context. Use this when the task would benefit from specialized expertise. Call with the skill name.","input_schema":{"type":"object","properties":{"name":{"type":"string","description":"The name of the skill to activate (e.g. coder, reviewer, architect, debugger)"}},"required":["name"]}},' +
		'{"name":"cron","description":"Manage cron scheduled tasks. Actions: create (add a cron job), create_once (add a one-time delayed job), list, show, delete, enable, disable, stats, log, run_now (execute immediately), daemon (start/stop/restart/status). When creating a job, if no daemon is running it will be auto-started.","input_schema":{"type":"object","properties":{"action":{"type":"string","description":"Action: create, create_once, list, show, delete, enable, disable, stats, log, run_now, daemon, status"},"name":{"type":"string","description":"Job name (for create, create_once, delete, enable, disable)"},"schedule":{"type":"string","description":"Cron expression like */5 * * * * (for create)"},"delay_seconds":{"type":"integer","description":"Delay in seconds (for create_once)"},"command":{"type":"string","description":"Command to execute when job runs"},"job_id":{"type":"string","description":"Job ID (for show, delete, enable, disable, log, run_now)"},"daemon_action":{"type":"string","description":"Daemon sub-action: start, stop, restart, status (for daemon action)"}},"required":["action"]}},' +
		'{"name":"generate_image","description":"Generate an image from text using the MiniMax image generation API. Supports image-01 and image-01-live.","input_schema":{"type":"object","properties":{"prompt":{"type":"string","description":"Text description of the image to generate. Max 1500 characters."},"model":{"type":"string","description":"Model name: image-01 or image-01-live","enum":["image-01","image-01-live"]},"aspect_ratio":{"type":"string","description":"Image aspect ratio, such as 1:1, 16:9, 4:3, 3:2, 2:3, 3:4, 9:16, or 21:9"},"width":{"type":"integer","description":"Width in pixels for image-01 (512-2048, multiple of 8)."},"height":{"type":"integer","description":"Height in pixels for image-01 (512-2048, multiple of 8)."},"response_format":{"type":"string","description":"Return format: url or base64","enum":["url","base64"]},"seed":{"type":"integer","description":"Optional random seed for reproducible results."},"n":{"type":"integer","description":"Number of images to generate (1-9)."},"prompt_optimizer":{"type":"boolean","description":"Whether to enable prompt optimization."},"aigc_watermark":{"type":"boolean","description":"Whether to add a watermark."},"style":{"type":"string","description":"Raw JSON style object for image-01-live."}},"required":["prompt"]}},' +
		'{"name":"send_mail","description":"Send an email via SMTP. Requires smtp_server, smtp_port, smtp_username, smtp_password configured (via config file or MINIMAX_SMTP_* env vars).","input_schema":{"type":"object","properties":{"mailserver":{"type":"string","description":"SMTP server hostname (optional if configured in config)"},"mailport":{"type":"integer","description":"SMTP port number: 587 (TLS) or 465 (SSL) (optional if configured in config)"},"username":{"type":"string","description":"SMTP username (optional if configured in config)"},"password":{"type":"string","description":"SMTP password (optional if configured in config)"},"from":{"type":"string","description":"Sender email address (optional if configured in config)"},"to":{"type":"string","description":"Recipient email address (optional if smtp_to is configured)"},"subject":{"type":"string","description":"Email subject line"},"body":{"type":"string","description":"Email body content"}},"required":["subject","body"]}}' +
		']'
}

fn execute_tool_use(tool ToolUse) string {
	return execute_tool_use_in_workspace(tool, '', default_config())
}

fn execute_tool_use_in_workspace(tool ToolUse, workspace string, config Config) string {
	match tool.name {
		'str_replace_editor' {
			cmd := tool.input['command'] or { '' }
			path := tool.input['path'] or { '' }
			old_str := tool.input['old_str'] or { '' }
			new_str := tool.input['new_str'] or { '' }
			file_text := tool.input['file_text'] or { '' }
			insert_line_str := tool.input['insert_line'] or { '0' }
			insert_line := insert_line_str.int()
			// Parse view_range from JSON array string like "[10, 20]"
			view_range_raw := tool.input['view_range'] or { '' }
			mut vr_start := 0
			mut vr_end := 0
			if view_range_raw.len > 2 {
				clean := view_range_raw.replace('[', '').replace(']', '').trim_space()
				parts := clean.split(',')
				if parts.len >= 1 {
					vr_start = parts[0].trim_space().int()
				}
				if parts.len >= 2 {
					vr_end = parts[1].trim_space().int()
				}
			}
			return str_replace_editor(cmd, path, old_str, new_str, insert_line, file_text,
				vr_start, vr_end, workspace)
		}
		'bash' {
			cmd := tool.input['command'] or { '' }
			restart_str := tool.input['restart'] or { 'false' }
			if restart_str == 'true' {
				bash_session = new_bash_session(workspace)
				return 'Bash session restarted. cwd=${bash_session.cwd}'
			}
			return bash_session.execute(cmd)
		}
		'read_file' {
			path := resolve_workspace_path(tool.input['path'] or { '' }, workspace)
			if result := read_file_tool(path) {
				return result
			} else {
				return 'Error: ${err.msg()}'
			}
		}
		'write_file' {
			path := resolve_workspace_path(tool.input['path'] or { '' }, workspace)
			content := tool.input['content'] or { '' }
			if result := write_file_tool(path, content) {
				return result
			} else {
				return 'Error: ${err.msg()}'
			}
		}
		'list_dir' {
			path := resolve_workspace_path(tool.input['path'] or { '' }, workspace)
			if result := list_dir_tool(path) {
				return result
			} else {
				return 'Error: ${err.msg()}'
			}
		}
		'run_command' {
			cmd := tool.input['command'] or { '' }
			if result := run_command_in_dir(cmd, workspace) {
				return result
			} else {
				return 'Error: ${err.msg()}'
			}
		}
		'mouse_control' {
			action := tool.input['action'] or { '' }
			x := parse_int_input(tool.input, 'x', -1)
			y := parse_int_input(tool.input, 'y', -1)
			button := tool.input['button'] or { 'left' }
			clicks := parse_int_input(tool.input, 'clicks', 1)
			delta := parse_int_input(tool.input, 'delta', 120)
			return mouse_control_tool(action, x, y, button, clicks, delta)
		}
		'keyboard_control' {
			action := tool.input['action'] or { '' }
			text := tool.input['text'] or { '' }
			keys := tool.input['keys'] or { '' }
			return keyboard_control_tool(action, text, keys)
		}
		'capture_screen' {
			path := resolve_workspace_path(tool.input['path'] or { '' }, workspace)
			x := parse_int_input(tool.input, 'x', 0)
			y := parse_int_input(tool.input, 'y', 0)
			width := parse_int_input(tool.input, 'width', 0)
			height := parse_int_input(tool.input, 'height', 0)
			return capture_screen_tool(path, x, y, width, height)
		}
		'screen_analyze' {
			return 'Error: screen_analyze requires MCP-enabled execution context'
		}
		'match_sop' {
			task := tool.input['task'] or { '' }
			limit := parse_int_input(tool.input, 'limit', 3)
			return match_sop(task, limit)
		}
		'record_experience' {
			return record_experience_from_tool_input(tool.input)
		}
		'session_note' {
			action := tool.input['action'] or { 'read' }
			content := tool.input['content'] or { '' }
			return session_note_tool(action, content)
		}
		'task_done' {
			result := tool.input['result'] or { 'Task completed.' }
			return '__TASK_DONE__:${result}'
		}
		'grep_search' {
			pattern := tool.input['pattern'] or { '' }
			search_path := resolve_workspace_path(tool.input['path'] or { '.' }, workspace)
			include := tool.input['include'] or { '' }
			return grep_search_tool(pattern, search_path, include)
		}
		'find_files' {
			pattern := tool.input['pattern'] or { '' }
			search_path := resolve_workspace_path(tool.input['path'] or { '.' }, workspace)
			return find_files_tool(pattern, search_path)
		}
		'sequentialthinking' {
			thought := tool.input['thought'] or { '' }
			thought_number := (tool.input['thought_number'] or { '1' }).int()
			total_thoughts := (tool.input['total_thoughts'] or { '1' }).int()
			next_str := tool.input['next_thought_needed'] or { 'false' }
			next_needed := next_str == 'true'
			is_rev_str := tool.input['is_revision'] or { 'false' }
			is_revision := is_rev_str == 'true'
			revises := (tool.input['revises_thought'] or { '0' }).int()
			branch := (tool.input['branch_from_thought'] or { '0' }).int()
			return sequentialthinking_tool(thought, thought_number, total_thoughts, next_needed,
				is_revision, revises, branch)
		}
		'json_edit' {
			action := tool.input['action'] or { 'view' }
			file := resolve_workspace_path(tool.input['file'] or { '' }, workspace)
			path := tool.input['path'] or { '' }
			value := tool.input['value'] or { '' }
			return json_edit_tool(action, file, path, value)
		}
		'ask_user' {
			question := tool.input['question'] or { '' }
			return ask_user_tool(question)
		}
		'update_working_checkpoint' {
			key_info := tool.input['key_info'] or { '' }
			related_sop := tool.input['related_sop'] or { '' }
			return update_working_checkpoint_tool(key_info, related_sop)
		}
		'todo_manager' {
			action := tool.input['action'] or { 'list' }
			title := tool.input['title'] or { '' }
			id := (tool.input['id'] or { '0' }).int()
			status := tool.input['status'] or { '' }
			return todo_manager_tool(action, '', id, title, status)
		}
		'read_many_files' {
			paths := tool.input['paths'] or { '' }
			return read_many_files_tool(paths, workspace)
		}
		'activate_skill' {
			name := tool.input['name'] or { '' }
			return activate_skill_tool(name)
		}
		'cron' {
			action := tool.input['action'] or { '' }
			return cron_tool_handler(action, tool.input)
		}
		'send_mail' {
			mailserver := tool.input['mailserver'] or { '' }
			mailport := (tool.input['mailport'] or { '0' }).int()
			username := tool.input['username'] or { '' }
			password := tool.input['password'] or { '' }
			from := tool.input['from'] or { '' }
			to := tool.input['to'] or { '' }
			subject := tool.input['subject'] or { '' }
			body := tool.input['body'] or { '' }
			return send_mail_tool(config, mailserver, mailport, username, password, from,
				to, subject, body)
		}
		'generate_image' {
			return image_generation_tool(config, tool.input)
		}
		else {
			return 'Error: Unknown tool "${tool.name}"'
		}
	}
}

fn print_tool_result(mut client ApiClient, name string, result string) {
	if runtime_is_acp_mode() {
		return
	}
	if term_ui_is_active() {
		term_ui_add_tool_result(name, result)
		return
	}
	client.clear_phase_status_line()
	display_len := if result.len > 120 { 120 } else { result.len }
	display := result[..display_len].replace('\n', ' ').replace('\t', ' ')
	suffix := if result.len > 120 { '...' } else { '' }
	status := if result.starts_with('[error]') || result.starts_with('Error') {
		'\x1b[31m✗\x1b[0m'
	} else {
		'\x1b[32m✓\x1b[0m'
	}
	println('  ${status} \x1b[36m${name}\x1b[0m → \x1b[2m${display}${suffix}\x1b[0m')
}

fn build_mcp_args_json(input map[string]string) string {
	mut args_json := '{'
	for key, val in input {
		args_json += '"${key}":${detect_jq_value(val)},'
	}
	if args_json.ends_with(',') {
		args_json = args_json[..args_json.len - 1]
	}
	args_json += '}'
	return args_json
}

fn execute_tool_use_with_mcp(mut mcp McpManager, tool ToolUse, workspace string, config Config) string {
	if tool.name == 'screen_analyze' {
		return screen_analyze_tool_with_mcp(mut mcp, tool.input, workspace)
	}

	// Try builtin tools first
	builtin_names := ['str_replace_editor', 'bash', 'read_file', 'write_file', 'list_dir',
		'run_command', 'mouse_control', 'keyboard_control', 'capture_screen', 'match_sop',
		'record_experience', 'session_note', 'task_done', 'grep_search', 'find_files',
		'sequentialthinking', 'json_edit', 'ask_user', 'update_working_checkpoint', 'todo_manager',
		'read_many_files', 'activate_skill', 'cron', 'generate_image', 'send_mail']
	if tool.name in builtin_names {
		return execute_tool_use_in_workspace(tool, workspace, config)
	}

	// Try MCP tools
	args_json := build_mcp_args_json(tool.input)

	result := mcp.call_tool(tool.name, args_json) or { return 'Error: ${err.msg()}' }
	return result
}
