module main

import os
import time

fn experience_test_dir(prefix string) string {
	return os.join_path(os.temp_dir(), '${prefix}_${time.now().unix_milli()}')
}

fn test_parse_experience_json_valid() {
	payload := '{"skill":"wechat-editor-image","title":"剪贴板插图成功","scenario":"微信公众号编辑器可读写","action":"读取剪贴板图片并注入ProseMirror","outcome":"成功插入图片","tags":"wechat,image,clipboard","confidence":5}'
	record := parse_experience_json(payload) or {
		assert false, 'should parse valid experience json'
		return
	}
	assert record.skill_name == 'wechat-editor-image'
	assert record.title == '剪贴板插图成功'
	assert record.confidence == 5
	assert record.action_taken.contains('ProseMirror')
}

fn test_parse_experience_kv_payload_valid() {
	payload := 'skill=wechat-editor-image; title=剪贴板插图成功; scenario=编辑器可读写; action=读取剪贴板图片并注入ProseMirror; outcome=成功插入图片; tags=wechat,image,clipboard; confidence=5'
	record := parse_experience_payload(payload) or {
		assert false, 'should parse kv experience payload'
		return
	}
	assert record.skill_name == 'wechat-editor-image'
	assert record.title == '剪贴板插图成功'
	assert record.confidence == 5
}

fn test_parse_experience_pipe_payload_valid() {
	payload := 'wechat-editor-image | 剪贴板插图成功 | 编辑器可读写 | 读取剪贴板图片并注入ProseMirror | 成功插入图片 | wechat,image,clipboard | 5'
	record := parse_experience_payload(payload) or {
		assert false, 'should parse pipe experience payload'
		return
	}
	assert record.skill_name == 'wechat-editor-image'
	assert record.outcome == '成功插入图片'
	assert record.tags == 'wechat,image,clipboard'
}

fn test_record_experience_payload_with_paths_writes_sidecars() {
	base := experience_test_dir('__minimax_experience_store__')
	os.mkdir_all(base) or {}
	defer { os.rmdir_all(base) or {} }

	db_path := os.join_path(base, 'skills.db')
	jsonl_path := os.join_path(base, 'experiences.jsonl')
	markdown_dir := os.join_path(base, 'skills')
	payload := '{"skill":"wechat-editor-image","title":"剪贴板插图成功","scenario":"微信公众号编辑器可读写","action":"读取剪贴板图片并注入ProseMirror","outcome":"成功插入图片","tags":"wechat,image,clipboard","confidence":5}'

	result := record_experience_payload_with_paths(payload, db_path, jsonl_path, markdown_dir)
	assert result.contains('已记录经验')
	assert os.is_file(jsonl_path)
	assert os.is_file(experience_markdown_path('wechat-editor-image', markdown_dir))

	jsonl_content := os.read_file(jsonl_path) or { '' }
	assert jsonl_content.contains('剪贴板插图成功')
	assert jsonl_content.contains('wechat-editor-image')

	markdown_content := os.read_file(experience_markdown_path('wechat-editor-image', markdown_dir)) or {
		''
	}
	assert markdown_content.contains('# Experience Notes: wechat-editor-image')
	assert markdown_content.contains('Scenario: 微信公众号编辑器可读写')

	if sqlite_cli_available() {
		count := sqlite_exec(db_path, 'SELECT COUNT(*) FROM experiences;') or {
			assert false, 'sqlite should be readable when sqlite3 exists'
			return
		}
		assert count.trim_space() == '1'
		records := load_experience_records_from_jsonl(jsonl_path)
		assert records.len == 1
		assert records[0].id > 0
	}
}

fn test_record_experience_payload_with_paths_accepts_kv_and_pipe_formats() {
	base := experience_test_dir('__minimax_experience_shortcuts__')
	os.mkdir_all(base) or {}
	defer { os.rmdir_all(base) or {} }

	db_path := os.join_path(base, 'skills.db')
	jsonl_path := os.join_path(base, 'experiences.jsonl')
	markdown_dir := os.join_path(base, 'skills')
	_ = record_experience_payload_with_paths('skill=wechat-editor-image; title=KV 写法; scenario=编辑器可读写; action=直接设置 innerHTML; outcome=正文成功; tags=wechat,kv; confidence=4',
		db_path, jsonl_path, markdown_dir)
	_ = record_experience_payload_with_paths('wechat-editor-image | Pipe 写法 | 编辑器可读写 | 直接设置 innerHTML | 正文成功 | wechat,pipe | 5',
		db_path, jsonl_path, markdown_dir)

	records := load_experience_records_from_jsonl(jsonl_path)
	assert records.len == 2
	titles := records.map(it.title)
	assert 'KV 写法' in titles
	assert 'Pipe 写法' in titles
}

