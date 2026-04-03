module main

import os
import time

const max_command_prompt_chars = 120000
const max_command_file_chars = 50000
const max_command_inject_output_chars = 10000
const max_command_inject_files = 20
const max_command_inject_depth = 4

pub struct CustomCommand {
pub mut:
	name        string
	description string
	prompt      string
	source      string // builtin | user | project | extension
	path        string
	extension   string
}

struct CommandRegistry {
mut:
	commands  []CustomCommand
	loaded    bool
	workspace string
}

struct ExtensionManifest {
	name          string
	version       string
	commands_path string
	mcp_servers   []string
	mcp_configs   []McpServerConfig
}

struct ExtensionInfo {
	name         string
	version      string
	root_dir     string
	commands_dir string
	mcp_servers  []string
	mcp_configs  []McpServerConfig
	source_path  string
	source_ref   string
	source_kind  string
	updated_at   i64
	enabled      bool
}

struct ExtensionMcpServer {
	extension_name string
	config         McpServerConfig
}

struct InjectionOptions {
mut:
	ext_filters      []string
	include_patterns []string
	exclude_patterns []string
	max_files        int
}

fn command_source_priority(source string) int {
	return match source {
		'project' { 4 }
		'user' { 3 }
		'extension' { 2 }
		else { 1 }
	}
}

fn load_command_registry(workspace string) CommandRegistry {
	mut registry := CommandRegistry{
		commands:  []CustomCommand{}
		loaded:    true
		workspace: workspace
	}

	for cmd in get_builtin_custom_commands() {
		add_or_override_custom_command(mut registry, cmd)
	}

	load_custom_commands_from_dir(get_user_commands_dir(), 'user', '', mut registry)
	if workspace.len > 0 {
		load_custom_commands_from_dir(os.join_path(workspace, '.minimax', 'commands'),
			'project', '', mut registry)
	}

	for ext in discover_extensions() {
		if ext.enabled && os.is_dir(ext.commands_dir) {
			load_custom_commands_from_dir(ext.commands_dir, 'extension', ext.name, mut
				registry)
		}
	}

	return registry
}

fn init_command_registry(workspace string) CommandRegistry {
	return load_command_registry(workspace)
}

fn reload_command_registry(workspace string) CommandRegistry {
	return load_command_registry(workspace)
}

fn add_or_override_custom_command(mut registry CommandRegistry, new_cmd CustomCommand) {
	for i, existing in registry.commands {
		if existing.name == new_cmd.name {
			if command_source_priority(new_cmd.source) >= command_source_priority(existing.source) {
				registry.commands[i] = new_cmd
			}
			return
		}
	}
	registry.commands << new_cmd
}

fn command_name_exists(commands []CustomCommand, name string) bool {
	for cmd in commands {
		if cmd.name == name {
			return true
		}
	}
	return false
}

fn sanitize_extension_name(name string) string {
	mut sanitized := name.trim_space()
	sanitized = sanitized.replace(' ', '-').replace(':', '-').replace('/', '-').replace('\\',
		'-')
	if sanitized.len == 0 {
		return 'extension'
	}
	return sanitized
}

fn build_extension_prefixed_name(extension_name string, base_name string) string {
	return 'ext:${sanitize_extension_name(extension_name)}:${base_name}'
}

fn ensure_unique_command_name(commands []CustomCommand, base_name string) string {
	if !command_name_exists(commands, base_name) {
		return base_name
	}
	mut i := 2
	for {
		candidate := '${base_name}-${i}'
		if !command_name_exists(commands, candidate) {
			return candidate
		}
		i++
	}
	return base_name
}

fn get_all_custom_commands(workspace string) []CustomCommand {
	registry := load_command_registry(workspace)
	mut cmds := registry.commands.clone()
	cmds.sort(a.name < b.name)
	return cmds
}

fn find_custom_command(workspace string, name string) ?CustomCommand {
	registry := load_command_registry(workspace)
	for cmd in registry.commands {
		if cmd.name == name {
			return cmd
		}
	}
	return none
}

fn get_user_commands_dir() string {
	return os.join_path(get_minimax_config_dir(), 'commands')
}

fn normalize_path_separators(path string) string {
	return path.replace('\\', '/')
}

fn get_minimax_config_dir() string {
	if custom := os.getenv_opt('MINIMAX_CONFIG_HOME') {
		trimmed := custom.trim_space()
		if trimmed.len > 0 {
			return trimmed
		}
	}
	return os.join_path(get_user_home_dir(), '.config', 'minimax')
}

fn command_name_from_toml_path(root string, full_path string) string {
	mut normalized_root := normalize_path_separators(root).trim_right('/')
	mut normalized_path := normalize_path_separators(full_path)
	if normalized_root.len > 0 && normalized_path.starts_with(normalized_root + '/') {
		normalized_path = normalized_path[normalized_root.len + 1..]
	} else {
		normalized_path = os.base(full_path)
	}
	if normalized_path.to_lower().ends_with('.toml') {
		normalized_path = normalized_path[..normalized_path.len - 5]
	}
	return normalized_path.trim_left('/').trim_right('/').replace('/', ':')
}

