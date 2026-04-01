module main

import os

const sync_mode_balanced = 'balanced'
const sync_mode_concise = 'concise'
const sync_mode_strict = 'strict'

// ExperienceRecord represents a single experience entry.
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

// ExperienceService manages SOP and experience records.
pub struct ExperienceService {
mut:
	skill_root string
	sop_root   string
	sync_mode  string
}

pub fn new_experience_service(skill_root string, sop_root string, sync_mode string) ExperienceService {
	return ExperienceService{
		skill_root: skill_root
		sop_root:   sop_root
		sync_mode:  normalize_sync_mode(sync_mode)
	}
}

fn normalize_sync_mode(mode string) string {
	trimmed := mode.trim_space().to_lower()
	return match trimmed {
		sync_mode_concise { sync_mode_concise }
		sync_mode_strict { sync_mode_strict }
		else { sync_mode_balanced }
	}
}

// match_sop finds the best matching SOP for a given task.
pub fn (svc &ExperienceService) match_sop(task string, limit int) []string {
	// Simple SOP matching - returns empty for now
	// Full implementation would search SOP files and score by relevance
	return []string{}
}

// sync_skill_from_knowledge generates skill rules from experience records.
pub fn (svc &ExperienceService) sync_skill_from_knowledge(skill_name string, mode string) string {
	if svc.skill_root.len == 0 {
		return 'Skill root not configured'
	}
	skill_dir := os.join_path(svc.skill_root, skill_name)
	skill_file := os.join_path(skill_dir, 'SKILL.md')
	os.mkdir_all(skill_dir) or { return 'Error: ${err.msg()}' }
	// Build auto-generated block
	auto_block := svc.build_skill_auto_block(skill_name, mode)
	os.write_file(skill_file, auto_block) or { return 'Error: ${err.msg()}' }
	return 'Skill synchronized: ${skill_file}'
}

fn (svc &ExperienceService) build_skill_auto_block(skill_name string, mode string) string {
	mut rules := []string{}
	rules << '<!-- BEGIN AUTO-GENERATED EXPERIENCE -->'
	rules << '<!-- END AUTO-GENERATED EXPERIENCE -->'
	return rules.join('\n')
}

// append_experience adds a new experience record.
pub fn (svc &ExperienceService) append_experience(record ExperienceRecord) string {
	jsonl_path := os.join_path(svc.sop_root, '..', 'knowledge', 'experiences.jsonl')
	os.mkdir_all(os.dir(jsonl_path)) or { return 'Error: ${err.msg()}' }
	line := '{"skill":"${record.skill_name}","title":"${record.title}","confidence":${record.confidence}}'
	mut content := ''
	if os.is_file(jsonl_path) {
		content = os.read_file(jsonl_path) or { '' }
	}
	if content.len > 0 && !content.ends_with('\n') {
		content += '\n'
	}
	content += line + '\n'
	os.write_file(jsonl_path, content) or { return 'Error: ${err.msg()}' }
	return 'Experience appended'
}