fn test_experience_add_wizard_with_scripted_inputs_retries_required_fields() {
	base := experience_test_dir('__minimax_experience_wizard__')
	os.mkdir_all(base) or {}
	defer { os.rmdir_all(base) or {} }

	db_path := os.join_path(base, 'skills.db')
	jsonl_path := os.join_path(base, 'experiences.jsonl')
	markdown_dir := os.join_path(base, 'skills')
	result := experience_add_wizard_with_scripted_inputs([
		'',
		'wechat-editor-image',
		'',
		'向导写入成功',
		'编辑器已加载',
		'直接设置 innerHTML',
		'正文成功写入',
		'wechat,wizard',
		'',
	], db_path, jsonl_path, markdown_dir)

	assert result.contains('已记录经验')
	assert result.contains('title: 向导写入成功')
	assert result.contains('confidence: 3')

	records := load_experience_records_from_jsonl(jsonl_path)
	assert records.len == 1
	assert records[0].skill_name == 'wechat-editor-image'
	assert records[0].title == '向导写入成功'
	assert records[0].source == 'wizard'
	assert records[0].confidence == 3
}

fn test_experience_add_wizard_with_scripted_inputs_cancel_when_inputs_exhausted() {
	base := experience_test_dir('__minimax_experience_wizard_cancel__')
	os.mkdir_all(base) or {}
	defer { os.rmdir_all(base) or {} }

	db_path := os.join_path(base, 'skills.db')
	jsonl_path := os.join_path(base, 'experiences.jsonl')
	markdown_dir := os.join_path(base, 'skills')
	result := experience_add_wizard_with_scripted_inputs([
		'wechat-editor-image',
	], db_path, jsonl_path, markdown_dir)

	assert result == '已取消'
	assert !os.is_file(jsonl_path)
}

fn test_experience_list_and_show_text_with_paths() {
	base := experience_test_dir('__minimax_experience_list_show__')
	os.mkdir_all(base) or {}
	defer { os.rmdir_all(base) or {} }

	db_path := os.join_path(base, 'skills.db')
	jsonl_path := os.join_path(base, 'experiences.jsonl')
	markdown_dir := os.join_path(base, 'skills')
	_ = record_experience_payload_with_paths('{"skill":"wechat-editor-image","title":"列表示例","scenario":"编辑器已完成加载","action":"直接设置 innerHTML","outcome":"正文成功写入","tags":"wechat,editor","confidence":4}',
		db_path, jsonl_path, markdown_dir)
	records := load_experience_records_from_jsonl(jsonl_path)
	assert records.len == 1

	list_text := experience_list_text_with_paths('wechat-editor-image', jsonl_path)
	assert list_text.contains('列表示例')
	assert list_text.contains('wechat-editor-image')

	show_target := if records[0].id > 0 { records[0].id.str() } else { '1' }
	show_text := experience_show_text_with_paths(show_target, jsonl_path)
	assert show_text.contains('Title: 列表示例')
	assert show_text.contains('Outcome: 正文成功写入')
}

fn test_experience_search_text_with_paths_finds_recent_record() {
	base := experience_test_dir('__minimax_experience_search__')
	os.mkdir_all(base) or {}
	defer { os.rmdir_all(base) or {} }

	db_path := os.join_path(base, 'skills.db')
	jsonl_path := os.join_path(base, 'experiences.jsonl')
	markdown_dir := os.join_path(base, 'skills')
	payload := '{"skill":"wechat-editor-image","title":"Base64 注入成功","scenario":"文件上传被沙箱阻止","action":"改用 Base64 直接创建 img 节点","outcome":"成功显示图片","tags":"wechat,image,base64","confidence":4}'
	_ = record_experience_payload_with_paths(payload, db_path, jsonl_path, markdown_dir)

	search_result := experience_search_text_with_paths('base64', db_path, jsonl_path)
	assert search_result.contains('Base64 注入成功')
	assert search_result.contains('confidence=4') || search_result.contains('置信度')
}

