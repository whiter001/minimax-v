module main

import os
import time

const experience_skill_auto_begin = '<!-- BEGIN AUTO-GENERATED EXPERIENCE -->'
const experience_skill_auto_end = '<!-- END AUTO-GENERATED EXPERIENCE -->'
const experience_sop_auto_begin = '<!-- BEGIN AUTO-GENERATED SOP -->'
const experience_sop_auto_end = '<!-- END AUTO-GENERATED SOP -->'
const max_skill_sync_records = 12
const max_skill_sync_rules = 6
const experience_sync_mode_balanced = 'balanced'
const experience_sync_mode_concise = 'concise'
const experience_sync_mode_strict = 'strict'

struct ExperienceAutomationSettings {
	auto_write_skills bool
	auto_upgrade_sops bool
	sync_mode         string
	skill_root        string
	sop_root          string
}

struct ExperienceRecord {
mut:
	id           int
	skill_name   string
	title        string
	scenario     string
	action_taken string
	outcome      string
	tags         string
	confidence   int
	source       string
	created_at   i64
	updated_at   i64
}

struct ExperienceWizardPrompter {
	interactive bool
mut:
	scripted_values []string
	index           int
}

fn get_knowledge_root_dir() string {
	return os.join_path(get_minimax_config_dir(), 'knowledge')
}

fn get_experience_db_path() string {
	return os.join_path(get_knowledge_root_dir(), 'skills.db')
}

fn get_experience_jsonl_path() string {
	return os.join_path(get_knowledge_root_dir(), 'experiences.jsonl')
}

fn get_experience_markdown_dir() string {
	return os.join_path(get_knowledge_root_dir(), 'skills')
}

fn get_global_skills_dir() string {
	return os.join_path(get_minimax_config_dir(), 'skills')
}

fn get_global_sops_dir() string {
	return os.join_path(get_minimax_config_dir(), 'sops')
}

fn sop_file_path(skill_name string, sop_root string) string {
	return os.join_path(sop_root, skill_name, 'SOP.md')
}

fn sqlite_cli_path() string {
	return os.find_abs_path_of_executable('sqlite3') or { '' }
}

fn sqlite_cli_available() bool {
	return sqlite_cli_path().len > 0
}

fn disabled_experience_automation_settings() ExperienceAutomationSettings {
	return ExperienceAutomationSettings{
		auto_write_skills: false
		auto_upgrade_sops: false
		sync_mode:         experience_sync_mode_balanced
		skill_root:        ''
		sop_root:          ''
	}
}

fn load_experience_automation_settings() ExperienceAutomationSettings {
	mut config := load_config_file()
	apply_env_overrides(mut config)
	return ExperienceAutomationSettings{
		auto_write_skills: config.auto_write_skills
		auto_upgrade_sops: config.auto_upgrade_sops
		sync_mode:         normalize_experience_sync_mode(config.knowledge_sync_mode)
		skill_root:        get_global_skills_dir()
		sop_root:          get_global_sops_dir()
	}
}

fn ensure_experience_storage(jsonl_path string, markdown_dir string) ! {
	os.mkdir_all(os.dir(jsonl_path))!
	os.mkdir_all(markdown_dir)!
}

fn sql_quote(s string) string {
	return "'" + s.replace("'", "''") + "'"
}

fn sqlite_exec(db_path string, statement string) !string {
	sqlite_path := sqlite_cli_path()
	if sqlite_path.len == 0 {
		return error('sqlite3 不可用')
	}
	os.mkdir_all(os.dir(db_path)) or {}
	mut proc := os.new_process(sqlite_path)
	proc.set_args([db_path, statement])
	proc.use_stdio_ctl = true
	proc.run()
	mut output := proc.stdout_slurp()
	output += proc.stderr_slurp()
	proc.wait()
	if proc.code != 0 {
		return error(output.trim_space())
	}
	return output
}

fn ensure_experience_db(db_path string) ! {
	statement := 'CREATE TABLE IF NOT EXISTS experiences (' +
		'id INTEGER PRIMARY KEY AUTOINCREMENT,' + 'skill_name TEXT NOT NULL,' +
		'title TEXT NOT NULL,' + "scenario TEXT DEFAULT ''," + "action_taken TEXT DEFAULT ''," +
		"outcome TEXT DEFAULT ''," + "tags TEXT DEFAULT ''," + 'confidence INTEGER DEFAULT 3,' +
		"source TEXT DEFAULT 'manual'," + 'created_at INTEGER NOT NULL,' +
		'updated_at INTEGER NOT NULL' + ');' +
		'CREATE INDEX IF NOT EXISTS idx_experiences_skill_name ON experiences(skill_name);' +
		'CREATE INDEX IF NOT EXISTS idx_experiences_created_at ON experiences(created_at DESC);'
	_ = sqlite_exec(db_path, statement)!
}

fn decode_json_field(json_payload string, key string) string {
	return decode_json_string(extract_json_string_value(json_payload, key)).trim_space()
}

fn build_experience_record(skill_name string, title string, scenario string, action_taken string, outcome string, tags string, confidence int, source string) !ExperienceRecord {
	trimmed_skill := skill_name.trim_space()
	trimmed_title := title.trim_space()
	if trimmed_skill.len == 0 {
		return error('缺少必填字段 skill')
	}
	if trimmed_title.len == 0 {
		return error('缺少必填字段 title')
	}
	now := time.now().unix()
	mut normalized_confidence := confidence
	if normalized_confidence <= 0 {
		normalized_confidence = 3
	}
	if normalized_confidence > 5 {
		normalized_confidence = 5
	}
	mut normalized_source := source.trim_space()
	if normalized_source.len == 0 {
		normalized_source = 'manual'
	}
	return ExperienceRecord{
		skill_name:   trimmed_skill
		title:        trimmed_title
		scenario:     scenario.trim_space()
		action_taken: action_taken.trim_space()
		outcome:      outcome.trim_space()
		tags:         tags.trim_space()
		confidence:   normalized_confidence
		source:       normalized_source
		created_at:   now
		updated_at:   now
	}
}

fn new_interactive_experience_wizard_prompter() ExperienceWizardPrompter {
	return ExperienceWizardPrompter{
		interactive: true
	}
}

fn new_scripted_experience_wizard_prompter(values []string) ExperienceWizardPrompter {
	return ExperienceWizardPrompter{
		interactive:     false
		scripted_values: values.clone()
	}
}

