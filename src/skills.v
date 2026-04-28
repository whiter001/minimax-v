module main

import os

const max_skill_metadata_entries = 24
const default_auto_skill_context_limit = 3
const max_auto_skill_excerpt_chars = 1400
const max_auto_skill_section_chars = 500

// Skills System — Built-in + Custom SKILL.md support with lightweight autoskill retrieval
// Discovery tiers: Project (.agents/skills/) > User (~/.config/minimax/skills/) > Built-in
// SKILL.md format: YAML frontmatter (---) with name/description/tags/tools/triggers/platform + Markdown body as prompt
// AI can auto-activate via activate_skill tool

struct Skill {
	name        string
	description string
	prompt      string
	source      string // 'builtin', 'user', 'project'
	path        string // file path for custom skills (empty for builtin)
	tags        []string
	tools       []string
	triggers    []string
	platform    string
	sections    []SkillSection
}

struct SkillSection {
mut:
	heading string
	level   int
	content string
}

struct SkillFrontmatter {
mut:
	name        string
	description string
	tags        []string
	tools       []string
	triggers    []string
	platform    string
}

struct SkillMatch {
	skill          Skill
	score          int
	matched_terms  []string
	matched_fields []string
}

struct SkillRegistry {
mut:
	skills       []Skill
	active_skill string // currently active skill name
	loaded       bool
}

// Initialize skill registry: discover all skills from all tiers
fn load_skill_registry(workspace string) SkillRegistry {
	mut registry := SkillRegistry{
		skills:       []Skill{}
		active_skill: ''
		loaded:       true
	}
	// 1. Built-in skills (lowest priority)
	for s in get_builtin_skills() {
		registry.skills << s
	}
	// 2. User-level skills (~/.config/minimax/skills/)
	user_dir := os.join_path(get_minimax_config_dir(), 'skills')
	load_custom_skills_from_dir(user_dir, 'user', mut registry)
	// Also check ~/.agents/skills/ alias
	user_agents_dir := expand_home_path('~/.agents/skills')
	load_custom_skills_from_dir(user_agents_dir, 'user', mut registry)
	// 3. Project-level skills (highest priority)
	if workspace.len > 0 {
		project_dir := os.join_path(workspace, '.agents', 'skills')
		load_custom_skills_from_dir(project_dir, 'project', mut registry)
	}
	return registry
}

fn init_skill_registry(workspace string) SkillRegistry {
	return load_skill_registry(workspace)
}

fn reload_skill_registry(workspace string) SkillRegistry {
	return load_skill_registry(workspace)
}

fn build_skills_metadata_from_registry(registry SkillRegistry) string {
	if registry.skills.len == 0 {
		return ''
	}
	mut lines := [
		'Available Skills (use activate_skill tool to load specialized expertise):',
	]
	limit := if registry.skills.len > max_skill_metadata_entries {
		max_skill_metadata_entries
	} else {
		registry.skills.len
	}
	for skill in registry.skills[..limit] {
		lines << '  - ${build_skill_metadata_line(skill)}'
	}
	if registry.skills.len > limit {
		lines << '  - ... ${registry.skills.len - limit} more skills omitted for brevity'
	}
	return lines.join('\n')
}

fn build_skill_metadata_line(skill Skill) string {
	mut line := '${skill.name}: ${skill.description} [${skill.source}]'
	mut extras := []string{}
	if skill.tags.len > 0 {
		tags_preview := if skill.tags.len > 3 { skill.tags[..3] } else { skill.tags.clone() }
		extras << 'tags=' + tags_preview.join(', ')
	}
	if skill.tools.len > 0 {
		tools_preview := if skill.tools.len > 3 { skill.tools[..3] } else { skill.tools.clone() }
		extras << 'tools=' + tools_preview.join(', ')
	}
	if skill.triggers.len > 0 {
		triggers_preview := if skill.triggers.len > 2 {
			skill.triggers[..2]
		} else {
			skill.triggers.clone()
		}
		extras << 'triggers=' + triggers_preview.join(' | ')
	}
	if skill.platform.len > 0 {
		extras << 'platform=' + skill.platform
	}
	if extras.len > 0 {
		line += ' (' + extras.join('; ') + ')'
	}
	return line
}