fn test_sync_skill_from_knowledge_with_paths_creates_skill_file() {
	base := experience_test_dir('__minimax_skill_sync__')
	os.mkdir_all(base) or {}
	defer { os.rmdir_all(base) or {} }

	db_path := os.join_path(base, 'skills.db')
	jsonl_path := os.join_path(base, 'experiences.jsonl')
	markdown_dir := os.join_path(base, 'knowledge')
	skill_root := os.join_path(base, 'skills-root')
	_ = record_experience_payload_with_paths('{"skill":"wechat-editor-image","title":"剪贴板插图成功","scenario":"编辑器已完成加载","action":"读取剪贴板图片并转Data URL","outcome":"成功插入图片","tags":"wechat,clipboard","confidence":5}',
		db_path, jsonl_path, markdown_dir)
	_ = record_experience_payload_with_paths('{"skill":"wechat-editor-image","title":"上传失败后回退","scenario":"setInputFiles 返回 Not allowed","action":"停止重试并提示用户手动上传","outcome":"保留正文内容不回滚","tags":"wechat,upload,fallback","confidence":4}',
		db_path, jsonl_path, markdown_dir)

	result := sync_skill_from_knowledge_with_paths('wechat-editor-image', 'balanced',
		skill_root, jsonl_path)
	assert result.contains('已同步 skill')
	assert result.contains('mode: balanced')

	skill_path := os.join_path(skill_root, 'wechat-editor-image', 'SKILL.md')
	assert os.is_file(skill_path)
	content := os.read_file(skill_path) or { '' }
	assert content.contains('name: wechat-editor-image')
	assert content.contains(experience_skill_auto_begin)
	assert content.contains('## Auto-Generated Operating Rules')
	assert content.contains('### Preferred Patterns')
	assert content.contains('### Fallbacks And Avoidance')
	assert content.contains('剪贴板插图成功')
	assert content.contains('上传失败后回退')
}

fn test_sync_skill_from_knowledge_with_paths_updates_existing_block() {
	base := experience_test_dir('__minimax_skill_sync_update__')
	os.mkdir_all(base) or {}
	defer { os.rmdir_all(base) or {} }

	jsonl_path := os.join_path(base, 'experiences.jsonl')
	skill_root := os.join_path(base, 'skills-root')
	os.mkdir_all(os.join_path(skill_root, 'wechat-editor-image')) or {}
	skill_path := os.join_path(skill_root, 'wechat-editor-image', 'SKILL.md')
	existing := '---\nname: wechat-editor-image\ndescription: Existing skill\n---\n\nManual intro.\n\n${experience_skill_auto_begin}\nold block\n${experience_skill_auto_end}\n'
	os.write_file(skill_path, existing) or {
		assert false
		return
	}
	append_experience_jsonl(ExperienceRecord{
		skill_name:   'wechat-editor-image'
		title:        '新的经验'
		scenario:     '微信编辑器资源加载完成'
		action_taken: '直接设置 innerHTML 并触发 input'
		outcome:      '正文成功保存'
		confidence:   5
		source:       'manual'
		created_at:   time.now().unix()
		updated_at:   time.now().unix()
	}, jsonl_path) or {
		assert false
		return
	}

	result := sync_skill_from_knowledge_with_paths('wechat-editor-image', 'balanced',
		skill_root, jsonl_path)
	assert result.contains('records: 1')

	content := os.read_file(skill_path) or { '' }
	assert content.contains('Manual intro.')
	assert content.contains('新的经验')
	assert content.contains('Preferred Patterns')
	assert !content.contains('old block')
}

fn test_build_skill_generated_block_extracts_preferred_and_fallback_rules() {
	records := [
		ExperienceRecord{
			skill_name:   'wechat-editor-image'
			title:        '剪贴板插图成功'
			scenario:     '编辑器已完成加载'
			action_taken: '读取剪贴板图片并转 Data URL 注入 ProseMirror'
			outcome:      '成功插入图片'
			tags:         'wechat,clipboard,image'
			confidence:   5
		},
		ExperienceRecord{
			skill_name:   'wechat-editor-image'
			title:        '上传失败后回退'
			scenario:     'setInputFiles 返回 Not allowed'
			action_taken: '停止重试并提示用户手动上传'
			outcome:      '保留正文内容不回滚'
			tags:         'wechat,upload,fallback'
			confidence:   4
		},
	]
	block := build_skill_generated_block('wechat-editor-image', records, 'balanced')
	assert block.contains('### Preferred Patterns')
	assert block.contains('Mode: balanced')
	assert block.contains('Prefer 读取剪贴板图片并转 Data URL 注入 ProseMirror')
	assert block.contains('### Fallbacks And Avoidance')
	assert block.contains('Avoid or fallback when setInputFiles 返回 Not allowed')
	assert block.contains('### Scenario Signals')
	assert block.contains('### Useful Tags')
}

fn test_parse_skill_sync_target_and_mode_supports_prefix_and_suffix_mode() {
	target1, mode1 := parse_skill_sync_target_and_mode('wechat-editor-image strict')
	assert target1 == 'wechat-editor-image'
	assert mode1 == 'strict'

	target2, mode2 := parse_skill_sync_target_and_mode('concise wechat-editor-image')
	assert target2 == 'wechat-editor-image'
	assert mode2 == 'concise'

	target3, mode3 := parse_skill_sync_target_and_mode('all')
	assert target3 == 'all'
	assert mode3 == 'balanced'
}

