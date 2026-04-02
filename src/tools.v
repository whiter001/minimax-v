module main

pub struct ToolUse {
pub mut:
	id    string
	name  string
	input map[string]string
}

// ToolDefinition represents a tool with its name and description.
pub struct ToolDefinition {
pub mut:
	name        string
	description string
}

// ToolExecutor manages all tools and their execution.
// It holds references to bash, mcp, and skill services.
pub struct ToolExecutor {
mut:
	bash_service  BashService
	mcp_service   &McpService
	skill_service &SkillService
	workspace     string
}

// new_tool_executor creates a new ToolExecutor with the given workspace.
pub fn new_tool_executor(workspace string, mcp &McpService, skill &SkillService) ToolExecutor {
	return ToolExecutor{
		bash_service:  new_bash_session(workspace)
		mcp_service:   mcp
		skill_service: skill
		workspace:     workspace
	}
}

// execute_tool executes a tool by name with the given input map.
// Returns the result string or an error message.
pub fn (mut te ToolExecutor) execute_tool(name string, input map[string]string) string {
	match name {
		'bash' {
			return te.execute_bash_tool(input)
		}
		'mcp' {
			return te.execute_mcp_tool(input)
		}
		'skill' {
			return te.execute_skill_tool(input)
		}
		else {
			return 'Error: unknown tool "${name}"'
		}
	}
}

// execute_bash_tool executes the bash builtin tool.
fn (mut te ToolExecutor) execute_bash_tool(input map[string]string) string {
	cmd := input['command'] or { '' }
	restart_str := input['restart'] or { 'false' }
	if restart_str == 'true' {
		te.bash_service = new_bash_session(te.workspace)
		return 'Bash session restarted. cwd=${te.bash_service.cwd}'
	}
	return te.bash_service.execute(cmd)
}

// execute_mcp_tool executes the mcp builtin tool.
fn (mut te ToolExecutor) execute_mcp_tool(input map[string]string) string {
	// MCP tool: list available tools or call a specific MCP tool
	action := input['action'] or { 'list' }
	if action == 'list' {
		tools := te.mcp_service.get_all_tools()
		if tools.len == 0 {
			return 'No MCP tools available.'
		}
		mut result := 'Available MCP tools:\n'
		for tool in tools {
			result += '  - ${tool.name}: ${tool.description}\n'
		}
		return result
	}
	// Call a specific MCP tool
	tool_name := input['name'] or { '' }
	if tool_name.len == 0 {
		return 'Error: mcp tool requires "name" parameter'
	}
	args_json := input['arguments'] or { '{}' }
	result := te.mcp_service.call_tool(tool_name, args_json) or { return 'Error: ${err.msg()}' }
	return result
}

// execute_skill_tool executes the skill builtin tool.
fn (mut te ToolExecutor) execute_skill_tool(input map[string]string) string {
	name := input['name'] or { '' }
	if name.len == 0 {
		// List all available skills
		return te.skill_service.build_metadata()
	}
	return te.skill_service.activate(name)
}

// parse_bool_input parses a boolean value from input map.
pub fn parse_bool_input(input map[string]string, key string, default_value bool) bool {
	val := (input[key] or { '' }).trim_space().to_lower()
	if val.len == 0 {
		return default_value
	}
	return val in ['true', '1', 'yes', 'on']
}

// parse_int_input parses an integer value from input map.
pub fn parse_int_input(input map[string]string, key string, default_value int) int {
	val := (input[key] or { '' }).trim_space()
	if val.len == 0 {
		return default_value
	}
	return val.int()
}

// get_tools_schema_json returns the JSON schema for all builtin tools.
pub fn get_tools_schema_json() string {
	return '[' +
		'{"name":"bash","description":"A persistent bash shell session. Working directory and environment variables are preserved between calls.","input_schema":{"type":"object","properties":{"command":{"type":"string","description":"The bash command to execute"},"restart":{"type":"boolean","description":"Set to true to restart the bash session (reset cwd and env)"}},"required":["command"]}},' +
		'{"name":"mcp","description":"MCP (Model Context Protocol) tool management. Use to list available MCP tools or call a specific MCP tool.","input_schema":{"type":"object","properties":{"action":{"type":"string","description":"Action: list or call (default: list)"},"name":{"type":"string","description":"Tool name to call (for action=call)"},"arguments":{"type":"string","description":"JSON arguments for the tool call"}},"required":[]}},' +
		'{"name":"skill","description":"Skill management. Use to activate a specialized skill or list available skills.","input_schema":{"type":"object","properties":{"name":{"type":"string","description":"Skill name to activate (e.g. coder, reviewer, architect)"}},"required":[]}}' +
		']'
}

pub fn build_tool_input_json(input map[string]string) string {
	mut parts := []string{}
	mut keys := input.keys()
	keys.sort()
	for key in keys {
		val := input[key] or { '' }
		parts << '"${key}":"${escape_json_string(val)}"'
	}
	return '{' + parts.join(',') + '}'
}

// get_builtin_tool_definitions returns all builtin tool definitions.
pub fn get_builtin_tool_definitions() []ToolDefinition {
	return [
		ToolDefinition{'bash', 'A persistent bash shell session with preserved working directory and environment.'},
		ToolDefinition{'mcp', 'MCP (Model Context Protocol) tool management and execution.'},
		ToolDefinition{'skill', 'Skill activation and management for specialized expertise.'},
	]
}