fn (mut prompter ExperienceWizardPrompter) prompt_field(label string, required bool) ?string {
	for {
		value := if prompter.interactive {
			os.input(label).trim_space()
		} else {
			if prompter.index >= prompter.scripted_values.len {
				return none
			}
			next_value := prompter.scripted_values[prompter.index]
			prompter.index++
			next_value.trim_space()
		}
		if value.len > 0 || !required {
			return value
		}
		if prompter.interactive {
			println('⚠️  该字段必填')
		}
	}
	return none
}

fn collect_experience_wizard_record(mut prompter ExperienceWizardPrompter) !ExperienceRecord {
	skill_name := prompter.prompt_field('skill: ', true) or { return error('已取消') }
	title := prompter.prompt_field('title: ', true) or { return error('已取消') }
	scenario := prompter.prompt_field('scenario: ', false) or { return error('已取消') }
	action_taken := prompter.prompt_field('action: ', false) or { return error('已取消') }
	outcome := prompter.prompt_field('outcome: ', false) or { return error('已取消') }
	tags := prompter.prompt_field('tags: ', false) or { return error('已取消') }
	confidence_text := prompter.prompt_field('confidence (1-5, default 3): ', false) or {
		return error('已取消')
	}
	confidence := if confidence_text.len > 0 { confidence_text.int() } else { 3 }
	return build_experience_record(skill_name, title, scenario, action_taken, outcome,
		tags, confidence, 'wizard')
}

fn append_experience_automation_results(mut lines []string, record ExperienceRecord, settings ExperienceAutomationSettings, jsonl_path string) {
	resolved_mode := normalize_experience_sync_mode(settings.sync_mode)
	if settings.auto_write_skills && settings.skill_root.len > 0 {
		lines << sync_skill_from_knowledge_with_paths(record.skill_name, resolved_mode,
			settings.skill_root, jsonl_path)
	}
	if settings.auto_upgrade_sops && settings.sop_root.len > 0 {
		lines << sync_sop_from_knowledge_with_paths(record.skill_name, resolved_mode,
			settings.sop_root, jsonl_path)
	}
}

fn store_experience_record_with_paths_and_automation(mut record ExperienceRecord, db_path string, jsonl_path string, markdown_dir string, settings ExperienceAutomationSettings) string {
	ensure_experience_storage(jsonl_path, markdown_dir) or { return 'Error: ${err.msg()}' }
	if sqlite_cli_available() {
		record.id = insert_experience_sqlite(record, db_path) or { return 'Error: ${err.msg()}' }
	}
	append_experience_jsonl(record, jsonl_path) or { return 'Error: ${err.msg()}' }
	append_experience_markdown(record, markdown_dir) or { return 'Error: ${err.msg()}' }
	mut lines := ['✅ 已记录经验']
	if record.id > 0 {
		lines << 'id: ${record.id}'
	}
	lines << 'skill: ${record.skill_name}'
	lines << 'title: ${record.title}'
	lines << 'confidence: ${record.confidence}'
	lines << 'store: JSONL + Markdown' + if sqlite_cli_available() { ' + SQLite' } else { '' }
	append_experience_automation_results(mut lines, record, settings, jsonl_path)
	return lines.join('\n')
}

fn store_experience_record_with_paths(mut record ExperienceRecord, db_path string, jsonl_path string, markdown_dir string) string {
	return store_experience_record_with_paths_and_automation(mut record, db_path, jsonl_path,
		markdown_dir, disabled_experience_automation_settings())
}

fn experience_add_wizard_with_prompter_and_automation(mut prompter ExperienceWizardPrompter, db_path string, jsonl_path string, markdown_dir string, settings ExperienceAutomationSettings) string {
	mut record := collect_experience_wizard_record(mut prompter) or {
		return if err.msg() == '已取消' { '已取消' } else { 'Error: ${err.msg()}' }
	}
	return store_experience_record_with_paths_and_automation(mut record, db_path, jsonl_path,
		markdown_dir, settings)
}

fn experience_add_wizard_with_prompter(mut prompter ExperienceWizardPrompter, db_path string, jsonl_path string, markdown_dir string) string {
	return experience_add_wizard_with_prompter_and_automation(mut prompter, db_path, jsonl_path,
		markdown_dir, disabled_experience_automation_settings())
}

fn experience_add_wizard_with_paths(db_path string, jsonl_path string, markdown_dir string) string {
	println('📝 经验录入向导')
	mut prompter := new_interactive_experience_wizard_prompter()
	return experience_add_wizard_with_prompter(mut prompter, db_path, jsonl_path, markdown_dir)
}

fn experience_add_wizard_with_paths_and_automation(db_path string, jsonl_path string, markdown_dir string, settings ExperienceAutomationSettings) string {
	println('📝 经验录入向导')
	mut prompter := new_interactive_experience_wizard_prompter()
	return experience_add_wizard_with_prompter_and_automation(mut prompter, db_path, jsonl_path,
		markdown_dir, settings)
}

fn experience_add_wizard_with_scripted_inputs(inputs []string, db_path string, jsonl_path string, markdown_dir string) string {
	mut prompter := new_scripted_experience_wizard_prompter(inputs)
	return experience_add_wizard_with_prompter(mut prompter, db_path, jsonl_path, markdown_dir)
}

fn experience_add_wizard() string {
	return experience_add_wizard_with_paths_and_automation(get_experience_db_path(), get_experience_jsonl_path(),
		get_experience_markdown_dir(), load_experience_automation_settings())
}

fn normalize_experience_sync_mode(mode string) string {
	trimmed := mode.trim_space().to_lower()
	return match trimmed {
		experience_sync_mode_concise { experience_sync_mode_concise }
		experience_sync_mode_strict { experience_sync_mode_strict }
		else { experience_sync_mode_balanced }
	}
}

fn is_experience_sync_mode(mode string) bool {
	trimmed := mode.trim_space().to_lower()
	return trimmed in [experience_sync_mode_balanced, experience_sync_mode_concise,
		experience_sync_mode_strict]
}

fn parse_skill_sync_target_and_mode(arg string) (string, string) {
	trimmed := arg.trim_space()
	if trimmed.len == 0 {
		return '', experience_sync_mode_balanced
	}
	parts := trimmed.split(' ').filter(it.trim_space().len > 0)
	if parts.len == 0 {
		return '', experience_sync_mode_balanced
	}
	if parts.len == 1 {
		return parts[0], experience_sync_mode_balanced
	}
	if is_experience_sync_mode(parts[0]) {
		return parts[1..].join(' '), normalize_experience_sync_mode(parts[0])
	}
	last := parts[parts.len - 1]
	if is_experience_sync_mode(last) {
		return parts[..parts.len - 1].join(' '), normalize_experience_sync_mode(last)
	}
	return trimmed, experience_sync_mode_balanced
}

