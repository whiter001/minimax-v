module main

import os

// Helper: create a local skill registry for isolated test state
fn new_test_skill_registry() SkillRegistry {
	return SkillRegistry{
		skills:       []Skill{}
		active_skill: ''
		loaded:       true
	}
}

fn reset_registry() {}

struct SkillTestEnv {
	base                 string
	previous_config_home string
	previous_home        string
}

fn setup_skill_test_env(name string) SkillTestEnv {
	base := os.join_path(os.temp_dir(), name)
	os.rmdir_all(base) or {}
	os.mkdir_all(base) or {}
	previous := os.getenv_opt('MINIMAX_CONFIG_HOME') or { '' }
	previous_home := os.getenv_opt('HOME') or { '' }
	os.setenv('MINIMAX_CONFIG_HOME', base, true)
	os.setenv('HOME', base, true)
	return SkillTestEnv{
		base:                 base
		previous_config_home: previous
		previous_home:        previous_home
	}
}

fn restore_skill_test_env(env SkillTestEnv) {
	if env.previous_config_home.len > 0 {
		os.setenv('MINIMAX_CONFIG_HOME', env.previous_config_home, true)
	} else {
		os.unsetenv('MINIMAX_CONFIG_HOME')
	}
	if env.previous_home.len > 0 {
		os.setenv('HOME', env.previous_home, true)
	} else {
		os.unsetenv('HOME')
	}
	os.rmdir_all(env.base) or {}
}

// ===== parse_skill_md =====

fn test_parse_skill_md_valid() {
	dir := '/tmp/__minimax_skill_test__'
	os.mkdir_all(dir) or {}
	defer { os.rmdir_all(dir) or {} }

	path := os.join_path(dir, 'SKILL.md')
	content := '---\nname: test-skill\ndescription: A test skill\n---\n\nYou are a test assistant.'
	os.write_file(path, content) or {
		assert false
		return
	}

	skill := parse_skill_md(path, 'user') or {
		assert false, 'should have parsed successfully'
		return
	}
	assert skill.name == 'test-skill'
	assert skill.description == 'A test skill'
	assert skill.prompt == 'You are a test assistant.'
	assert skill.source == 'user'
	assert skill.path == path
}

fn test_parse_skill_md_no_frontmatter() {
	dir := '/tmp/__minimax_skill_test_nofm__'
	os.mkdir_all(dir) or {}
	defer { os.rmdir_all(dir) or {} }

	path := os.join_path(dir, 'SKILL.md')
	os.write_file(path, 'Just plain text, no frontmatter') or {
		assert false
		return
	}

	if _ := parse_skill_md(path, 'user') {
		assert false, 'should return none for missing frontmatter'
	}
}

fn test_parse_skill_md_no_closing_fence() {
	dir := '/tmp/__minimax_skill_test_nofence__'
	os.mkdir_all(dir) or {}
	defer { os.rmdir_all(dir) or {} }

	path := os.join_path(dir, 'SKILL.md')
	os.write_file(path, '---\nname: broken\ndescription: oops\nno closing fence') or {
		assert false
		return
	}

	if _ := parse_skill_md(path, 'user') {
		assert false, 'should return none when closing --- is missing'
	}
}

fn test_parse_skill_md_empty_body() {
	dir := '/tmp/__minimax_skill_test_emptybody__'
	os.mkdir_all(dir) or {}
	defer { os.rmdir_all(dir) or {} }

	path := os.join_path(dir, 'SKILL.md')
	os.write_file(path, '---\nname: empty\ndescription: empty body\n---\n') or {
		assert false
		return
	}

	if _ := parse_skill_md(path, 'user') {
		assert false, 'should return none for empty body'
	}
}

fn test_parse_skill_md_no_name_uses_dirname() {
	dir := '/tmp/__minimax_skill_test_noname__/my-tool'
	os.mkdir_all(dir) or {}
	defer { os.rmdir_all('/tmp/__minimax_skill_test_noname__') or {} }

	path := os.join_path(dir, 'SKILL.md')
	os.write_file(path, '---\ndescription: Nameless skill\n---\n\nDo things.') or {
		assert false
		return
	}

	skill := parse_skill_md(path, 'project') or {
		assert false, 'should infer name from directory'
		return
	}
	assert skill.name == 'my-tool'
	assert skill.description == 'Nameless skill'
}

