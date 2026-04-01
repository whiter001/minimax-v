module main

import os
import time

// BashService manages a persistent bash session with working directory and environment state.
pub struct BashService {
mut:
	cwd     string
	env     map[string]string
	timeout int // seconds
}

// new_bash_session creates a new BashService with the given workspace as initial directory.
pub fn new_bash_session(workspace string) BashService {
	initial_cwd := if workspace.len > 0 && os.is_dir(workspace) { workspace } else { os.getwd() }
	return BashService{
		cwd:     initial_cwd
		env:     {}
		timeout: 120
	}
}

fn find_command_path(command string, fallback_paths []string) string {
	if command.trim_space().len == 0 {
		return ''
	}
	if resolved := os.find_abs_path_of_executable(command) {
		return resolved
	}
	for path in fallback_paths {
		if os.exists(path) {
			return path
		}
	}
	return ''
}

fn find_bash_path() string {
	return find_command_path('bash', [
		'C:\\Program Files\\Git\\bin\\bash.exe',
		'C:\\Program Files (x86)\\Git\\bin\\bash.exe',
		'/usr/bin/bash',
		'/bin/bash',
	])
}

fn find_pwsh_path() string {
	return find_command_path('pwsh', [
		'C:\\Program Files\\PowerShell\\7\\pwsh.exe',
		'C:\\Program Files\\PowerShell\\7-preview\\pwsh.exe',
	])
}

fn extract_tool_command_head(command string) string {
	trimmed := command.trim_space()
	if trimmed.len == 0 {
		return ''
	}
	if trimmed[0] == `"` || trimmed[0] == `'` {
		quote := trimmed[0]
		for i := 1; i < trimmed.len; i++ {
			if trimmed[i] == quote {
				return trimmed[1..i]
			}
		}
		return trimmed[1..]
	}
	for i := 0; i < trimmed.len; i++ {
		if trimmed[i] in [` `, `\t`, `\n`, `\r`, `;`, `&`, `|`, `>`, `<`] {
			return trimmed[..i]
		}
	}
	return trimmed
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

fn (mut s BashService) execute_with_windows_pwsh(command string) string {
	pwsh_path := find_pwsh_path()
	if pwsh_path.len == 0 {
		return ''
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
	result := os.execute('"${pwsh_path}" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "${tmp_ps}"')
	mut output := result.output
	exit_code := result.exit_code

	output = update_session_cwd_from_marker(mut s, output, '__PWSH_CWD__=', false)
	return format_shell_result(exit_code, s.cwd, output)
}

fn update_session_cwd_from_marker(mut s BashService, output string, marker string, convert_bash_path bool) string {
	if cwd_idx := output.index(marker) {
		cwd_line := output[cwd_idx + marker.len..]
		newline_idx := cwd_line.index('\n') or { cwd_line.len }
		new_cwd_raw := cwd_line[..newline_idx].trim_space()
		new_cwd := if convert_bash_path && new_cwd_raw.starts_with('/') && new_cwd_raw.len >= 3
			&& new_cwd_raw[2] == `/` {
			new_cwd_raw[1..2].to_upper() + ':' + new_cwd_raw[2..].replace('/', '\\')
		} else {
			new_cwd_raw
		}
		if new_cwd.len > 0 && os.is_dir(new_cwd) {
			s.cwd = new_cwd
		}
		return output[..cwd_idx].trim_right('\n ')
	}
	return output
}

fn format_shell_result(exit_code int, cwd string, output string) string {
	if exit_code != 0 {
		return 'Exit code: ${exit_code}\n[cwd: ${cwd}]\n${output}'
	}
	return '${output}\n[cwd: ${cwd}]'
}

// execute runs a command in the bash session, preserving cwd and env state.
// It checks for dangerous commands and supports Windows Git Bash and PowerShell.
pub fn (mut s BashService) execute(command string) string {
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
		mut p := os.new_process(bash_path)
		p.set_args(['-c', bash_c_arg])
		p.set_work_folder(s.cwd)
		p.use_stdio_ctl = true
		p.run()
		mut output := p.stdout_slurp()
		output += p.stderr_slurp()
		p.wait()
		exit_code := p.code
		p.close()

		output = update_session_cwd_from_marker(mut s, output, '__CWD_MARKER__=', true)
		return format_shell_result(exit_code, s.cwd, output)
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

		output = update_session_cwd_from_marker(mut s, output, '__CMD_CWD__=', false)
		return format_shell_result(result.exit_code, s.cwd, output)
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