fn parse_experience_kv_payload(payload string) !ExperienceRecord {
	mut values := map[string]string{}
	for part in payload.split(';') {
		segment := part.trim_space()
		if segment.len == 0 || !segment.contains('=') {
			continue
		}
		eq_idx := segment.index('=') or { continue }
		key := segment[..eq_idx].trim_space().to_lower()
		val := segment[eq_idx + 1..].trim_space()
		values[key] = val
	}
	if values.len == 0 {
		return error('不是合法的 key=value 经验格式')
	}
	confidence := (values['confidence'] or { values['c'] or { '3' } }).trim_space().int()
	return build_experience_record(values['skill'] or { values['s'] or { '' } }, values['title'] or {
		values['t'] or { '' }
	}, values['scenario'] or { '' }, values['action'] or { '' }, values['outcome'] or { '' },
		values['tags'] or { '' }, confidence, values['source'] or { '' })
}

fn parse_experience_pipe_payload(payload string) !ExperienceRecord {
	parts := payload.split('|').map(it.trim_space())
	if parts.len < 2 {
		return error('不是合法的管道经验格式')
	}
	skill_name := parts[0]
	title := parts[1]
	scenario := if parts.len > 2 { parts[2] } else { '' }
	action_taken := if parts.len > 3 { parts[3] } else { '' }
	outcome := if parts.len > 4 { parts[4] } else { '' }
	tags := if parts.len > 5 { parts[5] } else { '' }
	confidence := if parts.len > 6 { parts[6].int() } else { 3 }
	return build_experience_record(skill_name, title, scenario, action_taken, outcome,
		tags, confidence, 'manual')
}

fn parse_experience_json(payload string) !ExperienceRecord {
	trimmed := payload.trim_space()
	if !trimmed.starts_with('{') {
		return error('experience add 需要 JSON 对象，例如: experience add {"skill":"demo","title":"..."}')
	}
	return build_experience_record(decode_json_field(trimmed, 'skill'), decode_json_field(trimmed,
		'title'), decode_json_field(trimmed, 'scenario'), decode_json_field(trimmed, 'action'),
		decode_json_field(trimmed, 'outcome'), decode_json_field(trimmed, 'tags'), int(extract_json_number_value(trimmed,
		'confidence')), decode_json_field(trimmed, 'source'))
}

fn parse_experience_payload(payload string) !ExperienceRecord {
	trimmed := payload.trim_space()
	if trimmed.starts_with('{') {
		return parse_experience_json(trimmed)
	}
	if trimmed.contains('=') && trimmed.contains(';') {
		return parse_experience_kv_payload(trimmed)
	}
	if trimmed.contains('|') {
		return parse_experience_pipe_payload(trimmed)
	}
	return error('experience add 支持 3 种格式: JSON、skill=...; title=...; ...、skill | title | scenario | action | outcome | tags | confidence')
}

fn build_experience_json_line(record ExperienceRecord) string {
	return '{' + '"skill":"${escape_json_string(record.skill_name)}",' + '"id":${record.id},' +
		'"title":"${escape_json_string(record.title)}",' +
		'"scenario":"${escape_json_string(record.scenario)}",' +
		'"action":"${escape_json_string(record.action_taken)}",' +
		'"outcome":"${escape_json_string(record.outcome)}",' +
		'"tags":"${escape_json_string(record.tags)}",' + '"confidence":${record.confidence},' +
		'"source":"${escape_json_string(record.source)}",' + '"created_at":${record.created_at},' +
		'"updated_at":${record.updated_at}' + '}'
}

fn parse_experience_json_line(line string) ?ExperienceRecord {
	trimmed := line.trim_space()
	if trimmed.len == 0 || !trimmed.starts_with('{') {
		return none
	}
	skill_name := decode_json_field(trimmed, 'skill')
	title := decode_json_field(trimmed, 'title')
	if skill_name.len == 0 || title.len == 0 {
		return none
	}
	mut confidence := int(extract_json_number_value(trimmed, 'confidence'))
	if confidence <= 0 {
		confidence = 3
	}
	return ExperienceRecord{
		id:           int(extract_json_number_value(trimmed, 'id'))
		skill_name:   skill_name
		title:        title
		scenario:     decode_json_field(trimmed, 'scenario')
		action_taken: decode_json_field(trimmed, 'action')
		outcome:      decode_json_field(trimmed, 'outcome')
		tags:         decode_json_field(trimmed, 'tags')
		confidence:   confidence
		source:       decode_json_field(trimmed, 'source')
		created_at:   extract_json_number_value(trimmed, 'created_at')
		updated_at:   extract_json_number_value(trimmed, 'updated_at')
	}
}

fn append_experience_jsonl(record ExperienceRecord, jsonl_path string) ! {
	mut content := ''
	if os.is_file(jsonl_path) {
		content = os.read_file(jsonl_path) or { '' }
	}
	mut next_content := content
	if next_content.len > 0 && !next_content.ends_with('\n') {
		next_content += '\n'
	}
	next_content += build_experience_json_line(record) + '\n'
	os.write_file(jsonl_path, next_content)!
}

fn experience_markdown_path(skill_name string, markdown_dir string) string {
	return os.join_path(markdown_dir, '${sanitize_extension_name(skill_name)}.md')
}

fn append_experience_markdown(record ExperienceRecord, markdown_dir string) ! {
	path := experience_markdown_path(record.skill_name, markdown_dir)
	mut content := ''
	if os.is_file(path) {
		content = os.read_file(path) or { '' }
	} else {
		content = '# Experience Notes: ${record.skill_name}\n\n'
	}
	ts := time.unix(record.created_at).format_ss()
	mut block := '## ${ts} - ${record.title}\n'
	if record.scenario.len > 0 {
		block += '- Scenario: ${record.scenario}\n'
	}
	if record.action_taken.len > 0 {
		block += '- Action: ${record.action_taken}\n'
	}
	if record.outcome.len > 0 {
		block += '- Outcome: ${record.outcome}\n'
	}
	if record.tags.len > 0 {
		block += '- Tags: ${record.tags}\n'
	}
	block += '- Confidence: ${record.confidence}\n'
	block += '- Source: ${record.source}\n\n'
	if content.len > 0 && !content.ends_with('\n\n') {
		if content.ends_with('\n') {
			content += '\n'
		} else {
			content += '\n\n'
		}
	}
	content += block
	os.write_file(path, content)!
}

