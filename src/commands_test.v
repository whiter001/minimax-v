module main

import os

fn new_test_command_registry(workspace string) CommandRegistry {
	return CommandRegistry{
		commands:  []CustomCommand{}
		loaded:    true
		workspace: workspace
	}
}

fn reset_command_registry_for_test() {}

fn test_command_name_from_toml_path_namespaced() {
	root := os.join_path('C:\\tmp', 'commands')
	path := os.join_path(root, 'git', 'commit.toml')
	name := command_name_from_toml_path(root, path)
	assert name == 'git:commit'
}

fn test_parse_command_toml_multiline_prompt() {
	dir := os.join_path(os.temp_dir(), '__minimax_command_parse__')
	os.rmdir_all(dir) or {}
	os.mkdir_all(dir) or {}
	defer { os.rmdir_all(dir) or {} }

	path := os.join_path(dir, 'test.toml')
	content := 'description = "test command"\nprompt = """\nhello {{args}}\nworld\n"""'
	os.write_file(path, content) or {
		assert false
		return
	}

	cmd := parse_command_toml(path, 'test', 'user', '') or {
		assert false, 'should parse command'
		return
	}
	assert cmd.name == 'test'
	assert cmd.description == 'test command'
	assert cmd.prompt.contains('hello {{args}}')
	assert cmd.prompt.contains('world')
}

fn test_load_custom_commands_from_dir_subdirs() {
	reset_command_registry_for_test()
	mut registry := new_test_command_registry('')
	base := os.join_path(os.temp_dir(), '__minimax_command_discovery__')
	os.rmdir_all(base) or {}
	os.mkdir_all(os.join_path(base, 'fs')) or {}
	defer { os.rmdir_all(base) or {} }

	cmd_file := os.join_path(base, 'fs', 'grep-code.toml')
	os.write_file(cmd_file, 'prompt = """find {{args}}"""') or {
		assert false
		return
	}

	load_custom_commands_from_dir(base, 'project', '', mut registry)
	assert registry.commands.len == 1
	assert registry.commands[0].name == 'fs:grep-code'
	assert registry.commands[0].source == 'project'
}

fn test_add_or_override_custom_command_priority() {
	reset_command_registry_for_test()
	mut registry := new_test_command_registry('')
	add_or_override_custom_command(mut registry, CustomCommand{
		name:        'git:commit'
		description: 'builtin'
		prompt:      'p1'
		source:      'builtin'
	})
	add_or_override_custom_command(mut registry, CustomCommand{
		name:        'git:commit'
		description: 'project override'
		prompt:      'p2'
		source:      'project'
	})
	assert registry.commands.len == 1
	assert registry.commands[0].description == 'project override'
	assert registry.commands[0].source == 'project'
}

fn test_parse_custom_command_invocation_with_args() {
	name, args := parse_custom_command_invocation('/git:commit feat(api): add endpoint') or {
		assert false
		return
	}
	assert name == 'git:commit'
	assert args == 'feat(api): add endpoint'
}

fn test_render_custom_command_prompt_args_and_file_injection() {
	dir := os.join_path(os.temp_dir(), '__minimax_command_render__')
	os.rmdir_all(dir) or {}
	os.mkdir_all(dir) or {}
	defer { os.rmdir_all(dir) or {} }
	mut bash_session := new_bash_session(dir)

	sample := os.join_path(dir, 'sample.txt')
	os.write_file(sample, 'file-content') or {
		assert false
		return
	}

	cmd := CustomCommand{
		name:        'review:file'
		description: 'review'
		prompt:      'Target: {{args}}\n\n@{ sample.txt }'
		source:      'project'
	}
	rendered := render_custom_command_prompt(cmd, 'sample.txt', dir, false, mut bash_session) or {
		assert false
		return
	}
	assert rendered.contains('Target: sample.txt')
	assert rendered.contains('file-content')
	assert rendered.contains('--- File: sample.txt ---')
}

fn test_render_custom_command_prompt_missing_file_error() {
	mut bash_session := new_bash_session('')
	cmd := CustomCommand{
		name:        'review:file'
		description: 'review'
		prompt:      '@{ no-such-file.txt }'
		source:      'project'
	}
	if _ := render_custom_command_prompt(cmd, '', '', false, mut bash_session) {
		assert false, 'should fail when injected path does not exist'
	}
}

fn test_get_builtin_custom_commands_has_practical_pack() {
	cmds := get_builtin_custom_commands()
	names := cmds.map(it.name)
	assert 'git:commit' in names
	assert 'fs:grep-code' in names
	assert 'review:file' in names
	assert 'refactor:pure' in names
	assert 'changelog:add' in names
	assert 'git:pr-summary' in names
}

fn test_parse_extension_manifest_basic() {
	dir := os.join_path(os.temp_dir(), '__minimax_ext_manifest__')
	os.rmdir_all(dir) or {}
	os.mkdir_all(dir) or {}
	defer { os.rmdir_all(dir) or {} }

	path := os.join_path(dir, 'minimax-extension.json')
	os.write_file(path, '{"name":"custom-commands","version":"1.0.0","commands":"commands"}') or {
		assert false
		return
	}
	manifest := parse_extension_manifest(path) or {
		assert false
		return
	}
	assert manifest.name == 'custom-commands'
	assert manifest.version == '1.0.0'
	assert manifest.commands_path == 'commands'
}