// Load custom SKILL.md files from a directory
fn load_custom_skills_from_dir(dir string, source string, mut registry SkillRegistry) {
	if !os.is_dir(dir) {
		return
	}
	// Scan for SKILL.md directly in the dir
	skill_file := os.join_path(dir, 'SKILL.md')
	if os.is_file(skill_file) {
		if skill := parse_skill_md(skill_file, source) {
			add_or_override_skill(mut registry, skill)
		}
	}
	// Scan subdirectories for SKILL.md
	entries := os.ls(dir) or { return }
	for entry in entries {
		subdir := os.join_path(dir, entry)
		if os.is_dir(subdir) {
			sub_skill_file := os.join_path(subdir, 'SKILL.md')
			if os.is_file(sub_skill_file) {
				if skill := parse_skill_md(sub_skill_file, source) {
					add_or_override_skill(mut registry, skill)
				}
			}
		}
	}
}

// Add skill to registry, overriding same-name skill from lower tier
fn add_or_override_skill(mut registry SkillRegistry, new_skill Skill) {
	// Priority: project > user > builtin
	priority := fn (source string) int {
		return match source {
			'project' { 3 }
			'user' { 2 }
			else { 1 }
		}
	}
	for i, existing in registry.skills {
		if existing.name == new_skill.name {
			if priority(new_skill.source) >= priority(existing.source) {
				registry.skills[i] = new_skill
			}
			return
		}
	}
	registry.skills << new_skill
}

// Parse a SKILL.md file with YAML frontmatter
// Format:
// ---
// name: my-skill
// description: A short description
// ---
// Body text becomes the prompt
fn parse_skill_md(path string, source string) ?Skill {
	content := os.read_file(path) or { return none }
	trimmed := content.trim_space()
	if !trimmed.starts_with('---') {
		return none
	}
	// Find closing ---
	rest := trimmed[3..]
	end_idx := rest.index('---') or { return none }
	frontmatter := rest[..end_idx].trim_space()
	body := rest[end_idx + 3..].trim_space()
	mut meta := parse_skill_frontmatter(frontmatter)
	mut name := meta.name
	mut description := meta.description
	if name.len == 0 {
		// Use filename-based name
		parent := os.dir(path)
		dir_name := os.base(parent)
		if dir_name != 'skills' && dir_name.len > 0 {
			name = dir_name
		} else {
			return none
		}
	}
	if description.len == 0 {
		description = 'Custom skill: ${name}'
	}
	if body.len == 0 {
		return none
	}
	return Skill{
		name:        name
		description: description
		prompt:      body
		source:      source
		path:        path
		tags:        meta.tags
		tools:       meta.tools
		triggers:    meta.triggers
		platform:    meta.platform
		sections:    parse_skill_sections(body)
	}
}

fn parse_skill_frontmatter(frontmatter string) SkillFrontmatter {
	mut meta := SkillFrontmatter{}
	mut current_list_key := ''
	for raw_line in frontmatter.split('\n') {
		line := raw_line.trim_right('\r')
		trimmed := line.trim_space()
		if trimmed.len == 0 || trimmed.starts_with('#') {
			continue
		}
		if trimmed.starts_with('- ') && current_list_key.len > 0 {
			meta.append_list_value(current_list_key,
				trim_skill_frontmatter_value(trimmed[2..].trim_space()))
			continue
		}
		if !trimmed.contains(':') {
			current_list_key = ''
			continue
		}
		colon_idx := trimmed.index(':') or { continue }
		key := trimmed[..colon_idx].trim_space().to_lower()
		value := trimmed[colon_idx + 1..].trim_space()
		current_list_key = ''
		match key {
			'name', 'description', 'platform' {
				if value.len > 0 {
					meta.set_scalar_value(key, trim_skill_frontmatter_value(value))
				}
			}
			'tags', 'tools', 'triggers' {
				if value.len == 0 {
					current_list_key = key
					continue
				}
				for item in parse_skill_frontmatter_list(value) {
					meta.append_list_value(key, item)
				}
			}
			else {}
		}
	}
	meta.tags = dedupe_skill_values(meta.tags)
	meta.tools = dedupe_skill_values(meta.tools)
	meta.triggers = dedupe_skill_values(meta.triggers)
	return meta
}