fn insert_experience_sqlite(record ExperienceRecord, db_path string) !int {
	if !sqlite_cli_available() {
		return 0
	}
	ensure_experience_db(db_path)!
	statement :=
		'INSERT INTO experiences (skill_name, title, scenario, action_taken, outcome, tags, confidence, source, created_at, updated_at) VALUES (' +
		sql_quote(record.skill_name) + ', ' + sql_quote(record.title) + ', ' +
		sql_quote(record.scenario) + ', ' + sql_quote(record.action_taken) + ', ' +
		sql_quote(record.outcome) + ', ' + sql_quote(record.tags) + ', ' +
		'${record.confidence}, ' + sql_quote(record.source) +
		', ${record.created_at}, ${record.updated_at}) RETURNING id;'
	output := sqlite_exec(db_path, statement)!
	return output.trim_space().int()
}

fn record_experience_payload_with_paths_and_automation(payload string, db_path string, jsonl_path string, markdown_dir string, settings ExperienceAutomationSettings) string {
	mut record := parse_experience_payload(payload) or { return 'Error: ${err.msg()}' }
	return store_experience_record_with_paths_and_automation(mut record, db_path, jsonl_path,
		markdown_dir, settings)
}

fn record_experience_payload_with_paths(payload string, db_path string, jsonl_path string, markdown_dir string) string {
	return record_experience_payload_with_paths_and_automation(payload, db_path, jsonl_path,
		markdown_dir, disabled_experience_automation_settings())
}

fn record_experience_payload(payload string) string {
	return record_experience_payload_with_paths_and_automation(payload, get_experience_db_path(),
		get_experience_jsonl_path(), get_experience_markdown_dir(), load_experience_automation_settings())
}

fn record_experience_from_tool_input_with_paths(input map[string]string, db_path string, jsonl_path string, markdown_dir string, settings ExperienceAutomationSettings) string {
	payload := (input['payload'] or { '' }).trim_space()
	if payload.len > 0 {
		return record_experience_payload_with_paths_and_automation(payload, db_path, jsonl_path,
			markdown_dir, settings)
	}
	confidence_text := (input['confidence'] or { '3' }).trim_space()
	confidence := if confidence_text.len > 0 { confidence_text.int() } else { 3 }
	mut record := build_experience_record(input['skill'] or { '' }, input['title'] or { '' },
		input['scenario'] or { '' }, input['action'] or { input['action_taken'] or { '' } },
		input['outcome'] or { '' }, input['tags'] or { '' }, confidence, input['source'] or {
		'tool'
	}) or { return 'Error: ${err.msg()}' }
	return store_experience_record_with_paths_and_automation(mut record, db_path, jsonl_path,
		markdown_dir, settings)
}

fn record_experience_from_tool_input(input map[string]string) string {
	return record_experience_from_tool_input_with_paths(input, get_experience_db_path(),
		get_experience_jsonl_path(), get_experience_markdown_dir(), load_experience_automation_settings())
}

fn load_experience_records_from_jsonl(jsonl_path string) []ExperienceRecord {
	if !os.is_file(jsonl_path) {
		return []ExperienceRecord{}
	}
	content := os.read_file(jsonl_path) or { return []ExperienceRecord{} }
	mut records := []ExperienceRecord{}
	for line in content.split('\n') {
		if record := parse_experience_json_line(line) {
			records << record
		}
	}
	records.sort(a.created_at > b.created_at)
	return records
}

fn experience_record_display_id(record ExperienceRecord, ordinal int) int {
	if record.id > 0 {
		return record.id
	}
	return ordinal + 1
}

fn filter_experience_records(records []ExperienceRecord, skill_filter string) []ExperienceRecord {
	trimmed := skill_filter.trim_space()
	if trimmed.len == 0 || trimmed == 'all' {
		return records.clone()
	}
	mut filtered := []ExperienceRecord{}
	for record in records {
		if record.skill_name == trimmed {
			filtered << record
		}
	}
	return filtered
}

fn experience_list_text_with_paths(arg string, jsonl_path string) string {
	records := filter_experience_records(load_experience_records_from_jsonl(jsonl_path),
		arg)
	if records.len == 0 {
		return '暂无经验记录'
	}
	mut lines := ['📚 经验记录:']
	limit := if records.len > 20 { 20 } else { records.len }
	for i in 0 .. limit {
		record := records[i]
		mut line := '- [${experience_record_display_id(record, i)}] [${record.skill_name}] ${record.title}'
		line += ' | confidence=${record.confidence}'
		if record.outcome.len > 0 {
			line += ' | ${compact_experience_text(record.outcome, 50)}'
		}
		lines << line
	}
	if records.len > limit {
		lines << '... 共 ${records.len} 条，仅显示最近 ${limit} 条'
	}
	return lines.join('\n')
}

fn experience_list_text(arg string) string {
	return experience_list_text_with_paths(arg, get_experience_jsonl_path())
}

fn find_experience_record(records []ExperienceRecord, id_or_ordinal string) ?ExperienceRecord {
	target := id_or_ordinal.trim_space().int()
	if target <= 0 {
		return none
	}
	for i, record in records {
		if record.id == target || (record.id <= 0 && i + 1 == target) {
			return record
		}
	}
	if target <= records.len {
		return records[target - 1]
	}
	return none
}

fn experience_show_text_with_paths(id_or_ordinal string, jsonl_path string) string {
	records := load_experience_records_from_jsonl(jsonl_path)
	record := find_experience_record(records, id_or_ordinal) or {
		return '未找到经验记录: ${id_or_ordinal}'
	}
	mut lines := []string{}
	lines << 'ID: ${if record.id > 0 { record.id.str() } else { id_or_ordinal.trim_space() }}'
	lines << 'Skill: ${record.skill_name}'
	lines << 'Title: ${record.title}'
	lines << 'Confidence: ${record.confidence}'
	lines << 'Source: ${record.source}'
	if record.created_at > 0 {
		lines << 'Created: ${time.unix(record.created_at).format_ss()}'
	}
	if record.scenario.len > 0 {
		lines << 'Scenario: ${record.scenario}'
	}
	if record.action_taken.len > 0 {
		lines << 'Action: ${record.action_taken}'
	}
	if record.outcome.len > 0 {
		lines << 'Outcome: ${record.outcome}'
	}
	if record.tags.len > 0 {
		lines << 'Tags: ${record.tags}'
	}
	return lines.join('\n')
}

fn experience_show_text(id_or_ordinal string) string {
	return experience_show_text_with_paths(id_or_ordinal, get_experience_jsonl_path())
}

fn rewrite_experience_jsonl(records []ExperienceRecord, jsonl_path string) ! {
	os.mkdir_all(os.dir(jsonl_path))!
	mut lines := []string{}
	for record in records {
		lines << build_experience_json_line(record)
	}
	os.write_file(jsonl_path, lines.join('\n') + if lines.len > 0 { '\n' } else { '' })!
}