fn load_custom_commands_from_dir(dir string, source string, extension_name string, mut registry CommandRegistry) {
	if !os.is_dir(dir) {
		return
	}
	mut files := []string{}
	collect_toml_files_recursive(dir, 0, mut files)
	for path in files {
		mut name := command_name_from_toml_path(dir, path)
		if name.len == 0 {
			continue
		}
		if source == 'extension' && extension_name.len > 0
			&& command_name_exists(registry.commands, name) {
			name = ensure_unique_command_name(registry.commands, build_extension_prefixed_name(extension_name,
				name))
		}
		if cmd := parse_command_toml(path, name, source, extension_name) {
			add_or_override_custom_command(mut registry, cmd)
		}
	}
}

fn collect_toml_files_recursive(dir string, depth int, mut files []string) {
	if depth > max_command_inject_depth {
		return
	}
	entries := os.ls(dir) or { return }
	for entry in entries {
		path := os.join_path(dir, entry)
		if os.is_dir(path) {
			collect_toml_files_recursive(path, depth + 1, mut files)
			continue
		}
		if path.to_lower().ends_with('.toml') {
			files << path
		}
	}
}

fn extract_toml_multiline_string(content string, key string) string {
	pattern_double := '${key} = """'
	if idx := content.index(pattern_double) {
		start := idx + pattern_double.len
		rest := content[start..]
		if end_idx := rest.index('"""') {
			return rest[..end_idx]
		}
	}

	pattern_single := '${key} = \'\'\''
	if idx := content.index(pattern_single) {
		start := idx + pattern_single.len
		rest := content[start..]
		if end_idx := rest.index("'''") {
			return rest[..end_idx]
		}
	}
	return ''
}

fn find_unescaped_quote(raw string, start int, quote u8) ?int {
	mut i := start
	for i < raw.len {
		if raw[i] == quote {
			if i == 0 || raw[i - 1] != `\\` {
				return i
			}
		}
		i++
	}
	return none
}

fn extract_toml_single_line_string(content string, key string) string {
	for line in content.split('\n') {
		trimmed := line.trim_space()
		if trimmed.len == 0 || trimmed.starts_with('#') || !trimmed.starts_with('${key}') {
			continue
		}
		eq_idx := trimmed.index('=') or { continue }
		raw := trimmed[eq_idx + 1..].trim_space()
		if raw.starts_with('"') {
			if end_idx := find_unescaped_quote(raw, 1, `"`) {
				return raw[1..end_idx].replace('\\"', '"').replace('\\n', '\n').replace('\\t',
					'\t')
			}
		} else if raw.starts_with("'") {
			if end_idx := find_unescaped_quote(raw, 1, `'`) {
				return raw[1..end_idx]
			}
		}
	}
	return ''
}

fn parse_command_toml(path string, name string, source string, extension_name string) ?CustomCommand {
	content := os.read_file(path) or { return none }
	mut prompt := extract_toml_multiline_string(content, 'prompt')
	if prompt.len == 0 {
		prompt = extract_toml_single_line_string(content, 'prompt')
	}
	prompt = prompt.trim_space()
	if prompt.len == 0 {
		return none
	}

	mut description := extract_toml_multiline_string(content, 'description')
	if description.len == 0 {
		description = extract_toml_single_line_string(content, 'description')
	}
	description = description.trim_space()
	if description.len == 0 {
		description = 'Custom command: ${name}'
	}

	return CustomCommand{
		name:        name
		description: description
		prompt:      prompt
		source:      source
		path:        path
		extension:   extension_name
	}
}

fn parse_custom_command_invocation(input string) !(string, string) {
	trimmed := input.trim_space()
	if !trimmed.starts_with('/') {
		return error('命令必须以 / 开头')
	}
	body := trimmed[1..].trim_space()
	if body.len == 0 {
		return error('用法: /<command> [args]')
	}
	if sep := body.index(' ') {
		name := body[..sep].trim_space()
		args := body[sep + 1..].trim_space()
		return name, args
	}
	return body, ''
}

fn render_custom_command_prompt(cmd CustomCommand, args string, workspace string, interactive bool, mut bash_session BashSession) !string {
	mut rendered := cmd.prompt.replace('{{args}}', args)
	rendered = process_shell_injections(rendered, interactive, mut bash_session)!
	rendered = process_file_injections(rendered, workspace)!
	if rendered.len > max_command_prompt_chars {
		return error('命令渲染后内容过长 (${rendered.len} chars)，请缩小输入范围')
	}
	return rendered.trim_space()
}