fn parse_skill_frontmatter_list(value string) []string {
	mut trimmed := value.trim_space()
	if trimmed.len == 0 {
		return []string{}
	}
	if trimmed.starts_with('[') && trimmed.ends_with(']') && trimmed.len >= 2 {
		trimmed = trimmed[1..trimmed.len - 1].trim_space()
	}
	if trimmed.len == 0 {
		return []string{}
	}
	mut items := []string{}
	for part in trimmed.split(',') {
		item := trim_skill_frontmatter_value(part)
		if item.len > 0 {
			items << item
		}
	}
	return dedupe_skill_values(items)
}

fn trim_skill_frontmatter_value(value string) string {
	mut trimmed := value.trim_space()
	if trimmed.len >= 2 {
		if (trimmed[0] == `"` && trimmed[trimmed.len - 1] == `"`)
			|| (trimmed[0] == `'` && trimmed[trimmed.len - 1] == `'`) {
			trimmed = trimmed[1..trimmed.len - 1]
		}
	}
	return trimmed.trim_space()
}

fn (mut meta SkillFrontmatter) set_scalar_value(key string, value string) {
	match key {
		'name' {
			meta.name = value
		}
		'description' {
			meta.description = value
		}
		'platform' {
			meta.platform = value
		}
		else {}
	}
}

fn (mut meta SkillFrontmatter) append_list_value(key string, value string) {
	if value.len == 0 {
		return
	}
	match key {
		'tags' {
			meta.tags << value
		}
		'tools' {
			meta.tools << value
		}
		'triggers' {
			meta.triggers << value
		}
		else {}
	}
}

fn dedupe_skill_values(values []string) []string {
	mut seen := map[string]bool{}
	mut result := []string{}
	for value in values {
		trimmed := value.trim_space()
		if trimmed.len == 0 {
			continue
		}
		key := trimmed.to_lower()
		if key in seen {
			continue
		}
		seen[key] = true
		result << trimmed
	}
	return result
}

fn parse_skill_sections(content string) []SkillSection {
	lines := content.split('\n')
	mut sections := []SkillSection{}
	mut current := SkillSection{}
	mut current_lines := []string{}
	for line in lines {
		heading, level, ok := parse_skill_heading(line)
		if ok {
			append_skill_section(mut sections, current, current_lines.join('\n').trim_space())
			current = SkillSection{}
			current_lines.clear()
			current.heading = heading
			current.level = level
			continue
		}
		current_lines << line
	}
	append_skill_section(mut sections, current, current_lines.join('\n').trim_space())
	return sections
}

fn append_skill_section(mut sections []SkillSection, current SkillSection, text string) {
	if current.heading.len == 0 && text.len == 0 {
		return
	}
	sections << SkillSection{
		heading: current.heading
		level:   current.level
		content: text
	}
}

fn parse_skill_heading(line string) (string, int, bool) {
	trimmed := line.trim_space()
	if trimmed.len == 0 || !trimmed.starts_with('#') {
		return '', 0, false
	}
	mut level := 0
	for level < trimmed.len && trimmed[level] == `#` {
		level++
	}
	if level == 0 || level >= trimmed.len || trimmed[level] != ` ` {
		return '', 0, false
	}
	return trimmed[level..].trim_space(), level, true
}

fn normalize_skill_match_text(text string) string {
	return normalize_sop_match_text(text)
}

fn compact_skill_match_text(text string) string {
	return normalize_skill_match_text(text).replace(' ', '')
}

fn extract_skill_match_terms(text string) []string {
	return extract_sop_match_terms(text)
}