fn test_build_skill_generated_block_modes_adjust_output() {
	records := [
		ExperienceRecord{
			skill_name:   'wechat-editor-image'
			title:        '高置信成功路径'
			scenario:     '编辑器已完成加载'
			action_taken: '读取剪贴板图片并转 Data URL 注入 ProseMirror'
			outcome:      '成功插入图片'
			tags:         'wechat,clipboard,image'
			confidence:   5
		},
		ExperienceRecord{
			skill_name:   'wechat-editor-image'
			title:        '低置信失败路径'
			scenario:     'setInputFiles 返回 Not allowed'
			action_taken: '提示用户手动上传'
			outcome:      '避免继续重试'
			tags:         'wechat,upload,fallback'
			confidence:   4
		},
	]

	concise_block := build_skill_generated_block('wechat-editor-image', records, 'concise')
	assert concise_block.contains('Mode: concise')
	assert !concise_block.contains('### Scenario Signals')
	assert !concise_block.contains('### Useful Tags')
	assert concise_block.contains('### Recent Evidence')

	strict_block := build_skill_generated_block('wechat-editor-image', records, 'strict')
	assert strict_block.contains('Mode: strict')
	assert strict_block.contains('高置信成功路径')
	assert !strict_block.contains('低置信失败路径')
	assert strict_block.contains('### Scenario Signals')
	assert strict_block.contains('### Useful Tags')
	assert !strict_block.contains('### Recent Evidence')
}

fn test_build_sop_generated_block_includes_primary_and_fallback_sections() {
	records := [
		ExperienceRecord{
			skill_name:   'wechat-editor-image'
			title:        '高置信成功路径'
			scenario:     '编辑器已完成加载'
			action_taken: '读取剪贴板图片并转 Data URL 注入 ProseMirror'
			outcome:      '成功插入图片'
			tags:         'wechat,clipboard,image'
			confidence:   5
		},
		ExperienceRecord{
			skill_name:   'wechat-editor-image'
			title:        '低置信失败路径'
			scenario:     'setInputFiles 返回 Not allowed'
			action_taken: '提示用户手动上传'
			outcome:      '避免继续重试'
			tags:         'wechat,upload,fallback'
			confidence:   4
		},
	]

	block := build_sop_generated_block('wechat-editor-image', records, 'balanced')
	assert block.contains('# Auto-Generated SOP')
	assert block.contains('## Preconditions')
	assert block.contains('## Primary Workflow')
	assert block.contains('1. 读取剪贴板图片并转 Data URL 注入 ProseMirror')
	assert block.contains('## Fallback Workflow')
	assert block.contains('提示用户手动上传')
	assert block.contains('## Guardrails')
	assert block.contains('## Recent Evidence')
}

fn test_sync_skill_from_knowledge_with_paths_all_mode_creates_multiple_skill_files() {
	base := experience_test_dir('__minimax_skill_sync_all_mode__')
	os.mkdir_all(base) or {}
	defer { os.rmdir_all(base) or {} }

	db_path := os.join_path(base, 'skills.db')
	jsonl_path := os.join_path(base, 'experiences.jsonl')
	markdown_dir := os.join_path(base, 'knowledge')
	skill_root := os.join_path(base, 'skills-root')

	_ = record_experience_payload_with_paths('{"skill":"wechat-editor-image","title":"微信高置信成功","scenario":"编辑器已完成加载","action":"读取剪贴板图片并转Data URL","outcome":"成功插入图片","tags":"wechat,clipboard","confidence":5}',
		db_path, jsonl_path, markdown_dir)
	_ = record_experience_payload_with_paths('{"skill":"wechat-editor-image","title":"微信低置信失败","scenario":"setInputFiles 返回 Not allowed","action":"提示用户手动上传","outcome":"避免继续重试","tags":"wechat,upload","confidence":4}',
		db_path, jsonl_path, markdown_dir)
	_ = record_experience_payload_with_paths('{"skill":"browser-ops","title":"浏览器高置信成功","scenario":"页面已稳定加载","action":"等待目标节点后点击","outcome":"操作成功执行","tags":"browser,click","confidence":5}',
		db_path, jsonl_path, markdown_dir)
	_ = record_experience_payload_with_paths('{"skill":"browser-ops","title":"浏览器低置信失败","scenario":"元素持续不可见","action":"降级为人工确认","outcome":"保留当前页面状态","tags":"browser,fallback","confidence":4}',
		db_path, jsonl_path, markdown_dir)

	concise_result := sync_skill_from_knowledge_with_paths('all', 'concise', skill_root,
		jsonl_path)
	assert concise_result.contains('已同步 skill: wechat-editor-image')
	assert concise_result.contains('已同步 skill: browser-ops')
	assert concise_result.contains('mode: concise')

	wechat_skill_path := os.join_path(skill_root, 'wechat-editor-image', 'SKILL.md')
	browser_skill_path := os.join_path(skill_root, 'browser-ops', 'SKILL.md')
	assert os.is_file(wechat_skill_path)
	assert os.is_file(browser_skill_path)

	wechat_concise := os.read_file(wechat_skill_path) or { '' }
	browser_concise := os.read_file(browser_skill_path) or { '' }
	assert wechat_concise.contains('Mode: concise')
	assert browser_concise.contains('Mode: concise')
	assert !wechat_concise.contains('### Scenario Signals')
	assert !browser_concise.contains('### Useful Tags')
	assert wechat_concise.contains('### Recent Evidence')

	strict_result := sync_skill_from_knowledge_with_paths('all', 'strict', skill_root,
		jsonl_path)
	assert strict_result.contains('mode: strict')

	wechat_strict := os.read_file(wechat_skill_path) or { '' }
	browser_strict := os.read_file(browser_skill_path) or { '' }
	assert wechat_strict.contains('Mode: strict')
	assert browser_strict.contains('Mode: strict')
	assert wechat_strict.contains('微信高置信成功')
	assert browser_strict.contains('浏览器高置信成功')
	assert !wechat_strict.contains('微信低置信失败')
	assert !browser_strict.contains('浏览器低置信失败')
	assert wechat_strict.contains('### Scenario Signals')
	assert !wechat_strict.contains('### Recent Evidence')
	assert !browser_strict.contains('### Recent Evidence')
}