fn test_parse_skill_md_no_description_gets_default() {
	dir := '/tmp/__minimax_skill_test_nodesc__'
	os.mkdir_all(dir) or {}
	defer { os.rmdir_all(dir) or {} }

	path := os.join_path(dir, 'SKILL.md')
	os.write_file(path, '---\nname: nodesc\n---\n\nPrompt content here.') or {
		assert false
		return
	}

	skill := parse_skill_md(path, 'user') or {
		assert false
		return
	}
	assert skill.description == 'Custom skill: nodesc'
}

fn test_parse_skill_md_quoted_values() {
	dir := '/tmp/__minimax_skill_test_quoted__'
	os.mkdir_all(dir) or {}
	defer { os.rmdir_all(dir) or {} }

	path := os.join_path(dir, 'SKILL.md')
	os.write_file(path, '---\nname: "quoted-name"\ndescription: \'quoted desc\'\n---\n\nBody.') or {
		assert false
		return
	}

	skill := parse_skill_md(path, 'user') or {
		assert false
		return
	}
	assert skill.name == 'quoted-name'
	assert skill.description == 'quoted desc'
}

fn test_parse_skill_md_structured_metadata() {
	dir := os.join_path(os.temp_dir(), '__minimax_skill_test_meta__')
	os.mkdir_all(dir) or {}
	defer { os.rmdir_all(dir) or {} }

	path := os.join_path(dir, 'SKILL.md')
	os.write_file(path,
		'---\nname: background-runner\ndescription: Run background jobs\ntags:\n  - background\n  - pueue\ntools: [bash, pueue]\ntriggers:\n  - 帮我后台跑任务\n  - check pueue status\nplatform: windows\n---\n\n# Workflow\n\nUse pueue to manage queued tasks.\n') or {
		assert false
		return
	}

	skill := parse_skill_md(path, 'user') or {
		assert false
		return
	}
	assert skill.tags == ['background', 'pueue']
	assert skill.tools == ['bash', 'pueue']
	assert skill.triggers == ['帮我后台跑任务', 'check pueue status']
	assert skill.platform == 'windows'
	assert skill.sections.len == 1
	assert skill.sections[0].heading == 'Workflow'
}

fn test_parse_skill_md_nonexistent_file() {
	if _ := parse_skill_md('/tmp/__no_such_file_skill__.md', 'user') {
		assert false, 'should return none for nonexistent file'
	}
}

// ===== add_or_override_skill + priority =====

fn test_add_or_override_skill_same_priority() {
	reset_registry()
	mut registry := new_test_skill_registry()
	s1 := Skill{
		name:        'test'
		description: 'v1'
		prompt:      'p1'
		source:      'builtin'
	}
	s2 := Skill{
		name:        'test'
		description: 'v2'
		prompt:      'p2'
		source:      'builtin'
	}
	registry.skills << s1
	add_or_override_skill(mut registry, s2)
	assert registry.skills.len == 1
	assert registry.skills[0].description == 'v2' // same priority overrides
}

fn test_add_or_override_skill_higher_priority_overrides() {
	reset_registry()
	mut registry := new_test_skill_registry()
	s1 := Skill{
		name:        'test'
		description: 'builtin'
		prompt:      'p1'
		source:      'builtin'
	}
	s2 := Skill{
		name:        'test'
		description: 'user'
		prompt:      'p2'
		source:      'user'
	}
	registry.skills << s1
	add_or_override_skill(mut registry, s2)
	assert registry.skills.len == 1
	assert registry.skills[0].source == 'user'
	assert registry.skills[0].description == 'user'
}

fn test_add_or_override_skill_lower_priority_no_override() {
	reset_registry()
	mut registry := new_test_skill_registry()
	s1 := Skill{
		name:        'test'
		description: 'project'
		prompt:      'p1'
		source:      'project'
	}
	s2 := Skill{
		name:        'test'
		description: 'builtin'
		prompt:      'p2'
		source:      'builtin'
	}
	registry.skills << s1
	add_or_override_skill(mut registry, s2)
	assert registry.skills.len == 1
	assert registry.skills[0].source == 'project' // not overridden
}