fn process_shell_injections(input string, interactive bool, mut bash_session BashSession) !string {
	mut rendered := input
	for {
		start := rendered.index('!{') or { break }
		rest := rendered[start + 2..]
		end_rel := rest.index('}') or { return error('命令模板语法错误: !{...} 缺少 }') }
		end := start + 2 + end_rel
		command := rendered[start + 2..end].trim_space()
		if command.len == 0 {
			return error('命令模板语法错误: !{...} 不能为空')
		}
		if interactive {
			println('\x1b[33m⚠️  即将执行命令注入: ${command}\x1b[0m')
			confirm := os.input('继续执行? [y/N]: ').trim_space().to_lower()
			if confirm !in ['y', 'yes'] {
				return error('已取消命令执行')
			}
		} else if !allow_noninteractive_shell_injection() {
			return error('非交互模式已禁用 !{...} 命令注入，请设置 MINIMAX_ALLOW_NONINTERACTIVE_INJECTION=true 后重试')
		}
		mut output := bash_session.execute(command).trim_space()
		if output.len > max_command_inject_output_chars {
			output = utf8_safe_truncate(output, max_command_inject_output_chars) +
				'\n... (truncated, ${output.len} chars total)'
		}
		rendered = rendered[..start] + output + rendered[end + 1..]
	}
	return rendered
}

fn allow_noninteractive_shell_injection() bool {
	if val := os.getenv_opt('MINIMAX_ALLOW_NONINTERACTIVE_INJECTION') {
		normalized := val.trim_space().to_lower()
		if normalized in ['1', 'true', 'yes', 'on', 'allow'] {
			return true
		}
		if normalized in ['0', 'false', 'no', 'off', 'deny', 'block'] {
			return false
		}
	}
	return true
}

fn process_file_injections(input string, workspace string) !string {
	mut rendered := input
	for {
		start := rendered.index('@{') or { break }
		rest := rendered[start + 2..]
		end_rel := rest.index('}') or { return error('命令模板语法错误: @{...} 缺少 }') }
		end := start + 2 + end_rel
		mut target := rendered[start + 2..end].trim_space()
		target = target.trim('"').trim("'")
		if target.len == 0 {
			return error('命令模板语法错误: @{...} 路径不能为空')
		}
		base_target, opts := parse_injection_target(target)
		content := load_injection_target(base_target, workspace, opts)!
		rendered = rendered[..start] + content + rendered[end + 1..]
	}
	return rendered
}

fn parse_injection_target(raw string) (string, InjectionOptions) {
	mut opts := InjectionOptions{
		ext_filters:      []string{}
		include_patterns: []string{}
		exclude_patterns: []string{}
		max_files:        max_command_inject_files
	}
	if !raw.contains('?') {
		return raw, opts
	}
	q_idx := raw.index('?') or { return raw, opts }
	base := raw[..q_idx].trim_space()
	query := raw[q_idx + 1..].trim_space()
	if query.len == 0 {
		return base, opts
	}
	for pair in query.split('&') {
		item := pair.trim_space()
		if item.len == 0 || !item.contains('=') {
			continue
		}
		eq_idx := item.index('=') or { continue }
		key := item[..eq_idx].trim_space().to_lower()
		val := item[eq_idx + 1..].trim_space()
		if val.len == 0 {
			continue
		}
		match key {
			'ext', 'type' {
				for ext in val.split(',') {
					mut e := ext.trim_space().to_lower()
					if e.len == 0 {
						continue
					}
					if !e.starts_with('.') {
						e = '.' + e
					}
					if e !in opts.ext_filters {
						opts.ext_filters << e
					}
				}
			}
			'include' {
				for token in val.split(',') {
					p := token.trim_space().to_lower()
					if p.len > 0 {
						opts.include_patterns << p
					}
				}
			}
			'exclude' {
				for token in val.split(',') {
					p := token.trim_space().to_lower()
					if p.len > 0 {
						opts.exclude_patterns << p
					}
				}
			}
			'max', 'max_files' {
				parsed := val.int()
				if parsed > 0 {
					opts.max_files = if parsed > 200 { 200 } else { parsed }
				}
			}
			else {}
		}
	}
	return base, opts
}

fn path_relative_to(base string, full string) string {
	mut base_norm := normalize_path_separators(base).trim_right('/')
	mut full_norm := normalize_path_separators(full)
	if full_norm.starts_with(base_norm + '/') {
		full_norm = full_norm[base_norm.len + 1..]
	}
	return full_norm
}

fn collect_injection_files(dir string, depth int, max_files int, mut files []string) {
	if depth > max_command_inject_depth || files.len >= max_files {
		return
	}
	entries := os.ls(dir) or { return }
	for entry in entries {
		if files.len >= max_files {
			break
		}
		path := os.join_path(dir, entry)
		if os.is_dir(path) {
			collect_injection_files(path, depth + 1, max_files, mut files)
		} else if os.is_file(path) {
			files << path
		}
	}
}

fn should_include_injection_file(root string, file string, opts InjectionOptions) bool {
	rel := path_relative_to(root, file).to_lower()
	if opts.ext_filters.len > 0 {
		ext := os.file_ext(file).to_lower()
		if ext !in opts.ext_filters {
			return false
		}
	}
	if opts.include_patterns.len > 0 {
		mut matched := false
		for p in opts.include_patterns {
			if rel.contains(p) {
				matched = true
				break
			}
		}
		if !matched {
			return false
		}
	}
	for p in opts.exclude_patterns {
		if rel.contains(p) {
			return false
		}
	}
	return true
}