fn test_sync_skill_from_knowledge_preserves_trailing_content() {
	base := experience_test_dir('__minimax_skill_sync_suffix__')
	os.mkdir_all(base) or {}
	defer { os.rmdir_all(base) or {} }

	jsonl_path := os.join_path(base, 'experiences.jsonl')
	skill_root := os.join_path(base, 'skills-root')
	os.mkdir_all(os.join_path(skill_root, 'wechat-editor-image')) or {}
	skill_path := os.join_path(skill_root, 'wechat-editor-image', 'SKILL.md')
	existing := '---\nname: wechat-editor-image\ndescription: Existing skill\n---\n\nManual intro.\n\n${experience_skill_auto_begin}\nold block\n${experience_skill_auto_end}\n\nTrailing notes.\n'
	os.write_file(skill_path, existing) or {
		assert false
		return
	}
	append_experience_jsonl(ExperienceRecord{
		skill_name:   'wechat-editor-image'
		title:        '保留尾部内容'
		scenario:     '自动生成区块更新'
		action_taken: '替换 marker 间内容'
		outcome:      '尾部补充文案仍然存在'
		confidence:   4
		source:       'manual'
		created_at:   time.now().unix()
		updated_at:   time.now().unix()
	}, jsonl_path) or {
		assert false
		return
	}

	_ = sync_skill_from_knowledge_with_paths('wechat-editor-image', 'balanced', skill_root,
		jsonl_path)
	content := os.read_file(skill_path) or { '' }
	assert content.contains('保留尾部内容')
	assert content.contains('Trailing notes.')
}

fn test_sync_sop_from_knowledge_with_paths_creates_and_updates_sop_file() {
	base := experience_test_dir('__minimax_sop_sync__')
	os.mkdir_all(base) or {}
	defer { os.rmdir_all(base) or {} }

	db_path := os.join_path(base, 'skills.db')
	jsonl_path := os.join_path(base, 'experiences.jsonl')
	markdown_dir := os.join_path(base, 'knowledge')
	sop_root := os.join_path(base, 'sops-root')
	_ = record_experience_payload_with_paths('{"skill":"wechat-editor-image","title":"剪贴板插图成功","scenario":"编辑器已完成加载","action":"读取剪贴板图片并转Data URL","outcome":"成功插入图片","tags":"wechat,clipboard","confidence":5}',
		db_path, jsonl_path, markdown_dir)
	_ = record_experience_payload_with_paths('{"skill":"wechat-editor-image","title":"上传失败后回退","scenario":"setInputFiles 返回 Not allowed","action":"停止重试并提示用户手动上传","outcome":"保留正文内容不回滚","tags":"wechat,upload,fallback","confidence":4}',
		db_path, jsonl_path, markdown_dir)

	result := sync_sop_from_knowledge_with_paths('wechat-editor-image', 'balanced', sop_root,
		jsonl_path)
	assert result.contains('已升级 SOP')
	assert result.contains('mode: balanced')

	sop_path := os.join_path(sop_root, 'wechat-editor-image', 'SOP.md')
	assert os.is_file(sop_path)
	content := os.read_file(sop_path) or { '' }
	assert content.contains('# SOP: wechat-editor-image')
	assert content.contains(experience_sop_auto_begin)
	assert content.contains('## Primary Workflow')
	assert content.contains('## Fallback Workflow')

	existing := '# SOP: wechat-editor-image\n\n手写说明。\n\n${experience_sop_auto_begin}\nold block\n${experience_sop_auto_end}\n\nTrailing notes.\n'
	os.write_file(sop_path, existing) or {
		assert false
		return
	}
	_ = sync_sop_from_knowledge_with_paths('wechat-editor-image', 'strict', sop_root,
		jsonl_path)
	updated := os.read_file(sop_path) or { '' }
	assert updated.contains('手写说明。')
	assert updated.contains('Trailing notes.')
	assert !updated.contains('old block')
	assert updated.contains('Mode: strict')
}