fn rebuild_experience_markdown(records []ExperienceRecord, markdown_dir string) ! {
	os.rmdir_all(markdown_dir) or {}
	os.mkdir_all(markdown_dir)!
	mut chronological := records.clone()
	chronological.sort(a.created_at < b.created_at)
	for record in chronological {
		append_experience_markdown(record, markdown_dir)!
	}
}

fn prune_experience_records(records []ExperienceRecord, target string) ([]ExperienceRecord, string) {
	trimmed := target.trim_space()
	if trimmed.len == 0 {
		return records, '用法: experience prune <id|all|skill <name>>'
	}
	if trimmed == 'all' {
		return []ExperienceRecord{}, 'all'
	}
	if trimmed.starts_with('skill ') {
		skill_name := trimmed['skill '.len..].trim_space()
		if skill_name.len == 0 {
			return records, '用法: experience prune skill <name>'
		}
		mut kept := []ExperienceRecord{}
		mut removed := 0
		for record in records {
			if record.skill_name == skill_name {
				removed++
				continue
			}
			kept << record
		}
		if removed == 0 {
			return records, '未找到 skill `${skill_name}` 的经验记录'
		}
		return kept, 'skill:${skill_name}:${removed}'
	}
	record := find_experience_record(records, trimmed) or {
		return records, '未找到经验记录: ${trimmed}'
	}
	mut kept := []ExperienceRecord{}
	for existing in records {
		if record.id > 0 {
			if existing.id == record.id {
				continue
			}
		} else if existing.created_at == record.created_at && existing.title == record.title {
			continue
		}
		kept << existing
	}
	return kept, 'id:${if record.id > 0 {
		record.id.str()
	} else {
		trimmed
	}}'
}

fn delete_experience_from_sqlite(target string, result_tag string, db_path string) string {
	if !sqlite_cli_available() || !os.is_file(db_path) {
		return ''
	}
	if result_tag == 'all' {
		_ = sqlite_exec(db_path, 'DELETE FROM experiences;') or { return '' }
		return 'SQLite 已清空'
	}
	if result_tag.starts_with('skill:') {
		parts := result_tag.split(':')
		if parts.len >= 2 {
			_ = sqlite_exec(db_path, 'DELETE FROM experiences WHERE skill_name = ${sql_quote(parts[1])};') or {
				return ''
			}
			return 'SQLite 已按 skill 删除'
		}
	}
	if result_tag.starts_with('id:') {
		id_text := result_tag['id:'.len..]
		if id_text.int() > 0 {
			_ = sqlite_exec(db_path, 'DELETE FROM experiences WHERE id = ${id_text.int()};') or {
				return ''
			}
			return 'SQLite 已删除 id=${id_text}'
		}
	}
	return ''
}

fn experience_prune_text_with_paths(target string, db_path string, jsonl_path string, markdown_dir string) string {
	records := load_experience_records_from_jsonl(jsonl_path)
	kept, result_tag := prune_experience_records(records, target)
	if result_tag.starts_with('用法:') || result_tag.starts_with('未找到') {
		return result_tag
	}
	rewrite_experience_jsonl(kept, jsonl_path) or { return 'Error: ${err.msg()}' }
	rebuild_experience_markdown(kept, markdown_dir) or { return 'Error: ${err.msg()}' }
	sqlite_msg := delete_experience_from_sqlite(target, result_tag, db_path)
	mut lines := ['✅ 已清理经验记录']
	lines << 'remaining: ${kept.len}'
	if sqlite_msg.len > 0 {
		lines << sqlite_msg
	}
	return lines.join('\n')
}

fn experience_prune_text(target string) string {
	return experience_prune_text_with_paths(target, get_experience_db_path(), get_experience_jsonl_path(),
		get_experience_markdown_dir())
}

fn compact_experience_text(text string, max_len int) string {
	trimmed := text.trim_space().replace('\n', ' ')
	if trimmed.len <= max_len {
		return trimmed
	}
	return utf8_safe_truncate(trimmed, max_len).trim_space() + '...'
}

fn search_experience_records_jsonl(query string, jsonl_path string) []ExperienceRecord {
	needle := query.trim_space().to_lower()
	if needle.len == 0 {
		return []ExperienceRecord{}
	}
	mut matches := []ExperienceRecord{}
	for record in load_experience_records_from_jsonl(jsonl_path) {
		searchable := '${record.skill_name}\n${record.title}\n${record.scenario}\n${record.action_taken}\n${record.outcome}\n${record.tags}'.to_lower()
		if searchable.contains(needle) {
			matches << record
			if matches.len >= 20 {
				break
			}
		}
	}
	return matches
}

fn experience_search_text_with_paths(query string, db_path string, jsonl_path string) string {
	trimmed := query.trim_space()
	if trimmed.len == 0 {
		return '用法: experience search <query>'
	}
	if sqlite_cli_available() && os.is_file(db_path) {
		escaped_query := trimmed.replace("'", "''")
		statement := "SELECT '[' || id || '] ' || skill_name || ' | ' || title || CASE WHEN outcome != '' THEN ' | ' || outcome ELSE '' END || ' | confidence=' || confidence || ' | ' || datetime(created_at, 'unixepoch', 'localtime') FROM experiences WHERE lower(skill_name) LIKE lower('%${escaped_query}%') OR lower(title) LIKE lower('%${escaped_query}%') OR lower(scenario) LIKE lower('%${escaped_query}%') OR lower(action_taken) LIKE lower('%${escaped_query}%') OR lower(outcome) LIKE lower('%${escaped_query}%') OR lower(tags) LIKE lower('%${escaped_query}%') ORDER BY created_at DESC LIMIT 20;"
		if output := sqlite_exec(db_path, statement) {
			if output.trim_space().len > 0 {
				return '🔎 经验搜索结果 (SQLite):\n' + output.trim_space()
			}
		}
	}
	matches := search_experience_records_jsonl(trimmed, jsonl_path)
	if matches.len == 0 {
		return '未找到与 `${trimmed}` 相关的经验记录'
	}
	mut lines := ['🔎 经验搜索结果 (JSONL):']
	for record in matches {
		mut line := '- [${record.skill_name}] ${record.title}'
		if record.outcome.len > 0 {
			line += ' | ${compact_experience_text(record.outcome, 60)}'
		}
		line += ' | confidence=${record.confidence}'
		lines << line
	}
	return lines.join('\n')
}

fn experience_search_text(query string) string {
	return experience_search_text_with_paths(query, get_experience_db_path(), get_experience_jsonl_path())
}