fn load_injection_target(target string, workspace string, opts InjectionOptions) !string {
	resolved := resolve_workspace_path(target, workspace)
	if os.is_file(resolved) {
		content := os.read_file(resolved)!
		mut display := content
		if content.len > max_command_file_chars {
			display = utf8_safe_truncate(content, max_command_file_chars) +
				'\n... (truncated, ${content.len} chars total)'
		}
		return '--- File: ${target} ---\n${display}\n--- End: ${target} ---'
	}
	if os.is_dir(resolved) {
		mut files := []string{}
		collect_injection_files(resolved, 0, opts.max_files, mut files)
		if files.len == 0 {
			return error('目录为空或没有可读取文件: ${target}')
		}
		mut blocks := []string{}
		for file in files {
			if !should_include_injection_file(resolved, file, opts) {
				continue
			}
			content := os.read_file(file) or { continue }
			if content.contains('\x00') {
				continue
			}
			rel := path_relative_to(resolved, file)
			mut display := content
			if content.len > max_command_file_chars {
				display = utf8_safe_truncate(content, max_command_file_chars) +
					'\n... (truncated, ${content.len} chars total)'
			}
			blocks << '--- File: ${target}/${rel} ---\n${display}\n--- End: ${target}/${rel} ---'
			if blocks.len >= opts.max_files {
				break
			}
		}
		if blocks.len == 0 {
			return error('目录内没有匹配过滤条件的文本文件: ${target}')
		}
		return blocks.join('\n\n')
	}
	return error('注入路径不存在: ${target}')
}

fn execute_custom_command(mut client ApiClient, input string, interactive bool) !string {
	name, args := parse_custom_command_invocation(input)!
	cmd := find_custom_command(client.workspace, name) or {
		return error('未知命令: /${name}，可用命令请执行 "commands list"')
	}
	rendered := render_custom_command_prompt(cmd, args, client.workspace, interactive
		&& !client.silent_mode, mut client.bash_session)!
	if client.debug && !client.silent_mode {
		println('\x1b[2m[command] /${name} (${rendered.len} chars)\x1b[0m')
	}
	return client.chat(rendered)
}

fn format_custom_command_source(cmd CustomCommand) string {
	if cmd.source == 'extension' && cmd.extension.len > 0 {
		return 'extension:${cmd.extension}'
	}
	return cmd.source
}

fn list_custom_commands_text(workspace string) string {
	commands := get_all_custom_commands(workspace)
	if commands.len == 0 {
		return '📜 无可用自定义命令（可在 ~/.config/minimax/commands 或 .minimax/commands 添加）'
	}
	mut lines := ['📜 可用命令:']
	for cmd in commands {
		lines << '  /${cmd.name}  - ${cmd.description} [${format_custom_command_source(cmd)}]'
	}
	return lines.join('\n')
}

fn show_custom_command_text(workspace string, name string) string {
	cmd := find_custom_command(workspace, name) or { return 'Error: 未找到命令 /${name}' }
	mut lines := []string{}
	lines << '命令: /${cmd.name}'
	lines << '描述: ${cmd.description}'
	lines << '来源: ${format_custom_command_source(cmd)}'
	if cmd.path.len > 0 {
		lines << '路径: ${cmd.path}'
	}
	lines << ''
	lines << 'Prompt:'
	lines << cmd.prompt
	return lines.join('\n')
}

fn get_builtin_custom_commands() []CustomCommand {
	return [
		CustomCommand{
			name:        'git:commit'
			description: '基于 staged diff 生成 Conventional Commit 提交信息'
			prompt:
				'请根据下面的 staged diff 生成 1 条 Conventional Commit 提交信息。' +
				'\n要求：' + '\n1) 输出一个简洁标题（<type>(<scope>): <subject>）' +
				'\n2) 给出 3-6 条关键变更点' +
				'\n3) 如果有破坏性变更，明确标记 BREAKING CHANGE' +
				'\n4) 附加上下文：{{args}}' + '\n\nStaged diff:\n!{git diff --staged}'
			source:      'builtin'
		},
		CustomCommand{
			name:        'fs:grep-code'
			description: '按模式搜索代码并总结命中结果'
			prompt:      'Please summarize the findings for the pattern `{{args}}`.' +
				'\n\nSearch Results:\n!{grep -R "{{args}}" .}'
			source:      'builtin'
		},
		CustomCommand{
			name:        'review:file'
			description: '对目标文件做代码审查并给出修复建议'
			prompt:
				'请对目标文件做代码审查（正确性/安全性/可维护性），并按严重级别输出问题与建议。' +
				'\n目标文件: {{args}}' + '\n\n文件内容:\n@{ {{args}} }'
			source:      'builtin'
		},
		CustomCommand{
			name:        'refactor:pure'
			description: '将目标逻辑重构为更纯函数风格并解释改动'
			prompt:
				'请将目标文件中的核心逻辑重构为更纯函数风格，保持行为不变，并给出关键改动说明。' +
				'\n目标文件: {{args}}' + '\n\n文件内容:\n@{ {{args}} }'
			source:      'builtin'
		},
		CustomCommand{
			name:        'changelog:add'
			description: '基于输入内容生成 CHANGELOG 条目草稿'
			prompt:
				'请根据以下变更说明，生成规范的 CHANGELOG 条目草稿（不编造未发生的改动）。' +
				'\n输入: {{args}}' + '\n\n现有 CHANGELOG:\n@{ CHANGELOG.md }'
			source:      'builtin'
		},
		CustomCommand{
			name:        'git:pr-summary'
			description: '生成 PR 描述草稿（摘要/风险/测试）'
			prompt:
				'请基于当前分支改动生成 PR 描述草稿，包含：Summary、Changes、Risks、Test Plan。' +
				'\n补充上下文: {{args}}' + '\n\nDiff stat:\n!{git diff --stat}' +
				'\n\nRecent commits:\n!{git log --oneline -20}'
			source:      'builtin'
		},
	]
}