fn test_record_experience_payload_with_paths_and_automation_syncs_skill_and_sop() {
	base := experience_test_dir('__minimax_experience_automation__')
	os.mkdir_all(base) or {}
	defer { os.rmdir_all(base) or {} }

	db_path := os.join_path(base, 'skills.db')
	jsonl_path := os.join_path(base, 'experiences.jsonl')
	markdown_dir := os.join_path(base, 'knowledge')
	skill_root := os.join_path(base, 'skills-root')
	sop_root := os.join_path(base, 'sops-root')
	settings := ExperienceAutomationSettings{
		auto_write_skills: true
		auto_upgrade_sops: true
		sync_mode:         'balanced'
		skill_root:        skill_root
		sop_root:          sop_root
	}

	result := record_experience_payload_with_paths_and_automation('{"skill":"wechat-editor-image","title":"自动同步","scenario":"编辑器已完成加载","action":"读取剪贴板图片并转Data URL","outcome":"成功插入图片","tags":"wechat,clipboard","confidence":5}',
		db_path, jsonl_path, markdown_dir, settings)
	assert result.contains('已记录经验')
	assert result.contains('已同步 skill')
	assert result.contains('已升级 SOP')
	assert os.is_file(os.join_path(skill_root, 'wechat-editor-image', 'SKILL.md'))
	assert os.is_file(os.join_path(sop_root, 'wechat-editor-image', 'SOP.md'))
}

fn test_record_experience_from_tool_input_with_paths_accepts_structured_fields() {
	base := experience_test_dir('__minimax_experience_tool_input__')
	os.mkdir_all(base) or {}
	defer { os.rmdir_all(base) or {} }

	db_path := os.join_path(base, 'skills.db')
	jsonl_path := os.join_path(base, 'experiences.jsonl')
	markdown_dir := os.join_path(base, 'knowledge')
	skill_root := os.join_path(base, 'skills-root')
	sop_root := os.join_path(base, 'sops-root')
	settings := ExperienceAutomationSettings{
		auto_write_skills: true
		auto_upgrade_sops: true
		sync_mode:         'balanced'
		skill_root:        skill_root
		sop_root:          sop_root
	}
	result := record_experience_from_tool_input_with_paths({
		'skill':      'browser-ops'
		'title':      '工具录入'
		'scenario':   '页面已稳定加载'
		'action':     '等待目标节点后点击'
		'outcome':    '操作成功执行'
		'tags':       'browser,tool'
		'confidence': '5'
	}, db_path, jsonl_path, markdown_dir, settings)
	assert result.contains('已记录经验')
	assert result.contains('已同步 skill')
	assert result.contains('已升级 SOP')
	assert os.is_file(os.join_path(skill_root, 'browser-ops', 'SKILL.md'))
	assert os.is_file(os.join_path(sop_root, 'browser-ops', 'SOP.md'))
	content := os.read_file(jsonl_path) or { '' }
	assert content.contains('工具录入')
	assert content.contains('browser-ops')
}

fn test_list_and_show_sops_with_root() {
	base := experience_test_dir('__minimax_sops_show_list__')
	os.mkdir_all(base) or {}
	defer { os.rmdir_all(base) or {} }

	sop_root := os.join_path(base, 'sops-root')
	os.mkdir_all(os.join_path(sop_root, 'wechat-editor-image')) or {}
	path := os.join_path(sop_root, 'wechat-editor-image', 'SOP.md')
	os.write_file(path, '# SOP: wechat-editor-image\n\nhello sop\n') or {
		assert false
		return
	}

	list_text := list_sops_text_with_root(sop_root)
	assert list_text.contains('全局 SOP')
	assert list_text.contains('wechat-editor-image')
	assert list_text.contains(path)

	show_text := show_sop_text_with_root('wechat-editor-image', sop_root)
	assert show_text.contains('# SOP: wechat-editor-image')
	assert show_text.contains('hello sop')

	missing_text := show_sop_text_with_root('missing-skill', sop_root)
	assert missing_text.contains('未找到 SOP')
}