fn skill_field_score(text string, terms []string, long_weight int, short_weight int) (int, []string) {
	normalized := normalize_skill_match_text(text)
	if normalized.len == 0 || terms.len == 0 {
		return 0, []string{}
	}
	mut score := 0
	mut matched := []string{}
	for term in terms {
		if normalized.contains(term) {
			score += if term.len >= 4 { long_weight } else { short_weight }
			matched << term
		}
	}
	return score, dedupe_skill_values(matched)
}

fn skill_phrase_score(text string, compact_query string, weight int) bool {
	if compact_query.len == 0 || weight <= 0 {
		return false
	}
	return compact_skill_match_text(text).contains(compact_query)
}

fn skill_text_matches_all_terms(text string, terms []string) bool {
	if terms.len == 0 {
		return false
	}
	normalized := normalize_skill_match_text(text)
	for term in terms {
		if !normalized.contains(term) {
			return false
		}
	}
	return true
}

fn add_skill_match_data(mut matched_terms []string, mut matched_fields []string, field_name string, text string, terms []string, long_weight int, short_weight int) int {
	field_score, field_terms := skill_field_score(text, terms, long_weight, short_weight)
	if field_score <= 0 {
		return 0
	}
	for term in field_terms {
		if term !in matched_terms {
			matched_terms << term
		}
	}
	if field_name !in matched_fields {
		matched_fields << field_name
	}
	return field_score
}

fn score_skill_match(skill Skill, query string) SkillMatch {
	trimmed_query := query.trim_space()
	if trimmed_query.len == 0 {
		return SkillMatch{
			skill: skill
		}
	}
	terms := extract_skill_match_terms(trimmed_query)
	compact_query := compact_skill_match_text(trimmed_query)
	mut score := 0
	mut matched_terms := []string{}
	mut matched_fields := []string{}
	if skill_phrase_score(skill.name, compact_query, 90) {
		score += 90
		matched_fields << 'name'
	}
	if skill_phrase_score(skill.description, compact_query, 50) {
		score += 50
		if 'description' !in matched_fields {
			matched_fields << 'description'
		}
	}
	if skill_phrase_score(skill.tools.join(' '), compact_query, 80) {
		score += 80
		if 'tools' !in matched_fields {
			matched_fields << 'tools'
		}
	}
	if skill_phrase_score(skill.triggers.join(' '), compact_query, 75) {
		score += 75
		if 'triggers' !in matched_fields {
			matched_fields << 'triggers'
		}
	}
	score += add_skill_match_data(mut matched_terms, mut matched_fields, 'name', skill.name, terms,
		28, 18)
	score += add_skill_match_data(mut matched_terms, mut matched_fields, 'tools',
		skill.tools.join(' '), terms, 24, 14)
	score += add_skill_match_data(mut matched_terms, mut matched_fields, 'triggers',
		skill.triggers.join(' '), terms, 22, 13)
	score += add_skill_match_data(mut matched_terms, mut matched_fields, 'tags',
		skill.tags.join(' '), terms, 18, 11)
	score += add_skill_match_data(mut matched_terms, mut matched_fields, 'platform',
		skill.platform, terms, 14, 8)
	score += add_skill_match_data(mut matched_terms, mut matched_fields, 'description',
		skill.description, terms, 12, 7)
	for section in skill.sections {
		score += add_skill_match_data(mut matched_terms, mut matched_fields, 'sections',
			section.heading, terms, 10, 6)
	}
	score += add_skill_match_data(mut matched_terms, mut matched_fields, 'prompt', skill.prompt,
		terms, 6, 3)
	if skill_text_matches_all_terms(skill.name + ' ' + skill.tools.join(' ') + ' ' +
		skill.triggers.join(' ') + ' ' + skill.tags.join(' ') + ' ' + skill.platform, terms)
	{
		score += 20
	}
	return SkillMatch{
		skill:          skill
		score:          score
		matched_terms:  dedupe_skill_values(matched_terms)
		matched_fields: dedupe_skill_values(matched_fields)
	}
}