fn test_add_or_override_skill_new_name_appends() {
	reset_registry()
	mut registry := new_test_skill_registry()
	s1 := Skill{
		name:        'a'
		description: 'd1'
		prompt:      'p1'
		source:      'builtin'
	}
	s2 := Skill{
		name:        'b'
		description: 'd2'
		prompt:      'p2'
		source:      'user'
	}
	registry.skills << s1
	add_or_override_skill(mut registry, s2)
	assert registry.skills.len == 2
}

fn test_add_or_override_three_tier() {
	reset_registry()
	mut registry := new_test_skill_registry()
	builtin := Skill{
		name:        'coder'
		description: 'builtin'
		prompt:      'bp'
		source:      'builtin'
	}
	user := Skill{
		name:        'coder'
		description: 'user'
		prompt:      'up'
		source:      'user'
	}
	project := Skill{
		name:        'coder'
		description: 'project'
		prompt:      'pp'
		source:      'project'
	}
	registry.skills << builtin
	add_or_override_skill(mut registry, user)
	assert registry.skills[0].source == 'user'
	add_or_override_skill(mut registry, project)
	assert registry.skills[0].source == 'project'
	assert registry.skills[0].prompt == 'pp'
}

// ===== find_skill =====

fn test_find_skill_builtin() {
	env := setup_skill_test_env('__minimax_skill_find_builtin__')
	defer { restore_skill_test_env(env) }
	if skill := find_skill('', 'coder') {
		assert skill.name == 'coder'
		assert skill.source == 'builtin'
	} else {
		assert false, 'should find coder skill'
	}
}

fn test_find_skill_not_found() {
	env := setup_skill_test_env('__minimax_skill_find_missing__')
	defer { restore_skill_test_env(env) }
	if _ := find_skill('', 'nonexistent-skill') {
		assert false, 'should return none'
	}
}

// ===== get_all_skills / get_builtin_skills =====

fn test_get_builtin_skills_count() {
	skills := get_builtin_skills()
	assert skills.len == 15
	// Verify each has required fields
	for skill in skills {
		assert skill.name.len > 0
		assert skill.description.len > 0
		assert skill.prompt.len > 0
		assert skill.source == 'builtin'
	}
}

fn test_get_all_skills_after_init() {
	env := setup_skill_test_env('__minimax_skill_get_all__')
	defer { restore_skill_test_env(env) }
	all := get_all_skills('')
	assert all.len >= 15
}

// ===== activate_skill_tool =====

fn test_activate_skill_tool_success() {
	env := setup_skill_test_env('__minimax_skill_activate_success__')
	defer { restore_skill_test_env(env) }
	result := activate_skill_tool('', 'debugger')
	assert result.contains('Skill activated')
	assert result.contains('debugger')
	assert result.contains('Skill Instructions')
}

fn test_activate_skill_tool_not_found() {
	env := setup_skill_test_env('__minimax_skill_activate_missing__')
	defer { restore_skill_test_env(env) }
	result := activate_skill_tool('', 'nonexistent')
	assert result.contains('not found')
	assert result.contains('Available skills')
	assert result.contains('coder')
}

// ===== build_skills_metadata =====

fn test_build_skills_metadata_with_skills() {
	env := setup_skill_test_env('__minimax_skill_meta__')
	defer { restore_skill_test_env(env) }
	workspace := os.join_path(os.temp_dir(), '__minimax_skill_meta__')
	os.rmdir_all(workspace) or {}
	os.mkdir_all(os.join_path(workspace, '.agents', 'skills', 'test1')) or {}
	os.mkdir_all(os.join_path(workspace, '.agents', 'skills', 'test2')) or {}
	defer { os.rmdir_all(workspace) or {} }
	os.write_file(os.join_path(workspace, '.agents', 'skills', 'test1', 'SKILL.md'),
		'---\nname: test1\ndescription: desc1\n---\n\np') or {}
	os.write_file(os.join_path(workspace, '.agents', 'skills', 'test2', 'SKILL.md'),
		'---\nname: test2\ndescription: desc2\n---\n\np') or {}
	meta := build_skills_metadata(workspace)
	assert meta.contains('Available Skills')
	assert meta.contains('activate_skill')
	assert meta.contains('test1: desc1 [project]')
	assert meta.contains('test2: desc2 [project]')
}