fn test_parse_manifest_mcp_servers_top_level_keys() {
	content := '{"name":"ext","version":"1.0.0","mcpServers":{"playwright":{"type":"stdio","command":"npx","args":["-y","@playwright/mcp@latest"]},"search":{"type":"stdio","command":"uvx","args":["minimax-coding-plan-mcp"]}}}'
	servers := parse_manifest_mcp_servers(content)
	assert 'playwright' in servers
	assert 'search' in servers
	assert 'type' !in servers
}

fn test_load_extension_command_conflict_prefixed() {
	reset_command_registry_for_test()
	mut registry := new_test_command_registry('')
	add_or_override_custom_command(mut registry, CustomCommand{
		name:        'fs:grep-code'
		description: 'user command'
		prompt:      'user prompt'
		source:      'user'
	})

	ext_dir := os.join_path(os.temp_dir(), '__minimax_ext_conflict__')
	os.rmdir_all(ext_dir) or {}
	os.mkdir_all(os.join_path(ext_dir, 'fs')) or {}
	defer { os.rmdir_all(ext_dir) or {} }

	ext_cmd_file := os.join_path(ext_dir, 'fs', 'grep-code.toml')
	os.write_file(ext_cmd_file, 'prompt = """extension prompt"""') or {
		assert false
		return
	}

	load_custom_commands_from_dir(ext_dir, 'extension', 'my-ext', mut registry)
	mut original_source := ''
	mut prefixed_source := ''
	mut prefixed_prompt := ''
	for cmd in registry.commands {
		if cmd.name == 'fs:grep-code' {
			original_source = cmd.source
		}
		if cmd.name == 'ext:my-ext:fs:grep-code' {
			prefixed_source = cmd.source
			prefixed_prompt = cmd.prompt
		}
	}
	assert original_source == 'user'
	assert prefixed_source == 'extension'
	assert prefixed_prompt == 'extension prompt'
}

fn test_parse_manifest_mcp_server_configs() {
	content := '{"name":"ext","version":"1.0.0","mcpServers":{"playwright":{"type":"stdio","command":"npx","args":["-y","@playwright/mcp@latest"],"env":{"FOO":"BAR"}}}}'
	configs := parse_manifest_mcp_server_configs(content)
	assert configs.len == 1
	assert configs[0].name == 'playwright'
	assert configs[0].command == 'npx'
	assert configs[0].args.len >= 2
	foo := configs[0].env['FOO'] or { '' }
	assert foo == 'BAR'
}

fn test_collect_enabled_extension_mcp_servers_only_enabled() {
	exts := [
		ExtensionInfo{
			name:        'enabled-ext'
			enabled:     true
			mcp_configs: [
				McpServerConfig{
					name:    'playwright'
					command: 'npx'
					args:    ['-y', '@playwright/mcp@latest']
					env:     {}
				},
			]
		},
		ExtensionInfo{
			name:        'disabled-ext'
			enabled:     false
			mcp_configs: [
				McpServerConfig{
					name:    'hidden'
					command: 'uvx'
					args:    ['hidden']
					env:     {}
				},
			]
		},
	]
	servers := collect_enabled_extension_mcp_servers(exts)
	assert servers.len == 1
	assert servers[0].extension_name == 'enabled-ext'
	assert servers[0].config.name == 'playwright'
}

fn test_reserve_unique_mcp_server_name_conflict() {
	mut used := {
		'MiniMax': true
	}
	first := reserve_unique_mcp_server_name('my-ext', 'MiniMax', mut used)
	second := reserve_unique_mcp_server_name('my-ext', 'MiniMax', mut used)
	assert first == 'ext:my-ext:MiniMax'
	assert second == 'ext:my-ext:MiniMax-2'
}

fn test_write_and_read_extension_state() {
	dir := os.join_path(os.temp_dir(), '__minimax_ext_state__')
	os.rmdir_all(dir) or {}
	os.mkdir_all(dir) or {}
	defer { os.rmdir_all(dir) or {} }

	write_extension_state(dir, 'D:\\source\\my-extension', 'git', 'https://example.com/ext.git') or {
		assert false
		return
	}
	source := read_extension_source_path(dir)
	kind := read_extension_source_kind(dir)
	ref := read_extension_source_ref(dir)
	updated := read_extension_updated_at(dir)
	assert source == 'D:\\source\\my-extension'
	assert kind == 'git'
	assert ref == 'https://example.com/ext.git'
	assert updated > 0
}

fn test_parse_injection_target_with_filters() {
	base, opts := parse_injection_target('src?ext=.v,.md&include=api,core&exclude=test,spec&max=7')
	assert base == 'src'
	assert opts.ext_filters.len == 2
	assert '.v' in opts.ext_filters
	assert '.md' in opts.ext_filters
	assert opts.include_patterns == ['api', 'core']
	assert opts.exclude_patterns == ['test', 'spec']
	assert opts.max_files == 7
}

fn test_should_include_injection_file_filters() {
	opts := InjectionOptions{
		ext_filters:      ['.v']
		include_patterns: ['src']
		exclude_patterns: ['test']
		max_files:        10
	}
	assert should_include_injection_file('D:\\repo', 'D:\\repo\\src\\main.v', opts)
	assert !should_include_injection_file('D:\\repo', 'D:\\repo\\src\\main_test.v', opts)
	assert !should_include_injection_file('D:\\repo', 'D:\\repo\\docs\\readme.md', opts)
}

fn test_is_probable_git_source() {
	assert is_probable_git_source('https://github.com/org/repo.git')
	assert is_probable_git_source('git@github.com:org/repo.git')
	assert !is_probable_git_source('D:\\work\\local-extension')
}