fn select_skill_matches_from_registry(registry SkillRegistry, query string, limit int) []SkillMatch {
	if registry.skills.len == 0 || query.trim_space().len == 0 {
		return []SkillMatch{}
	}
	mut matches := []SkillMatch{}
	for skill in registry.skills {
		skill_match := score_skill_match(skill, query)
		if skill_match.score > 0 {
			matches << skill_match
		}
	}
	if matches.len == 0 {
		return []SkillMatch{}
	}
	matches.sort_with_compare(fn (a &SkillMatch, b &SkillMatch) int {
		if a.score == b.score {
			if a.skill.name < b.skill.name {
				return -1
			}
			if a.skill.name > b.skill.name {
				return 1
			}
			return 0
		}
		if a.score > b.score {
			return -1
		}
		return 1
	})
	resolved_limit := if limit > 0 { limit } else { default_auto_skill_context_limit }
	if matches.len > resolved_limit {
		return matches[..resolved_limit]
	}
	return matches
}

fn select_relevant_skills(workspace string, query string, limit int) []SkillMatch {
	return select_skill_matches_from_registry(load_skill_registry(workspace), query, limit)
}

fn first_populated_skill_sections(sections []SkillSection, limit int) []SkillSection {
	if sections.len == 0 {
		return []SkillSection{}
	}
	mut selected := []SkillSection{}
	for section in sections {
		if section.content.trim_space().len == 0 {
			continue
		}
		selected << section
		if selected.len >= limit {
			break
		}
	}
	return selected
}

fn score_skill_section(section SkillSection, query string) int {
	terms := extract_skill_match_terms(query)
	compact_query := compact_skill_match_text(query)
	mut score := 0
	if skill_phrase_score(section.heading, compact_query, 30) {
		score += 30
	}
	if skill_phrase_score(section.content, compact_query, 18) {
		score += 18
	}
	heading_score, _ := skill_field_score(section.heading, terms, 10, 6)
	content_score, _ := skill_field_score(section.content, terms, 4, 2)
	score += heading_score + content_score
	return score
}

fn select_relevant_skill_sections(skill Skill, query string, limit int) []SkillSection {
	if skill.sections.len == 0 {
		return []SkillSection{}
	}
	if query.trim_space().len == 0 {
		return first_populated_skill_sections(skill.sections, limit)
	}
	mut scored := []SkillMatch{}
	mut section_lookup := map[string]SkillSection{}
	for idx, section in skill.sections {
		if section.content.trim_space().len == 0 {
			continue
		}
		mut section_score := score_skill_section(section, query)
		if idx == 0 && section_score == 0 {
			section_score = 1
		}
		if section_score <= 0 {
			continue
		}
		key := '${idx}:${section.heading}'
		section_lookup[key] = section
		scored << SkillMatch{
			skill: Skill{
				name: key
			}
			score: section_score
		}
	}
	if scored.len == 0 {
		return first_populated_skill_sections(skill.sections, limit)
	}
	scored.sort_with_compare(fn (a &SkillMatch, b &SkillMatch) int {
		if a.score == b.score {
			if a.skill.name < b.skill.name {
				return -1
			}
			if a.skill.name > b.skill.name {
				return 1
			}
			return 0
		}
		if a.score > b.score {
			return -1
		}
		return 1
	})
	resolved_limit := if limit > 0 { limit } else { 2 }
	mut result := []SkillSection{}
	for scored_section in scored {
		if section := section_lookup[scored_section.skill.name] {
			result << section
		}
		if result.len >= resolved_limit {
			break
		}
	}
	return result
}