fn records_for_skill(skill_name string, jsonl_path string) []ExperienceRecord {
	mut records := []ExperienceRecord{}
	for record in load_experience_records_from_jsonl(jsonl_path) {
		if record.skill_name == skill_name {
			records << record
			if records.len >= max_skill_sync_records {
				break
			}
		}
	}
	return records
}

fn looks_like_failure(record ExperienceRecord) bool {
	text := '${record.title}\n${record.scenario}\n${record.action_taken}\n${record.outcome}'.to_lower()
	markers := ['失败', '错误', '报错', '阻止', 'not allowed', 'denied', 'timeout', '无效',
		'回退', 'fallback', '手动上传', '手动处理']
	for marker in markers {
		if text.contains(marker) {
			return true
		}
	}
	return false
}

fn looks_like_success(record ExperienceRecord) bool {
	if looks_like_failure(record) {
		return false
	}
	text := '${record.title}\n${record.outcome}'.to_lower()
	markers := ['成功', '可用', '稳定', '通过', '生效', 'saved', 'works', 'working',
		'success']
	for marker in markers {
		if text.contains(marker) {
			return true
		}
	}
	return record.confidence >= 4
}

fn append_unique_compact(mut lines []string, value string, max_len int) {
	compact := compact_experience_text(value, max_len)
	if compact.len == 0 {
		return
	}
	if compact !in lines {
		lines << compact
	}
}

fn top_unique_items(records []ExperienceRecord, kind string, limit int) []string {
	mut items := []string{}
	for record in records {
		match kind {
			'scenario' {
				append_unique_compact(mut items, record.scenario, 80)
			}
			'action' {
				append_unique_compact(mut items, record.action_taken, 90)
			}
			'outcome' {
				append_unique_compact(mut items, record.outcome, 80)
			}
			'tags' {
				for tag in record.tags.split(',') {
					append_unique_compact(mut items, tag.trim_space(), 30)
				}
			}
			else {}
		}
		if items.len >= limit {
			break
		}
	}
	return items
}

fn build_preferred_rule(record ExperienceRecord) string {
	mut rule := '- Prefer '
	if record.action_taken.len > 0 {
		rule += compact_experience_text(record.action_taken, 90)
	} else {
		rule += compact_experience_text(record.title, 70)
	}
	if record.scenario.len > 0 {
		rule += ' when ' + compact_experience_text(record.scenario, 70)
	}
	if record.outcome.len > 0 {
		rule += '. Expected result: ' + compact_experience_text(record.outcome, 70)
	}
	rule += '. Evidence: ${record.title} (${record.confidence}/5)'
	return rule
}

fn build_fallback_rule(record ExperienceRecord) string {
	mut rule := '- Avoid or fallback when '
	if record.scenario.len > 0 {
		rule += compact_experience_text(record.scenario, 70)
	} else {
		rule += compact_experience_text(record.title, 60)
	}
	if record.action_taken.len > 0 {
		rule += '; use ' + compact_experience_text(record.action_taken, 90)
	}
	if record.outcome.len > 0 {
		rule += '. Reason: ' + compact_experience_text(record.outcome, 70)
	}
	rule += '. Evidence: ${record.title} (${record.confidence}/5)'
	return rule
}

fn should_include_in_sync_mode(record ExperienceRecord, mode string) bool {
	return match normalize_experience_sync_mode(mode) {
		experience_sync_mode_strict { record.confidence >= 5 }
		else { true }
	}
}

fn build_skill_generated_block(skill_name string, records []ExperienceRecord, mode string) string {
	resolved_mode := normalize_experience_sync_mode(mode)
	mut preferred := []ExperienceRecord{}
	mut fallbacks := []ExperienceRecord{}
	for record in records {
		if !should_include_in_sync_mode(record, resolved_mode) {
			continue
		}
		if looks_like_failure(record) {
			fallbacks << record
		} else if looks_like_success(record) {
			preferred << record
		}
	}
	mut lines := []string{}
	lines << experience_skill_auto_begin
	lines << '## Auto-Generated Operating Rules'
	lines << 'Mode: ${resolved_mode}'
	lines << 'Use the rules below as distilled guidance from the local experience knowledge base. Prefer evidence-backed stable paths first, and use fallbacks only when the primary path is blocked.'
	lines << ''
	lines << '### Preferred Patterns'
	if preferred.len == 0 {
		lines << '- No high-confidence preferred pattern extracted yet. Review recent evidence before acting.'
	} else {
		rule_limit := match resolved_mode {
			experience_sync_mode_concise { 3 }
			experience_sync_mode_strict { 4 }
			else { max_skill_sync_rules }
		}
		for idx, record in preferred {
			if idx >= rule_limit {
				break
			}
			lines << build_preferred_rule(record)
		}
	}
	lines << ''
	lines << '### Fallbacks And Avoidance'
	if fallbacks.len == 0 {
		lines << '- No explicit fallback rule extracted yet. If a path fails, preserve user-visible state and switch to a lower-risk manual or DOM-based path.'
	} else {
		rule_limit := match resolved_mode {
			experience_sync_mode_concise { 2 }
			experience_sync_mode_strict { 4 }
			else { max_skill_sync_rules }
		}
		for idx, record in fallbacks {
			if idx >= rule_limit {
				break
			}
			lines << build_fallback_rule(record)
		}
	}
	if resolved_mode != experience_sync_mode_concise {
		lines << ''
		lines << '### Scenario Signals'
		scenarios := top_unique_items(records, 'scenario', if resolved_mode == experience_sync_mode_strict {
			3
		} else {
			4
		})
		if scenarios.len == 0 {
			lines << '- No recurring scenario signals extracted yet.'
		} else {
			for scenario in scenarios {
				lines << '- ${scenario}'
			}
		}
		lines << ''
		lines << '### Useful Tags'
		tags := top_unique_items(records, 'tags', if resolved_mode == experience_sync_mode_strict {
			6
		} else {
			8
		})
		if tags.len == 0 {
			lines << '- No tags extracted yet.'
		} else {
			for tag in tags {
				lines << '- ${tag}'
			}
		}
	}
	if resolved_mode != experience_sync_mode_strict {
		lines << ''
		lines << '### Recent Evidence'
		evidence_limit := if resolved_mode == experience_sync_mode_concise { 3 } else { records.len }
		mut shown := 0
		for record in records {
			if !should_include_in_sync_mode(record, resolved_mode) {
				continue
			}
			mut line := '- ${record.title}'
			if record.outcome.len > 0 {
				line += '；结果：${compact_experience_text(record.outcome, 70)}'
			}
			line += '；置信度：${record.confidence}/5'
			lines << line
			shown++
			if shown >= evidence_limit {
				break
			}
		}
	}
	lines << experience_skill_auto_end
	return lines.join('\n')
}