fn test_build_skills_metadata_empty() {
	env := setup_skill_test_env('__minimax_skill_meta_empty__')
	defer { restore_skill_test_env(env) }
	workspace := os.join_path(os.temp_dir(), '__minimax_skill_meta_empty__')
	os.rmdir_all(workspace) or {}
	os.mkdir_all(workspace) or {}
	defer { os.rmdir_all(workspace) or {} }
	meta := build_skills_metadata(workspace)
	assert meta.contains('Available Skills')
	assert meta.contains('coder')
}

fn test_select_relevant_skills_prefers_metadata_match() {
	env := setup_skill_test_env('__minimax_skill_select__')
	defer { restore_skill_test_env(env) }
	workspace := os.join_path(os.temp_dir(), '__minimax_skill_select_workspace__')
	os.rmdir_all(workspace) or {}
	defer { os.rmdir_all(workspace) or {} }
	os.mkdir_all(os.join_path(workspace, '.agents', 'skills', 'background-runner')) or {}
	os.mkdir_all(os.join_path(workspace, '.agents', 'skills', 'frontend-ui')) or {}
	os.write_file(os.join_path(workspace, '.agents', 'skills', 'background-runner', 'SKILL.md'),
		'---\nname: background-runner\ndescription: Manage background jobs\ntags:\n  - background\n  - queue\ntools:\n  - bash\n  - pueue\ntriggers:\n  - 后台跑任务\n  - check pueue status\nplatform: windows\n---\n\n# Workflow\n\nUse pueue to queue and inspect background tasks.\n') or {}
	os.write_file(os.join_path(workspace, '.agents', 'skills', 'frontend-ui', 'SKILL.md'),
		'---\nname: frontend-ui\ndescription: Build browser UI\ntags:\n  - react\n  - css\ntools:\n  - bash\ntriggers:\n  - 调整页面样式\n---\n\n# Workflow\n\nWork on frontend components.\n') or {}

	matches :=
		select_relevant_skills(workspace, '帮我在后台跑任务并查看 pueue 状态', 2)
	assert matches.len >= 1
	assert matches[0].skill.name == 'background-runner'
	assert 'tools' in matches[0].matched_fields || 'triggers' in matches[0].matched_fields
}

fn test_build_auto_skills_context_includes_relevant_excerpt() {
	env := setup_skill_test_env('__minimax_skill_auto_context__')
	defer { restore_skill_test_env(env) }
	workspace := os.join_path(os.temp_dir(), '__minimax_skill_auto_context_workspace__')
	os.rmdir_all(workspace) or {}
	defer { os.rmdir_all(workspace) or {} }
	os.mkdir_all(os.join_path(workspace, '.agents', 'skills', 'background-runner')) or {}
	os.write_file(os.join_path(workspace, '.agents', 'skills', 'background-runner', 'SKILL.md'),
		'---\nname: background-runner\ndescription: Manage background jobs\ntools:\n  - pueue\ntriggers:\n  - 后台跑任务\n---\n\n# Overview\n\nThis skill handles background work.\n\n# Workflow\n\nCheck pueue status before resuming or pausing jobs.\n') or {}

	context :=
		build_auto_skills_context(workspace, '先看 pueue 状态，再恢复后台任务', 2)
	assert context.contains('Auto-selected skills for the current task')
	assert context.contains('background-runner')
	assert context.contains('matched_terms')
	assert context.contains('### Workflow')
}

// ===== create_skill_template =====

fn test_create_skill_template_success() {
	base_dir := '/tmp/__minimax_skill_template_test__'
	os.rmdir_all(base_dir) or {}
	defer { os.rmdir_all(base_dir) or {} }

	result := create_skill_template('my-new-skill', base_dir)
	assert result.contains('Skill template created')
	assert result.contains('my-new-skill')

	// Verify file exists
	skill_path := os.join_path(base_dir, 'my-new-skill', 'SKILL.md')
	assert os.is_file(skill_path)

	// Verify content
	content := os.read_file(skill_path) or { '' }
	assert content.contains('name: my-new-skill')
	assert content.contains('description:')
}

fn test_create_skill_template_already_exists() {
	base_dir := '/tmp/__minimax_skill_template_exists__'
	skill_dir := os.join_path(base_dir, 'existing')
	os.mkdir_all(skill_dir) or {}
	defer { os.rmdir_all(base_dir) or {} }

	result := create_skill_template('existing', base_dir)
	assert result.contains('Error')
	assert result.contains('already exists')
}

