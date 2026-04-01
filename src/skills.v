module main

import os

// Skill represents a single skill with its metadata
struct Skill {
	name        string
	description string
	prompt      string
	source      string // 'builtin', 'user', 'project'
	path        string // file path for custom skills (empty for builtin)
}

// SkillService manages all skills with discovery tiers:
// Project (.agents/skills/) > User (~/.config/minimax/skills/) > Built-in
@[heap]
pub struct SkillService {
mut:
	skills       []Skill
	active_skill string
	loaded       bool
}

// new_skill_service creates a new SkillService instance
pub fn new_skill_service() SkillService {
	return SkillService{}
}

// Initialize skill registry: discover all skills from all tiers
pub fn (mut ss SkillService) init(workspace string) {
	if ss.loaded {
		return
	}
	ss.skills = []
	// 1. Built-in skills (lowest priority)
	for s in builtin_skills() {
		ss.skills << s
	}
	// 2. User-level skills (~/.config/minimax/skills/)
	user_dir := os.join_path(minimax_config_dir(), 'skills')
	ss.load_custom_skills_from_dir(user_dir, 'user')
	// Also check ~/.agents/skills/ alias
	user_agents_dir := expand_home('~/.agents/skills')
	ss.load_custom_skills_from_dir(user_agents_dir, 'user')
	// 3. Project-level skills (highest priority)
	if workspace.len > 0 {
		project_dir := os.join_path(workspace, '.agents', 'skills')
		ss.load_custom_skills_from_dir(project_dir, 'project')
	}
	ss.loaded = true
}

// Activate a skill by name
pub fn (ss &SkillService) activate(name string) string {
	for skill in ss.skills {
		if skill.name == name {
			unsafe {
				mut ss2 := ss
				ss2.active_skill = name
			}
			mut info := '✅ Skill activated: "${skill.name}" — ${skill.description}\n'
			info += 'Source: ${skill.source}'
			if skill.path.len > 0 {
				info += ' (${skill.path})'
			}
			info += '\n\n--- Skill Instructions ---\n${skill.prompt}\n--- End Skill ---'
			return info
		}
	}
	mut available := 'Error: Skill "${name}" not found.\nAvailable skills:\n'
	for skill in ss.skills {
		available += '  - ${skill.name}: ${skill.description} [${skill.source}]\n'
	}
	return available
}

// Get all skills
pub fn (ss &SkillService) get_all() []Skill {
	return ss.skills
}

// Build skills metadata string for system prompt injection
pub fn (ss &SkillService) build_metadata() string {
	if ss.skills.len == 0 {
		return ''
	}
	mut parts := []string{}
	parts << 'Available Skills (use activate_skill tool to load specialized expertise):'
	for skill in ss.skills {
		parts << '  - ${skill.name}: ${skill.description}'
	}
	return parts.join('\n')
}

// Load custom SKILL.md files from a directory
fn (mut ss SkillService) load_custom_skills_from_dir(dir string, source string) {
	if !os.is_dir(dir) {
		return
	}
	// Scan for SKILL.md directly in the dir
	skill_file := os.join_path(dir, 'SKILL.md')
	if os.is_file(skill_file) {
		if skill := parse_skill_md(skill_file, source) {
			ss.add_or_override(skill)
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
					ss.add_or_override(skill)
				}
			}
		}
	}
}

// Add skill, overriding same-name skill from lower tier
fn (mut ss SkillService) add_or_override(new_skill Skill) {
	priority := fn (source string) int {
		return match source {
			'project' { 3 }
			'user' { 2 }
			else { 1 }
		}
	}
	for i, existing in ss.skills {
		if existing.name == new_skill.name {
			if priority(new_skill.source) >= priority(existing.source) {
				ss.skills[i] = new_skill
			}
			return
		}
	}
	ss.skills << new_skill
}

// Parse a SKILL.md file with YAML frontmatter
fn parse_skill_md(path string, source string) ?Skill {
	content := os.read_file(path) or { return none }
	trimmed := content.trim_space()
	if !trimmed.starts_with('---') {
		return none
	}
	rest := trimmed[3..]
	end_idx := rest.index('---') or { return none }
	frontmatter := rest[..end_idx].trim_space()
	body := rest[end_idx + 3..].trim_space()

	mut name := ''
	mut description := ''
	for line in frontmatter.split('\n') {
		l := line.trim_space()
		if l.starts_with('name:') {
			name = l[5..].trim_space().trim('"').trim("'")
		} else if l.starts_with('description:') {
			description = l[12..].trim_space().trim('"').trim("'")
		}
	}
	if name.len == 0 {
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
	}
}

// Get minimax config directory
fn minimax_config_dir() string {
	$if windows {
		return os.join_path(os.getenv('APPDATA'), 'minimax')
	} $else {
		return os.join_path(os.home_dir(), '.config', 'minimax')
	}
}

// Expand ~ in path
fn expand_home(path string) string {
	if path.starts_with('~/') {
		return os.join_path(os.home_dir(), path[2..])
	}
	return path
}

// --- Built-in Skills (15 total) ---

fn builtin_skills() []Skill {
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