fn build_skill_excerpt(skill Skill, query string, section_limit int, char_limit int) string {
	mut sections := select_relevant_skill_sections(skill, query, section_limit)
	if sections.len == 0 {
		sections = first_populated_skill_sections(skill.sections, section_limit)
	}
	if sections.len == 0 {
		if skill.prompt.len == 0 {
			return ''
		}
		return utf8_safe_truncate(skill.prompt.trim_space(), char_limit)
	}
	mut parts := []string{}
	for section in sections {
		text := utf8_safe_truncate(section.content.trim_space(), max_auto_skill_section_chars)
		if text.len == 0 {
			continue
		}
		title := if section.heading.len > 0 { section.heading } else { 'Overview' }
		parts << '### ${title}\n${text}'
	}
	if parts.len == 0 {
		return utf8_safe_truncate(skill.prompt.trim_space(), char_limit)
	}
	return utf8_safe_truncate(parts.join('\n\n'), char_limit)
}

fn build_auto_skills_context_from_registry(registry SkillRegistry, query string, limit int) string {
	matches := select_skill_matches_from_registry(registry, query, limit)
	if matches.len == 0 {
		return ''
	}
	mut lines := [
		'Auto-selected skills for the current task (chosen locally from the discovered skill set):',
		'Review the shortlist below. If one is clearly relevant, call activate_skill with that skill before continuing. If none clearly fit, continue without activating a skill.',
	]
	for idx, skill_match in matches {
		lines << '${idx + 1}. ${skill_match.skill.name}: ${skill_match.skill.description} [${skill_match.skill.source}]'
		if skill_match.matched_fields.len > 0 {
			lines << '   - matched_fields: ${skill_match.matched_fields.join(', ')}'
		}
		if skill_match.matched_terms.len > 0 {
			lines << '   - matched_terms: ${skill_match.matched_terms.join(', ')}'
		}
		if skill_match.skill.tools.len > 0 {
			lines << '   - tools: ${skill_match.skill.tools.join(', ')}'
		}
		if skill_match.skill.triggers.len > 0 {
			lines << '   - triggers: ${skill_match.skill.triggers.join(' | ')}'
		}
		if skill_match.skill.platform.len > 0 {
			lines << '   - platform: ${skill_match.skill.platform}'
		}
		excerpt := build_skill_excerpt(skill_match.skill, query, 2, max_auto_skill_excerpt_chars)
		if excerpt.len > 0 {
			lines << '   - relevant_notes:'
			for excerpt_line in excerpt.split('\n') {
				lines << '     ${excerpt_line}'
			}
		}
	}
	return lines.join('\n')
}

fn build_auto_skills_context(workspace string, query string, limit int) string {
	return build_auto_skills_context_from_registry(load_skill_registry(workspace), query, limit)
}

// Find a skill by name from the registry
fn find_skill(workspace string, name string) ?Skill {
	registry := load_skill_registry(workspace)
	for skill in registry.skills {
		if skill.name == name {
			return skill
		}
	}
	return none
}

// Get all skills (for listing)
fn get_all_skills(workspace string) []Skill {
	registry := load_skill_registry(workspace)
	return registry.skills
}

// Activate a skill: load its full prompt into the system
fn activate_skill_tool(workspace string, name string) string {
	registry := load_skill_registry(workspace)
	for skill in registry.skills {
		if skill.name == name {
			mut info := '✅ Skill activated: "${skill.name}" — ${skill.description}\n'
			info += 'Source: ${skill.source}'
			if skill.path.len > 0 {
				info += ' (${skill.path})'
			}
			info += '\n\n--- Skill Instructions ---\n${skill.prompt}\n--- End Skill ---'
			return info
		}
	}
	// List available
	mut available := 'Error: Skill "${name}" not found.\nAvailable skills:\n'
	for skill in registry.skills {
		available += '  - ${skill.name}: ${skill.description} [${skill.source}]\n'
	}
	return available
}

// Build skills metadata string for system prompt injection
// Only injects compact metadata (not full prompt) to save tokens
fn build_skills_metadata(workspace string) string {
	return build_skills_metadata_from_registry(load_skill_registry(workspace))
}