// ===== load_custom_skills_from_dir =====

fn test_load_custom_skills_from_dir_subdir_structure() {
	reset_registry()
	mut registry := new_test_skill_registry()
	base_dir := '/tmp/__minimax_skill_discovery__'
	os.rmdir_all(base_dir) or {}
	os.mkdir_all(os.join_path(base_dir, 'alpha')) or {}
	os.mkdir_all(os.join_path(base_dir, 'beta')) or {}
	defer { os.rmdir_all(base_dir) or {} }

	os.write_file(os.join_path(base_dir, 'alpha', 'SKILL.md'),
		'---\nname: alpha\ndescription: Alpha skill\n---\n\nAlpha prompt.') or {}
	os.write_file(os.join_path(base_dir, 'beta', 'SKILL.md'),
		'---\nname: beta\ndescription: Beta skill\n---\n\nBeta prompt.') or {}

	load_custom_skills_from_dir(base_dir, 'project', mut registry)

	assert registry.skills.len == 2
	names := registry.skills.map(it.name)
	assert 'alpha' in names
	assert 'beta' in names
	for s in registry.skills {
		assert s.source == 'project'
	}
}

fn test_load_custom_skills_from_dir_nonexistent() {
	reset_registry()
	mut registry := new_test_skill_registry()
	load_custom_skills_from_dir('/tmp/__no_such_dir_minimax__', 'user', mut registry)
	assert registry.skills.len == 0 // no crash, just skip
}

fn test_load_custom_skills_from_dir_root_skill_md() {
	reset_registry()
	mut registry := new_test_skill_registry()
	base_dir := '/tmp/__minimax_root_skill__'
	os.rmdir_all(base_dir) or {}
	os.mkdir_all(base_dir) or {}
	defer { os.rmdir_all(base_dir) or {} }

	// SKILL.md directly in the skills dir (not in a subdirectory)
	os.write_file(os.join_path(base_dir, 'SKILL.md'),
		'---\nname: root-skill\ndescription: In root\n---\n\nRoot prompt.') or {}

	load_custom_skills_from_dir(base_dir, 'user', mut registry)
	assert registry.skills.len == 1
	assert registry.skills[0].name == 'root-skill'
}

// ===== reload_skill_registry =====

fn test_reload_skill_registry() {
	env := setup_skill_test_env('__minimax_skill_reload__')
	defer { restore_skill_test_env(env) }
	registry := reload_skill_registry('')
	assert registry.loaded == true
	assert registry.skills.len >= 15 // at least builtins
}

// ===== Integration: full tier discovery =====

fn test_full_tier_discovery() {
	env := setup_skill_test_env('__minimax_skill_full_tier__')
	defer { restore_skill_test_env(env) }
	reset_registry()
	// Setup project-level skills
	project_dir := '/tmp/__minimax_full_tier__/project'
	skills_dir := os.join_path(project_dir, '.agents', 'skills', 'custom-coder')
	os.rmdir_all('/tmp/__minimax_full_tier__') or {}
	os.mkdir_all(skills_dir) or {}
	defer { os.rmdir_all('/tmp/__minimax_full_tier__') or {} }

	// Project skill that overrides builtin 'coder'
	os.write_file(os.join_path(skills_dir, 'SKILL.md'),
		'---\nname: coder\ndescription: Project coder\n---\n\nProject-level coder prompt.') or {}

	// The 'coder' should be project-level, not builtin
	if skill := find_skill(project_dir, 'coder') {
		assert skill.source == 'project'
		assert skill.description == 'Project coder'
		assert skill.prompt == 'Project-level coder prompt.'
	} else {
		assert false, 'should find overridden coder skill'
	}

	// Other builtins should still be present
	if skill := find_skill(project_dir, 'debugger') {
		assert skill.source == 'builtin'
	} else {
		assert false, 'should find builtin debugger'
	}
}

// ===== print_skills_list (no crash test) =====

fn test_print_skills_list_no_crash() {
	env := setup_skill_test_env('__minimax_skill_print__')
	defer { restore_skill_test_env(env) }
	reset_registry()
	// Just verify no panic
	print_skills_list('', '')
}