fn get_extensions_root_dir() string {
	root := os.join_path(get_minimax_config_dir(), 'extensions')
	if !os.is_dir(root) {
		os.mkdir_all(root) or {}
	}
	return root
}

fn get_extension_state_file(ext_root string) string {
	return os.join_path(ext_root, '.minimax-extension-state.json')
}

fn write_extension_state(ext_root string, source_path string, source_kind string, source_ref string) ! {
	state := '{"source_path":"${escape_json_string(source_path)}","source_kind":"${escape_json_string(source_kind)}","source_ref":"${escape_json_string(source_ref)}","updated_at":${time.now().unix()}}'
	os.write_file(get_extension_state_file(ext_root), state)!
}

fn read_extension_state_value(ext_root string, key string) string {
	state_file := get_extension_state_file(ext_root)
	if !os.is_file(state_file) {
		return ''
	}
	content := os.read_file(state_file) or { return '' }
	raw := extract_json_string_value(content, key).trim_space()
	return raw.replace('\\n', '\n').replace('\\"', '"').replace('\\\\', '\\')
}

fn read_extension_source_path(ext_root string) string {
	return read_extension_state_value(ext_root, 'source_path')
}

fn read_extension_source_kind(ext_root string) string {
	kind := read_extension_state_value(ext_root, 'source_kind')
	if kind.len == 0 {
		return 'path'
	}
	return kind
}

fn read_extension_source_ref(ext_root string) string {
	return read_extension_state_value(ext_root, 'source_ref')
}

fn read_extension_updated_at(ext_root string) i64 {
	state_file := get_extension_state_file(ext_root)
	if !os.is_file(state_file) {
		return 0
	}
	content := os.read_file(state_file) or { return 0 }
	return extract_json_number_value(content, 'updated_at')
}

fn get_extensions_disabled_file() string {
	return os.join_path(get_extensions_root_dir(), '.disabled')
}

fn read_disabled_extensions() map[string]bool {
	path := get_extensions_disabled_file()
	if !os.is_file(path) {
		return map[string]bool{}
	}
	content := os.read_file(path) or { return map[string]bool{} }
	mut disabled := map[string]bool{}
	for line in content.split('\n') {
		name := line.trim_space()
		if name.len > 0 && !name.starts_with('#') {
			disabled[name] = true
		}
	}
	return disabled
}

fn write_disabled_extensions(disabled map[string]bool) ! {
	mut names := []string{}
	for name, state in disabled {
		if state {
			names << name
		}
	}
	names.sort()
	os.write_file(get_extensions_disabled_file(), names.join('\n'))!
}

fn parse_extension_manifest(path string) ?ExtensionManifest {
	content := os.read_file(path) or { return none }
	name := extract_json_string_value(content, 'name').trim_space()
	if name.len == 0 {
		return none
	}
	ext_version := extract_json_string_value(content, 'version').trim_space()
	commands_path := extract_json_string_value(content, 'commands').trim_space()
	mcp_servers := parse_manifest_mcp_servers(content)
	mcp_configs := parse_manifest_mcp_server_configs(content)
	return ExtensionManifest{
		name:          name
		version:       ext_version
		commands_path: commands_path
		mcp_servers:   mcp_servers
		mcp_configs:   mcp_configs
	}
}

fn extract_manifest_mcp_servers_block(content string) string {
	if start := find_json_object(content, '"mcpServers"') {
		end := find_matching_bracket(content, start)
		if end > start {
			return content[start..end + 1]
		}
	}
	return ''
}