fn build_primary_sop_steps(records []ExperienceRecord, mode string) []string {
	resolved_mode := normalize_experience_sync_mode(mode)
	step_limit := match resolved_mode {
		experience_sync_mode_concise { 3 }
		experience_sync_mode_strict { 4 }
		else { 5 }
	}
	mut steps := []string{}
	for record in records {
		if !should_include_in_sync_mode(record, resolved_mode) || !looks_like_success(record) {
			continue
		}
		mut step := compact_experience_text(if record.action_taken.len > 0 {
			record.action_taken
		} else {
			record.title
		}, 100)
		if record.scenario.len > 0 {
			step += '。适用场景：' + compact_experience_text(record.scenario, 70)
		}
		if record.outcome.len > 0 {
			step += '。预期结果：' + compact_experience_text(record.outcome, 70)
		}
		if step !in steps {
			steps << step
		}
		if steps.len >= step_limit {
			break
		}
	}
	return steps
}

fn build_fallback_sop_items(records []ExperienceRecord, mode string) []string {
	resolved_mode := normalize_experience_sync_mode(mode)
	item_limit := match resolved_mode {
		experience_sync_mode_concise { 2 }
		experience_sync_mode_strict { 4 }
		else { 4 }
	}
	mut items := []string{}
	for record in records {
		if !should_include_in_sync_mode(record, resolved_mode) || !looks_like_failure(record) {
			continue
		}
		mut item := compact_experience_text(if record.scenario.len > 0 {
			record.scenario
		} else {
			record.title
		}, 80)
		if record.action_taken.len > 0 {
			item += '；回退：' + compact_experience_text(record.action_taken, 80)
		}
		if record.outcome.len > 0 {
			item += '；原因：' + compact_experience_text(record.outcome, 70)
		}
		if item !in items {
			items << item
		}
		if items.len >= item_limit {
			break
		}
	}
	return items
}

fn build_sop_generated_block(skill_name string, records []ExperienceRecord, mode string) string {
	resolved_mode := normalize_experience_sync_mode(mode)
	primary_steps := build_primary_sop_steps(records, resolved_mode)
	fallback_items := build_fallback_sop_items(records, resolved_mode)
	scenarios := top_unique_items(records, 'scenario', if resolved_mode == experience_sync_mode_strict {
		3
	} else {
		4
	})
	mut lines := []string{}
	lines << experience_sop_auto_begin
	lines << '# Auto-Generated SOP'
	lines << 'Target: ${skill_name}'
	lines << 'Mode: ${resolved_mode}'
	lines << 'This SOP is synthesized from the local experience knowledge base and should be refreshed whenever new evidence is added.'
	lines << ''
	lines << '## Preconditions'
	if scenarios.len == 0 {
		lines << '- 确认目标环境已就绪，并先观察可见状态再执行关键操作。'
	} else {
		for scenario in scenarios {
			lines << '- ${scenario}'
		}
	}
	lines << ''
	lines << '## Primary Workflow'
	if primary_steps.len == 0 {
		lines << '1. 先确认当前目标流程的可见状态和输入条件。'
		lines << '2. 选择风险最低、证据最多的执行路径。'
		lines << '3. 每完成一步就验证结果，避免在未知状态下连续重试。'
	} else {
		for idx, step in primary_steps {
			lines << '${idx + 1}. ${step}'
		}
	}
	lines << ''
	lines << '## Fallback Workflow'
	if fallback_items.len == 0 {
		lines << '- 若主路径失败，优先保留用户可见状态，再切换到更保守的人工或 DOM 级路径。'
	} else {
		for item in fallback_items {
			lines << '- ${item}'
		}
	}
	lines << ''
	lines << '## Guardrails'
	lines << '- 不要在失败路径上无限重试；连续失败后应立即切换回退方案。'
	lines << '- 任何回退动作都应优先保证正文、表单或当前页面状态不被破坏。'
	lines << '- 执行高风险步骤前，先确认前置条件、权限和可见反馈。'
	if resolved_mode != experience_sync_mode_strict {
		lines << ''
		lines << '## Recent Evidence'
		evidence_limit := if resolved_mode == experience_sync_mode_concise { 3 } else { records.len }
		mut shown := 0
		for record in records {
			if !should_include_in_sync_mode(record, resolved_mode) {
				continue
			}
			mut line := '- ${record.title}'
			if record.outcome.len > 0 {
				line += '；结果：${compact_experience_text(record.outcome, 70)}'
			}
			line += '；置信度：${record.confidence}/5'
			lines << line
			shown++
			if shown >= evidence_limit {
				break
			}
		}
	}
	lines << experience_sop_auto_end
	return lines.join('\n')
}

fn upsert_generated_block(content string, start_marker string, end_marker string, generated_block string) string {
	if start := content.index(start_marker) {
		if end := content.index(end_marker) {
			end_idx := end + end_marker.len
			suffix := content[end_idx..].trim_left('\n ')
			mut merged := content[..start].trim_right('\n ') + '\n\n' + generated_block
			if suffix.len > 0 {
				merged += '\n\n' + suffix
			} else {
				merged += '\n'
			}
			return merged
		}
	}
	if content.trim_space().len == 0 {
		return generated_block + '\n'
	}
	return content.trim_right('\n ') + '\n\n' + generated_block + '\n'
}

fn upsert_generated_skill_block(content string, generated_block string) string {
	return upsert_generated_block(content, experience_skill_auto_begin, experience_skill_auto_end,
		generated_block)
}

fn default_skill_content(skill_name string, generated_block string) string {
	return
		'---\nname: ${skill_name}\ndescription: Auto-generated skill derived from local experience knowledge base\n---\n\n' +
		'You are a specialized expert for ${skill_name}.\n\n' +
		'Use the accumulated local experience below as operational guidance. Favor stable, repeatable methods and update this skill when new evidence appears.\n\n' +
		generated_block + '\n'
}

fn default_sop_content(skill_name string, generated_block string) string {
	return '# SOP: ${skill_name}\n\n' +
		'以下步骤由本地经验库自动总结生成。可以在自动区块外补充手写说明，后续同步只会更新自动区块。\n\n' +
		generated_block + '\n'
}