// Create a new skill template
fn create_skill_template(name string, dir string) string {
	skill_dir := os.join_path(dir, name)
	if os.is_dir(skill_dir) {
		return 'Error: Skill directory already exists: ${skill_dir}'
	}
	os.mkdir_all(skill_dir) or { return 'Error: ${err.msg}' }
	template := '---\nname: ${name}\ndescription: Describe what this skill does\ntags:\n  - example\ntools:\n  - bash\ntriggers:\n  - Example request this skill should match\nplatform: cross-platform\n---\n\n# Overview\n\nYou are a specialized expert in ${name}.\n\n## Responsibilities\n\n1. ...\n2. ...\n3. ...\n\n## Workflow\n\n- Be thorough and precise\n- Explain your reasoning\n- Follow best practices\n'
	skill_path := os.join_path(skill_dir, 'SKILL.md')
	os.write_file(skill_path, template) or { return 'Error: ${err.msg}' }
	return '✅ Skill template created: ${skill_path}\n   Edit the SKILL.md file to customize the skill instructions.'
}

// Print enhanced skills list with source info
fn print_skills_list(workspace string, active_skill string) {
	registry := load_skill_registry(workspace)
	skills := registry.skills
	println('🎯 可用技能 (Skills):')
	println('')
	// Group by source
	mut has_project := false
	mut has_user := false
	mut has_builtin := false
	for skill in skills {
		match skill.source {
			'project' { has_project = true }
			'user' { has_user = true }
			else { has_builtin = true }
		}
	}
	if has_project {
		println('  \x1b[1m📂 项目技能 (.agents/skills/):\x1b[0m')
		for skill in skills {
			if skill.source == 'project' {
				active := if active_skill == skill.name {
					' \x1b[32m◀ 已激活\x1b[0m'
				} else {
					''
				}
				println('    \x1b[36m${skill.name}\x1b[0m  ${skill.description}${active}')
			}
		}
		println('')
	}
	if has_user {
		println('  \x1b[1m👤 用户技能 (~/.config/minimax/skills/):\x1b[0m')
		for skill in skills {
			if skill.source == 'user' {
				active := if active_skill == skill.name {
					' \x1b[32m◀ 已激活\x1b[0m'
				} else {
					''
				}
				println('    \x1b[36m${skill.name}\x1b[0m  ${skill.description}${active}')
			}
		}
		println('')
	}
	if has_builtin {
		println('  \x1b[1m⚙️  内置技能:\x1b[0m')
		for skill in skills {
			if skill.source == 'builtin' {
				active := if active_skill == skill.name {
					' \x1b[32m◀ 已激活\x1b[0m'
				} else {
					''
				}
				println('    \x1b[36m${skill.name}\x1b[0m  ${skill.description}${active}')
			}
		}
		println('')
	}
	println('用法:')
	println('  skill <name>              手动切换技能')
	println('  skills reload              重新扫描技能')
	println('  skills create <name>       创建自定义技能模板')
	println('')
	println('自定义技能目录:')
	println('  项目级: .agents/skills/<name>/SKILL.md')
	println('  用户级: ~/.config/minimax/skills/<name>/SKILL.md')
	println('')
}

// --- Built-in Skills ---