fn parse_top_level_object_keys(obj string) []string {
	if obj.len < 2 || obj[0] != `{` {
		return []string{}
	}
	mut keys := []string{}
	mut pos := 1
	for pos < obj.len {
		for pos < obj.len && obj[pos] in [u8(` `), `,`, `\n`, `\t`, `\r`] {
			pos++
		}
		if pos >= obj.len || obj[pos] == `}` {
			break
		}
		if pos + 1 < obj.len && obj[pos] == `/` && obj[pos + 1] == `/` {
			for pos < obj.len && obj[pos] != `\n` {
				pos++
			}
			continue
		}
		if obj[pos] != `"` {
			pos++
			continue
		}

		pos++
		mut key_end := pos
		for key_end < obj.len {
			if obj[key_end] == `\\` {
				key_end += 2
				continue
			}
			if obj[key_end] == `"` {
				break
			}
			key_end++
		}
		if key_end >= obj.len {
			break
		}
		key := obj[pos..key_end]
		if key.len > 0 {
			keys << key
		}
		pos = key_end + 1

		for pos < obj.len && obj[pos] in [u8(` `), `\n`, `\t`, `\r`] {
			pos++
		}
		if pos >= obj.len || obj[pos] != `:` {
			continue
		}
		pos++
		for pos < obj.len && obj[pos] in [u8(` `), `\n`, `\t`, `\r`] {
			pos++
		}
		if pos >= obj.len {
			break
		}

		if obj[pos] == `{` || obj[pos] == `[` {
			value_end := find_matching_bracket(obj, pos)
			if value_end <= pos {
				break
			}
			pos = value_end + 1
		} else if obj[pos] == `"` {
			pos++
			for pos < obj.len {
				if obj[pos] == `\\` {
					pos += 2
					continue
				}
				if obj[pos] == `"` {
					pos++
					break
				}
				pos++
			}
		} else {
			for pos < obj.len && obj[pos] != `,` && obj[pos] != `}` {
				pos++
			}
		}
	}
	return keys
}

fn parse_manifest_mcp_servers(content string) []string {
	block := extract_manifest_mcp_servers_block(content)
	if block.len == 0 {
		return []string{}
	}
	return parse_top_level_object_keys(block)
}

fn parse_manifest_mcp_server_configs(content string) []McpServerConfig {
	block := extract_manifest_mcp_servers_block(content)
	if block.len == 0 {
		return []McpServerConfig{}
	}
	wrapped := '{"servers":${block}}'
	return parse_mcp_config(wrapped)
}

fn discover_extensions() []ExtensionInfo {
	root := get_extensions_root_dir()
	entries := os.ls(root) or { return []ExtensionInfo{} }
	disabled := read_disabled_extensions()
	mut exts := []ExtensionInfo{}
	for entry in entries {
		ext_root := os.join_path(root, entry)
		if !os.is_dir(ext_root) {
			continue
		}
		mut manifest_path := os.join_path(ext_root, 'minimax-extension.json')
		if !os.is_file(manifest_path) {
			manifest_path = os.join_path(ext_root, 'gemini-extension.json')
		}
		if !os.is_file(manifest_path) {
			continue
		}
		manifest := parse_extension_manifest(manifest_path) or { continue }
		commands_dir := if manifest.commands_path.len > 0 {
			os.join_path(ext_root, manifest.commands_path)
		} else {
			os.join_path(ext_root, 'commands')
		}
		source_path := read_extension_source_path(ext_root)
		source_kind := read_extension_source_kind(ext_root)
		source_ref := read_extension_source_ref(ext_root)
		updated_at := read_extension_updated_at(ext_root)
		enabled := !(disabled[manifest.name] or { false })
		exts << ExtensionInfo{
			name:         manifest.name
			version:      manifest.version
			root_dir:     ext_root
			commands_dir: commands_dir
			mcp_servers:  manifest.mcp_servers
			mcp_configs:  manifest.mcp_configs
			source_path:  source_path
			source_kind:  source_kind
			source_ref:   source_ref
			updated_at:   updated_at
			enabled:      enabled
		}
	}
	exts.sort(a.name < b.name)
	return exts
}

fn collect_enabled_extension_mcp_servers(exts []ExtensionInfo) []ExtensionMcpServer {
	mut servers := []ExtensionMcpServer{}
	for ext in exts {
		if !ext.enabled {
			continue
		}
		for cfg in ext.mcp_configs {
			servers << ExtensionMcpServer{
				extension_name: ext.name
				config:         cfg
			}
		}
	}
	return servers
}

fn get_enabled_extension_mcp_servers() []ExtensionMcpServer {
	return collect_enabled_extension_mcp_servers(discover_extensions())
}

fn reserve_unique_mcp_server_name(extension_name string, base_name string, mut used map[string]bool) string {
	mut candidate := base_name
	if !(used[candidate] or { false }) {
		used[candidate] = true
		return candidate
	}
	mut prefixed := 'ext:${sanitize_extension_name(extension_name)}:${base_name}'
	mut idx := 2
	for used[prefixed] or { false } {
		prefixed = 'ext:${sanitize_extension_name(extension_name)}:${base_name}-${idx}'
		idx++
	}
	used[prefixed] = true
	return prefixed
}

fn add_extension_mcp_servers(mut manager McpManager) int {
	servers := get_enabled_extension_mcp_servers()
	if servers.len == 0 {
		return 0
	}
	mut used := map[string]bool{}
	for server in manager.servers {
		used[server.name] = true
	}
	mut added := 0
	for ext_server in servers {
		server_name := reserve_unique_mcp_server_name(ext_server.extension_name, ext_server.config.name, mut
			used)
		manager.add_server(server_name, ext_server.config.command, ext_server.config.args,
			ext_server.config.env)
		added++
	}
	return added
}