fn test_match_sop_with_root_returns_best_candidate() {
	base := experience_test_dir('__minimax_match_sop__')
	os.mkdir_all(base) or {}
	defer { os.rmdir_all(base) or {} }

	sop_root := os.join_path(base, 'sops-root')
	os.mkdir_all(os.join_path(sop_root, 'wechat-mp-draft-publisher')) or {}
	os.mkdir_all(os.join_path(sop_root, 'browser-ops')) or {}
	os.write_file(os.join_path(sop_root, 'wechat-mp-draft-publisher', 'SOP.md'), '# SOP\n\n微信公众号草稿箱发布流程\n先检查草稿箱状态，再设置封面。') or {
		assert false
		return
	}
	os.write_file(os.join_path(sop_root, 'browser-ops', 'SOP.md'), '# SOP\n\n普通浏览器点击流程') or {
		assert false
		return
	}

	result := match_sop_with_root('请处理微信公众号草稿箱封面', sop_root,
		2)
	assert result.contains('TOP: wechat-mp-draft-publisher')
	assert result.contains('strategy: single_sop_first')
	assert result.contains('suggested_read_order:')
	assert result.contains('score_breakdown:')
	assert result.contains('matched_terms:')
	assert result.contains('score:')
	assert result.contains(os.join_path(sop_root, 'wechat-mp-draft-publisher', 'SOP.md'))
}

fn test_match_sop_with_root_handles_no_match() {
	base := experience_test_dir('__minimax_match_sop_none__')
	os.mkdir_all(base) or {}
	defer { os.rmdir_all(base) or {} }

	sop_root := os.join_path(base, 'sops-root')
	os.mkdir_all(os.join_path(sop_root, 'browser-ops')) or {}
	os.write_file(os.join_path(sop_root, 'browser-ops', 'SOP.md'), '# SOP\n\n普通浏览器点击流程') or {
		assert false
		return
	}

	result := match_sop_with_root('数据库迁移和索引修复', sop_root, 1)
	assert result.contains('No relevant SOP found')
}

fn test_match_sop_with_paths_uses_experience_tags_weight() {
	base := experience_test_dir('__minimax_match_sop_tags__')
	os.mkdir_all(base) or {}
	defer { os.rmdir_all(base) or {} }

	sop_root := os.join_path(base, 'sops-root')
	jsonl_path := os.join_path(base, 'experiences.jsonl')
	markdown_dir := os.join_path(base, 'skills')
	os.mkdir_all(os.join_path(sop_root, 'wechat-mp-draft-publisher')) or {}
	os.mkdir_all(os.join_path(sop_root, 'browser-ops')) or {}
	os.write_file(os.join_path(sop_root, 'wechat-mp-draft-publisher', 'SOP.md'), '# SOP\n\n发布流程\n先检查状态再继续。') or {
		assert false
		return
	}
	os.write_file(os.join_path(sop_root, 'browser-ops', 'SOP.md'), '# SOP\n\n浏览器点击流程') or {
		assert false
		return
	}
	_ = record_experience_payload_with_paths('{"skill":"wechat-mp-draft-publisher","title":"公众号草稿处理","scenario":"公众号草稿箱页面","action":"先检查草稿状态","outcome":"流程稳定","tags":"wechat,mp,draft,publisher","confidence":5}',
		os.join_path(base, 'skills.db'), jsonl_path, markdown_dir)

	result := match_sop_with_paths('请处理微信草稿封面', sop_root, jsonl_path,
		2)
	assert result.contains('TOP: wechat-mp-draft-publisher')
	assert result.contains('score_breakdown:')
	assert result.contains('matched_layers:')
	assert result.contains('experience_tags') || result.contains('experience_text')
}

fn test_match_sop_with_paths_prefers_skill_name_over_body_only_match() {
	base := experience_test_dir('__minimax_match_sop_weighted_layers__')
	os.mkdir_all(base) or {}
	defer { os.rmdir_all(base) or {} }

	sop_root := os.join_path(base, 'sops-root')
	jsonl_path := os.join_path(base, 'experiences.jsonl')
	os.mkdir_all(os.join_path(sop_root, 'wechat-mp-draft-publisher')) or {}
	os.mkdir_all(os.join_path(sop_root, 'generic-publisher')) or {}
	os.write_file(os.join_path(sop_root, 'wechat-mp-draft-publisher', 'SOP.md'), '# SOP\n\n通用发布步骤') or {
		assert false
		return
	}
	os.write_file(os.join_path(sop_root, 'generic-publisher', 'SOP.md'), '# SOP\n\n微信公众号草稿箱封面发布流程') or {
		assert false
		return
	}
	os.write_file(jsonl_path, '') or {
		assert false
		return
	}

	result := match_sop_with_paths('wechat mp publisher workflow', sop_root, jsonl_path,
		2)
	assert result.contains('TOP: wechat-mp-draft-publisher')
	assert result.contains('score_breakdown: exact_query=')
	assert result.contains('matched_layers: skill_name')
}