fn get_builtin_skills() []Skill {
	return [
		Skill{
			name:        'coder'
			description: '软件开发专家'
			prompt:      'You are an expert software developer. You write clean, efficient, well-tested code. You follow best practices and design patterns. When modifying existing code, you first read and understand the codebase. You write tests for your changes. You provide clear commit messages and documentation.'
			source:      'builtin'
		},
		Skill{
			name:        'reviewer'
			description: '代码审查专家'
			prompt:      'You are a thorough code reviewer. You check for bugs, security vulnerabilities, performance issues, and code quality problems. You provide constructive feedback with specific line references. You suggest improvements with example code. You check for edge cases, error handling, and test coverage.'
			source:      'builtin'
		},
		Skill{
			name:        'architect'
			description: '系统架构师'
			prompt:      'You are a system architect. You design scalable, maintainable software systems. You evaluate tradeoffs between different approaches. You create clear diagrams and documentation. You consider performance, security, reliability, and cost. You define API contracts and data models.'
			source:      'builtin'
		},
		Skill{
			name:        'debugger'
			description: '调试专家'
			prompt:      'You are an expert debugger. You systematically diagnose issues by analyzing error messages, logs, and code paths. You form hypotheses and verify them step by step. You use tools to read files, run commands, and inspect state. You find root causes rather than treating symptoms. You explain your debugging process clearly.'
			source:      'builtin'
		},
		Skill{
			name:        'tester'
			description: '测试工程师'
			prompt:      'You are a test engineering expert. You write comprehensive test suites covering unit tests, integration tests, and edge cases. You follow testing best practices like AAA (Arrange-Act-Assert) pattern. You aim for high coverage while keeping tests maintainable. You use appropriate testing frameworks and mock strategies.'
			source:      'builtin'
		},
		Skill{
			name:        'devops'
			description: 'DevOps 工程师'
			prompt:      'You are a DevOps expert. You set up CI/CD pipelines, containerization (Docker), and infrastructure as code. You automate deployment processes. You configure monitoring and alerting. You optimize build times and resource usage. You ensure security best practices in deployment.'
			source:      'builtin'
		},
		Skill{
			name:        'documenter'
			description: '技术文档专家'
			prompt:      'You are a technical documentation expert. You write clear, comprehensive documentation including README files, API references, architecture guides, and tutorials. You use proper markdown formatting. You include examples and diagrams. You organize content logically for the target audience.'
			source:      'builtin'
		},
		Skill{
			name:        'refactorer'
			description: '代码重构专家'
			prompt:      'You are a refactoring expert. You improve code structure without changing behavior. You identify code smells and apply appropriate refactoring patterns. You work in small, safe steps and verify each change. You improve naming, reduce duplication, extract functions/modules, and simplify complex logic.'
			source:      'builtin'
		},
		Skill{
			name:        'security'
			description: '安全专家'
			prompt:      'You are a security expert. You identify and fix security vulnerabilities including injection attacks, authentication issues, data exposure, and misconfigurations. You follow OWASP guidelines. You implement secure coding practices. You review dependencies for known vulnerabilities.'
			source:      'builtin'
		},
		Skill{
			name:        'performance'
			description: '性能优化专家'
			prompt:      'You are a performance optimization expert. You identify bottlenecks through profiling and analysis. You optimize algorithms, database queries, memory usage, and I/O operations. You use caching strategies appropriately. You measure before and after optimization to verify improvements.'
			source:      'builtin'
		},
		Skill{
			name:        'database'
			description: '数据库专家'
			prompt:      'You are a database expert. You design efficient schemas, write optimized queries, and manage migrations. You understand indexing strategies, transaction isolation levels, and replication. You handle both SQL and NoSQL databases. You ensure data integrity and backup strategies.'
			source:      'builtin'
		},
		Skill{
			name:        'frontend'
			description: '前端开发专家'
			prompt:      'You are a frontend development expert. You build responsive, accessible, and performant user interfaces. You master HTML, CSS, JavaScript/TypeScript, and modern frameworks (React, Vue, etc.). You follow accessibility standards (WCAG). You optimize loading performance and user experience.'
			source:      'builtin'
		},
		Skill{
			name:        'api'
			description: 'API 设计专家'
			prompt:      'You are an API design expert. You design RESTful and GraphQL APIs following best practices. You define clear contracts with proper HTTP methods, status codes, and error handling. You implement authentication, rate limiting, and versioning. You write comprehensive API documentation with examples.'
			source:      'builtin'
		},
		Skill{
			name:        'data'
			description: '数据分析专家'
			prompt:      'You are a data analysis expert. You clean, transform, and analyze datasets. You create visualizations and reports. You use statistical methods appropriately. You write efficient data processing pipelines. You communicate findings clearly with actionable insights.'
			source:      'builtin'
		},
		Skill{
			name:        'sysadmin'
			description: '系统管理员'
			prompt:      'You are a system administration expert. You manage Linux/Unix servers, configure networking, and handle system monitoring. You automate routine tasks with shell scripts. You manage users, permissions, and services. You troubleshoot system issues and optimize resource usage. You implement backup and disaster recovery plans.'
			source:      'builtin'
		},
	]
}