fn list_extensions_text() string {
	exts := discover_extensions()
	if exts.len == 0 {
		return '📦 暂无扩展（安装目录: ~/.config/minimax/extensions）'
	}
	mut lines := ['📦 扩展列表:']
	for ext in exts {
		status := if ext.enabled { 'enabled' } else { 'disabled' }
		ext_version := if ext.version.len > 0 { ext.version } else { 'unknown' }
		lines << '  - ${ext.name} (${ext_version}) [${status}]'
		source_display := if ext.source_kind == 'git' && ext.source_ref.len > 0 {
			ext.source_ref
		} else {
			ext.source_path
		}
		if source_display.len > 0 {
			lines << '      source: ${source_display}'
		}
		if ext.updated_at > 0 {
			lines << '      updated: ${time.unix(ext.updated_at).format_ss()}'
		}
		if ext.mcp_servers.len > 0 {
			lines << '      mcpServers: ${ext.mcp_servers.join(', ')}'
		}
	}
	return lines.join('\n')
}

fn show_extension_text(name string) string {
	ext := find_extension_info(name) or { return 'Error: 未找到扩展: ${name}' }
	mut lines := []string{}
	lines << '扩展: ${ext.name}'
	lines << '版本: ${if ext.version.len > 0 { ext.version } else { 'unknown' }}'
	lines << '状态: ${if ext.enabled { 'enabled' } else { 'disabled' }}'
	lines << '目录: ${ext.root_dir}'
	lines << '命令目录: ${ext.commands_dir}'
	if ext.source_kind.len > 0 {
		lines << '来源类型: ${ext.source_kind}'
	}
	if ext.source_ref.len > 0 {
		lines << '来源引用: ${ext.source_ref}'
	}
	if ext.source_path.len > 0 {
		lines << '来源路径: ${ext.source_path}'
	}
	if ext.updated_at > 0 {
		lines << '更新时间: ${time.unix(ext.updated_at).format_ss()}'
	}
	if ext.mcp_servers.len > 0 {
		lines << 'mcpServers: ${ext.mcp_servers.join(', ')}'
	}
	return lines.join('\n')
}

fn copy_directory_recursive(src string, dst string) ! {
	os.mkdir_all(dst)!
	entries := os.ls(src)!
	for entry in entries {
		src_path := os.join_path(src, entry)
		dst_path := os.join_path(dst, entry)
		if os.is_dir(src_path) {
			copy_directory_recursive(src_path, dst_path)!
		} else {
			os.cp(src_path, dst_path)!
		}
	}
}

fn is_probable_git_source(source string) bool {
	s := source.trim_space().to_lower()
	return s.starts_with('http://') || s.starts_with('https://') || s.starts_with('ssh://')
		|| s.starts_with('git@') || s.ends_with('.git')
}

fn sanitize_path_component(input string) string {
	mut out := []u8{}
	for ch in input.bytes() {
		if (ch >= `a` && ch <= `z`) || (ch >= `A` && ch <= `Z`) || (ch >= `0` && ch <= `9`) {
			out << ch
		} else {
			out << `_`
		}
		if out.len >= 80 {
			break
		}
	}
	if out.len == 0 {
		return 'source'
	}
	return out.bytestr()
}

fn get_extension_sources_root_dir() string {
	dir := os.join_path(get_extensions_root_dir(), '.sources')
	if !os.is_dir(dir) {
		os.mkdir_all(dir) or {}
	}
	return dir
}

fn get_git_source_checkout_dir(source_ref string) string {
	return os.join_path(get_extension_sources_root_dir(), sanitize_path_component(source_ref))
}

fn ensure_git_source_checkout(source_ref string, checkout_dir string) ! {
	if os.is_dir(os.join_path(checkout_dir, '.git')) {
		result := os.execute('git -C "${checkout_dir}" pull --ff-only')
		if result.exit_code != 0 {
			return error('git pull 失败: ${result.output}')
		}
		return
	}
	if os.is_dir(checkout_dir) {
		os.rmdir_all(checkout_dir) or {}
	}
	result := os.execute('git clone --depth 1 "${source_ref}" "${checkout_dir}"')
	if result.exit_code != 0 {
		return error('git clone 失败: ${result.output}')
	}
}

fn install_extension_from_path(source_path string) string {
	mut input := source_path.trim_space()
	if input.len == 0 {
		return 'Error: 用法 extensions install <path>'
	}
	mut src := input
	mut source_kind := 'path'
	mut source_ref := ''

	if is_probable_git_source(input) {
		source_kind = 'git'
		source_ref = input
		src = get_git_source_checkout_dir(source_ref)
		ensure_git_source_checkout(source_ref, src) or {
			return 'Error: 拉取扩展 Git 源失败: ${err.msg()}'
		}
	} else {
		if src.starts_with('~') {
			src = expand_config_path(src)
		}
		if !os.is_abs_path(src) {
			src = os.real_path(src)
		}
		source_ref = src
		if !os.is_dir(src) {
			return 'Error: 扩展目录不存在: ${src}'
		}
	}

	mut manifest_path := os.join_path(src, 'minimax-extension.json')
	if !os.is_file(manifest_path) {
		manifest_path = os.join_path(src, 'gemini-extension.json')
	}
	if !os.is_file(manifest_path) {
		return 'Error: 未找到 minimax-extension.json'
	}
	manifest := parse_extension_manifest(manifest_path) or {
		return 'Error: 扩展清单解析失败'
	}
	target_dir := os.join_path(get_extensions_root_dir(), manifest.name)
	if os.is_dir(target_dir) {
		return 'Error: 扩展已存在: ${manifest.name}'
	}
	copy_directory_recursive(src, target_dir) or { return 'Error: 安装失败: ${err.msg()}' }
	write_extension_state(target_dir, src, source_kind, source_ref) or {
		return 'Error: 扩展已复制，但写入元数据失败: ${err.msg()}'
	}

	mut disabled := read_disabled_extensions()
	disabled.delete(manifest.name)
	write_disabled_extensions(disabled) or {}

	return if source_kind == 'git' {
		'✅ 已安装扩展: ${manifest.name} (git: ${source_ref})'
	} else {
		'✅ 已安装扩展: ${manifest.name}'
	}
}