fn sync_skill_from_knowledge_with_paths(skill_name string, mode string, skill_root string, jsonl_path string) string {
	resolved_mode := normalize_experience_sync_mode(mode)
	trimmed := skill_name.trim_space()
	if trimmed.len == 0 {
		return '用法: skills sync <skill-name|all> [concise|balanced|strict]'
	}
	if trimmed == 'all' {
		mut skill_names := []string{}
		for record in load_experience_records_from_jsonl(jsonl_path) {
			if record.skill_name !in skill_names {
				skill_names << record.skill_name
			}
		}
		if skill_names.len == 0 {
			return '没有可同步的经验记录'
		}
		mut results := []string{}
		for name in skill_names {
			results << sync_skill_from_knowledge_with_paths(name, resolved_mode, skill_root,
				jsonl_path)
		}
		return results.join('\n\n')
	}
	records := records_for_skill(trimmed, jsonl_path)
	if records.len == 0 {
		return '未找到 skill `${trimmed}` 的经验记录'
	}
	os.mkdir_all(skill_root) or { return 'Error: ${err.msg()}' }
	skill_dir := os.join_path(skill_root, trimmed)
	os.mkdir_all(skill_dir) or { return 'Error: ${err.msg()}' }
	skill_path := os.join_path(skill_dir, 'SKILL.md')
	generated_block := build_skill_generated_block(trimmed, records, resolved_mode)
	mut next_content := ''
	if os.is_file(skill_path) {
		content := os.read_file(skill_path) or { return 'Error: ${err.msg()}' }
		next_content = upsert_generated_skill_block(content, generated_block)
	} else {
		next_content = default_skill_content(trimmed, generated_block)
	}
	os.write_file(skill_path, next_content) or { return 'Error: ${err.msg()}' }
	return '✅ 已同步 skill: ${trimmed}\nmode: ${resolved_mode}\npath: ${skill_path}\nrecords: ${records.len}'
}

fn sync_skill_from_knowledge(arg string) string {
	target, mode := parse_skill_sync_target_and_mode(arg)
	return sync_skill_from_knowledge_with_paths(target, mode, get_global_skills_dir(),
		get_experience_jsonl_path())
}

fn sync_sop_from_knowledge_with_paths(skill_name string, mode string, sop_root string, jsonl_path string) string {
	resolved_mode := normalize_experience_sync_mode(mode)
	trimmed := skill_name.trim_space()
	if trimmed.len == 0 {
		return '用法: sops sync <skill-name|all> [concise|balanced|strict]'
	}
	if trimmed == 'all' {
		mut skill_names := []string{}
		for record in load_experience_records_from_jsonl(jsonl_path) {
			if record.skill_name !in skill_names {
				skill_names << record.skill_name
			}
		}
		if skill_names.len == 0 {
			return '没有可同步的经验记录'
		}
		mut results := []string{}
		for name in skill_names {
			results << sync_sop_from_knowledge_with_paths(name, resolved_mode, sop_root,
				jsonl_path)
		}
		return results.join('\n\n')
	}
	records := records_for_skill(trimmed, jsonl_path)
	if records.len == 0 {
		return '未找到 skill `${trimmed}` 的经验记录'
	}
	os.mkdir_all(sop_root) or { return 'Error: ${err.msg()}' }
	sop_dir := os.join_path(sop_root, trimmed)
	os.mkdir_all(sop_dir) or { return 'Error: ${err.msg()}' }
	sop_path := os.join_path(sop_dir, 'SOP.md')
	generated_block := build_sop_generated_block(trimmed, records, resolved_mode)
	mut next_content := ''
	if os.is_file(sop_path) {
		content := os.read_file(sop_path) or { return 'Error: ${err.msg()}' }
		next_content = upsert_generated_block(content, experience_sop_auto_begin, experience_sop_auto_end,
			generated_block)
	} else {
		next_content = default_sop_content(trimmed, generated_block)
	}
	os.write_file(sop_path, next_content) or { return 'Error: ${err.msg()}' }
	return '✅ 已升级 SOP: ${trimmed}\nmode: ${resolved_mode}\npath: ${sop_path}\nrecords: ${records.len}'
}

fn sync_sop_from_knowledge(arg string) string {
	target, mode := parse_skill_sync_target_and_mode(arg)
	return sync_sop_from_knowledge_with_paths(target, mode, get_global_sops_dir(), get_experience_jsonl_path())
}

fn list_sops_text_with_root(sop_root string) string {
	if !os.is_dir(sop_root) {
		return '暂无全局 SOP'
	}
	entries := os.ls(sop_root) or { return 'Error: ${err.msg()}' }
	mut names := []string{}
	for entry in entries {
		if os.is_file(sop_file_path(entry, sop_root)) {
			names << entry
		}
	}
	if names.len == 0 {
		return '暂无全局 SOP'
	}
	names.sort()
	mut lines := ['📘 全局 SOP:']
	for name in names {
		lines << '- ${name} | ${sop_file_path(name, sop_root)}'
	}
	return lines.join('\n')
}

fn list_sops_text() string {
	return list_sops_text_with_root(get_global_sops_dir())
}

fn show_sop_text_with_root(skill_name string, sop_root string) string {
	trimmed := skill_name.trim_space()
	if trimmed.len == 0 {
		return '用法: sops show <skill-name>'
	}
	path := sop_file_path(trimmed, sop_root)
	if !os.is_file(path) {
		return '未找到 SOP: ${trimmed}'
	}
	content := os.read_file(path) or { return 'Error: ${err.msg()}' }
	if content.trim_space().len == 0 {
		return 'SOP 为空: ${trimmed}'
	}
	return content
}

fn show_sop_text(skill_name string) string {
	return show_sop_text_with_root(skill_name, get_global_sops_dir())
}

fn sops_help_text() string {
	return 'SOP 命令:\n' + '  sops list\n' + '  sops show <skill-name>\n' +
		'  sops sync <skill-name|all> [concise|balanced|strict]\n\n' +
		'全局 SOP 默认存储在 ~/.config/minimax/sops/<skill>/SOP.md'
}

fn experience_help_text() string {
	return '经验库命令:\n' +
		'  experience add {"skill":"name","title":"...","scenario":"...","action":"...","outcome":"...","tags":"a,b","confidence":4}\n' +
		'  experience add skill=name; title=...; scenario=...; action=...; outcome=...; tags=a,b; confidence=4\n' +
		'  experience add name | title | scenario | action | outcome | tags | confidence\n' +
		'  experience list [skill-name]\n' + '  experience show <id>\n' +
		'  experience search <query>\n' + '  experience prune <id|all|skill <name>>\n' +
		'  sops list\n' + '  sops show <skill-name>\n' +
		'  skills sync <skill-name|all> [concise|balanced|strict]\n' +
		'  sops sync <skill-name|all> [concise|balanced|strict]\n\n' +
		'默认会在 experience add 后自动写入全局 skill 并升级全局 SOP；可通过 config 中 auto_write_skills、auto_upgrade_sops、knowledge_sync_mode 调整。'
}