fn test_match_sop_with_paths_suggests_multi_sop_sequence_for_compound_task() {
	base := experience_test_dir('__minimax_match_sop_compound__')
	os.mkdir_all(base) or {}
	defer { os.rmdir_all(base) or {} }

	sop_root := os.join_path(base, 'sops-root')
	jsonl_path := os.join_path(base, 'experiences.jsonl')
	markdown_dir := os.join_path(base, 'skills')
	os.mkdir_all(os.join_path(sop_root, 'wechat-mp-draft-publisher')) or {}
	os.mkdir_all(os.join_path(sop_root, 'browser-ops')) or {}
	os.write_file(os.join_path(sop_root, 'wechat-mp-draft-publisher', 'SOP.md'), '# SOP\n\n公众号草稿封面处理流程') or {
		assert false
		return
	}
	os.write_file(os.join_path(sop_root, 'browser-ops', 'SOP.md'), '# SOP\n\n浏览器点击校验流程') or {
		assert false
		return
	}
	_ = record_experience_payload_with_paths('{"skill":"wechat-mp-draft-publisher","title":"公众号草稿处理","scenario":"公众号草稿箱页面","action":"先检查草稿状态","outcome":"流程稳定","tags":"wechat,mp,draft,publisher","confidence":5}',
		os.join_path(base, 'skills.db'), jsonl_path, markdown_dir)
	_ = record_experience_payload_with_paths('{"skill":"browser-ops","title":"浏览器点击巡检","scenario":"浏览器页面已打开","action":"检查关键按钮点击反馈","outcome":"巡检流程稳定","tags":"browser,click,qa,check","confidence":5}',
		os.join_path(base, 'skills.db'), jsonl_path, markdown_dir)

	result := match_sop_with_paths('先处理微信公众号草稿封面，然后执行浏览器点击巡检',
		sop_root, jsonl_path, 3)
	assert result.contains('strategy: multi_sop_sequence')
	assert result.contains('suggested_read_order:')
	assert result.contains('1. wechat-mp-draft-publisher')
	assert result.contains('2. browser-ops')
}

fn test_experience_prune_text_with_paths_by_id() {
	base := experience_test_dir('__minimax_experience_prune_id__')
	os.mkdir_all(base) or {}
	defer { os.rmdir_all(base) or {} }

	db_path := os.join_path(base, 'skills.db')
	jsonl_path := os.join_path(base, 'experiences.jsonl')
	markdown_dir := os.join_path(base, 'skills')
	_ = record_experience_payload_with_paths('{"skill":"wechat-editor-image","title":"保留记录","scenario":"场景A","action":"操作A","outcome":"结果A","tags":"keep","confidence":4}',
		db_path, jsonl_path, markdown_dir)
	_ = record_experience_payload_with_paths('{"skill":"wechat-editor-image","title":"删除记录","scenario":"场景B","action":"操作B","outcome":"结果B","tags":"delete","confidence":3}',
		db_path, jsonl_path, markdown_dir)
	records := load_experience_records_from_jsonl(jsonl_path)
	assert records.len == 2

	delete_target := if records[0].title == '删除记录' {
		experience_record_display_id(records[0], 0).str()
	} else {
		experience_record_display_id(records[1], 1).str()
	}
	result := experience_prune_text_with_paths(delete_target, db_path, jsonl_path, markdown_dir)
	assert result.contains('已清理经验记录')

	rest := load_experience_records_from_jsonl(jsonl_path)
	assert rest.len == 1
	assert rest[0].title == '保留记录'
	markdown_content := os.read_file(experience_markdown_path('wechat-editor-image', markdown_dir)) or {
		''
	}
	assert markdown_content.contains('保留记录')
	assert !markdown_content.contains('删除记录')
}

fn test_experience_prune_text_with_paths_by_skill() {
	base := experience_test_dir('__minimax_experience_prune_skill__')
	os.mkdir_all(base) or {}
	defer { os.rmdir_all(base) or {} }

	db_path := os.join_path(base, 'skills.db')
	jsonl_path := os.join_path(base, 'experiences.jsonl')
	markdown_dir := os.join_path(base, 'skills')
	_ = record_experience_payload_with_paths('{"skill":"wechat-editor-image","title":"微信经验","scenario":"A","action":"A","outcome":"A","tags":"wechat","confidence":5}',
		db_path, jsonl_path, markdown_dir)
	_ = record_experience_payload_with_paths('{"skill":"browser-ops","title":"浏览器经验","scenario":"B","action":"B","outcome":"B","tags":"browser","confidence":4}',
		db_path, jsonl_path, markdown_dir)

	result := experience_prune_text_with_paths('skill wechat-editor-image', db_path, jsonl_path,
		markdown_dir)
	assert result.contains('已清理经验记录')

	rest := load_experience_records_from_jsonl(jsonl_path)
	assert rest.len == 1
	assert rest[0].skill_name == 'browser-ops'
	assert !os.is_file(experience_markdown_path('wechat-editor-image', markdown_dir))
	assert os.is_file(experience_markdown_path('browser-ops', markdown_dir))
}