fn find_extension_info(name string) ?ExtensionInfo {
	target := name.trim_space()
	for ext in discover_extensions() {
		if ext.name == target {
			return ext
		}
	}
	return none
}

fn set_extension_enabled(name string, enabled bool) string {
	target := name.trim_space()
	if target.len == 0 {
		return 'Error: 扩展名不能为空'
	}
	_ := find_extension_info(target) or { return 'Error: 未找到扩展: ${target}' }

	mut disabled := read_disabled_extensions()
	if enabled {
		disabled.delete(target)
	} else {
		disabled[target] = true
	}
	write_disabled_extensions(disabled) or {
		return 'Error: 无法更新扩展状态: ${err.msg()}'
	}
	return if enabled { '✅ 扩展已启用: ${target}' } else { '✅ 扩展已禁用: ${target}' }
}

fn uninstall_extension(name string) string {
	target := name.trim_space()
	if target.len == 0 {
		return 'Error: 用法 extensions uninstall <name>'
	}
	ext := find_extension_info(target) or { return 'Error: 未找到扩展: ${target}' }
	os.rmdir_all(ext.root_dir) or { return 'Error: 卸载失败: ${err.msg()}' }
	if ext.source_kind == 'git' && ext.source_path.len > 0 {
		sources_root := normalize_path_separators(get_extension_sources_root_dir())
		candidate := normalize_path_separators(ext.source_path)
		if candidate.starts_with(sources_root + '/') {
			os.rmdir_all(ext.source_path) or {}
		}
	}

	mut disabled := read_disabled_extensions()
	disabled.delete(target)
	write_disabled_extensions(disabled) or {}

	return '✅ 已卸载扩展: ${target}'
}

fn update_extension(name string) string {
	target := name.trim_space()
	if target.len == 0 {
		return 'Error: 用法 extensions update <name>'
	}
	ext := find_extension_info(target) or { return 'Error: 未找到扩展: ${target}' }
	source_path := ext.source_path
	if source_path.len == 0 {
		return 'Error: 扩展 ${target} 缺少 source_path 元数据，无法自动更新'
	}
	if ext.source_kind == 'git' {
		source_ref := if ext.source_ref.len > 0 { ext.source_ref } else { source_path }
		ensure_git_source_checkout(source_ref, source_path) or {
			return 'Error: 更新扩展 ${target} 的 Git 源失败: ${err.msg()}'
		}
	}
	if !os.is_dir(source_path) {
		return 'Error: 扩展 ${target} 的源目录不存在: ${source_path}'
	}
	mut source_manifest := os.join_path(source_path, 'minimax-extension.json')
	if !os.is_file(source_manifest) {
		source_manifest = os.join_path(source_path, 'gemini-extension.json')
	}
	parsed := parse_extension_manifest(source_manifest) or {
		return 'Error: 扩展 ${target} 源目录清单解析失败'
	}
	if parsed.name != ext.name {
		return 'Error: 扩展源名称不匹配: expected=${ext.name}, actual=${parsed.name}'
	}

	os.rmdir_all(ext.root_dir) or { return 'Error: 删除旧版本失败: ${err.msg()}' }
	copy_directory_recursive(source_path, ext.root_dir) or {
		return 'Error: 复制新版本失败: ${err.msg()}'
	}
	source_kind := if ext.source_kind.len > 0 { ext.source_kind } else { 'path' }
	source_ref := if ext.source_ref.len > 0 { ext.source_ref } else { source_path }
	write_extension_state(ext.root_dir, source_path, source_kind, source_ref) or {
		return 'Error: 更新后写入元数据失败: ${err.msg()}'
	}
	return '✅ 扩展已更新: ${target}'
}

fn update_all_extensions() string {
	exts := discover_extensions()
	if exts.len == 0 {
		return '📦 暂无扩展可更新'
	}
	mut lines := ['🔄 扩展更新结果:']
	mut ok_count := 0
	for ext in exts {
		result := update_extension(ext.name)
		lines << '  - ${result}'
		if result.starts_with('✅') {
			ok_count++
		}
	}
	lines << '完成: ${ok_count}/${exts.len}'
	return lines.join('\n')
}
