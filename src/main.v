module main

import os
import flag
import time
import minimax

const version = '0.1.0'

// ToolDef represents a callable tool definition.
pub struct ToolDef {
pub:
	name        string
	description string
	schema      string
}

// ToolService manages available tools from MCP servers and built-in sources.
pub struct ToolService {
mut:
	tools []ToolDef
}

pub fn new_tool_service() ToolService {
	return ToolService{
		tools: []ToolDef{}
	}
}

pub fn (mut ts ToolService) register_tool(name string, description string, schema string) {
	ts.tools << ToolDef{
		name:        name
		description: description
		schema:      schema
	}
}

pub fn (ts &ToolService) get_all_tools() []ToolDef {
	return ts.tools
}

// AppContext holds all application services and configuration.
pub struct AppContext {
mut:
	skills           SkillService
	mcp              McpService
	cron             CronService
	memory           MemoryService
	bash             BashService
	tools            ToolService
	executor         ToolExecutor
	config           Config
	runtime          RuntimeContext
	workspace        string
	minimax_client   &minimax.Client = unsafe { nil }
}

pub fn new_app_context() AppContext {
	return AppContext{
		skills:    new_skill_service()
		mcp:       new_mcp_service()
		cron:      CronService{}
		memory:    new_memory_service()
		bash:      BashService{}
		tools:     new_tool_service()
		executor:  new_tool_executor('', unsafe { nil }, unsafe { nil })
		runtime:   new_runtime_context()
		workspace: ''
	}
}

// CliArgs holds parsed command line arguments.
struct CliArgs {
mut:
	workspace   string
	config_path string
	cli_mode    string
	no_tools    bool
	verbose     bool
	prompt      string
}

fn parse_cli_args() CliArgs {
	mut fp := flag.new_flag_parser(os.args[1..])
	fp.application('minimax-v')
	fp.version('${version}')
	fp.description('Minimax CLI - AI-powered development assistant')

	mut args := CliArgs{}
	args.workspace = fp.string('workspace', `w`, '', 'Working directory')
	args.config_path = fp.string('config', `c`, '', 'Path to config file')
	args.cli_mode = fp.string('mode', `m`, 'cli', 'Start mode: cli or ui')
	args.no_tools = fp.bool('no-tools', 0, false, 'Disable tool execution')
	args.verbose = fp.bool('verbose', `v`, false, 'Enable verbose output')
	args.prompt = fp.string('prompt', `p`, '', 'Execute a single prompt and exit')

	_ = fp.finalize() or {
		eprintln('Error parsing arguments: ${err}')
		exit(1)
	}

	return args
}

// run_cli_mode starts the interactive CLI mode.
fn run_cli_mode(mut ctx AppContext) {
	println('MiniMax CLI v${version}')
	println('Type your message or :quit to exit.')
	println('')

	for {
		print('> ')
		input := os.get_line().trim_space()
		if input.len == 0 {
			continue
		}
		if input == ':quit' || input == ':exit' {
			println('Goodbye!')
			break
		}
		println('You: ${input}')
		result := ctx.executor.execute_tool('skill', {
			'name': ''
		})
		println('Bot: ${result}')
		println('')
	}
}

// main_loop runs the main event loop with cron tick handling.
fn main_loop(mut ctx AppContext, verbose bool) {
	ctx.cron.start()
	defer {
		ctx.cron.stop()
		ctx.mcp.stop_all()
	}

	for !ctx.runtime.is_shutting_down() {
		ctx.cron.tick(fn [mut ctx, verbose] (job CronJob) ! {
			result := ctx.bash.execute(job.command)
			if verbose {
				println('[Cron] ${job.name}: ${result}')
			}
		}) or {}

		time.sleep(1 * time.second)
	}
}

// start_ui_mode starts the terminal UI mode.
fn start_ui_mode(mut ctx AppContext) {
	start_term_ui(mut ctx)
}

fn main() {
	args := parse_cli_args()

	mut config := load_config()

	if args.workspace.len > 0 {
		config.workspace = args.workspace
	}
	if args.no_tools {
		config.enable_tools = false
	}

	workspace := config.workspace
	if workspace.len > 0 && !os.is_dir(workspace) {
		os.mkdir_all(workspace) or {
			eprintln('Error: Cannot create workspace directory: ${err}')
			exit(1)
		}
	}

	mut ctx := new_app_context()
	ctx.config = config
	ctx.workspace = workspace

	ctx.skills.init(workspace)
	ctx.bash = new_bash_session(workspace)
	ctx.memory = new_memory_service()
	ctx.cron = new_cron_service() or {
		eprintln('Warning: Failed to initialize cron service: ${err}')
		CronService{}
	}

	ctx.mcp = new_mcp_service()

	// Initialize MiniMax client
	api_key := os.getenv('MINIMAX_API_KEY')
	if api_key.len > 0 {
		mut host := os.getenv('MINIMAX_API_HOST')
		if host.len == 0 {
			host = 'https://api.minimaxi.com'
		}
		minimax_client := minimax.new_client(api_key, host)
		ctx.minimax_client = &minimax_client
		ctx.mcp.set_minimax_client(ctx.minimax_client)
		if args.verbose {
			println('[Main] MiniMax client initialized')
		}
	} else {
		if args.verbose {
			println('[Main] Warning: MINIMAX_API_KEY not set, MiniMax tools disabled')
		}
	}

	ctx.mcp.start_eager_servers()
	ctx.executor = new_tool_executor(workspace, &ctx.mcp, &ctx.skills)

	// Handle single prompt mode
	if args.prompt.len > 0 {
		// Directly call minimax client search
		if isnil(ctx.minimax_client) {
			eprintln('Error: minimax_client not initialized')
			exit(1)
		}
		req := minimax.SearchRequest{query: args.prompt}
		if args.verbose {
			println('[Main] Calling minimax search directly...')
		}
		result := ctx.minimax_client.search(req) or {
			eprintln('Search error: ${err}')
			exit(1)
		}
		if args.verbose {
			println('[Main] Result: ${result}')
		}
		println(result)
		exit(0)
	}

	if config.enable_tools {
		ctx.tools.register_tool('bash', 'A persistent bash shell session.', '{"type":"object"}')
		ctx.tools.register_tool('skill', 'Skill management.', '{"type":"object"}')
		mcp_tools := ctx.mcp.get_all_tools()
		for tool in mcp_tools {
			ctx.tools.register_tool(tool.name, tool.description, tool.raw_schema)
		}
	}

	if args.verbose {
		println('[Main] AppContext initialized')
		println('[Main] Workspace: ${workspace}')
		println('[Main] Tools available: ${ctx.tools.get_all_tools().len}')
	}

	if args.cli_mode == 'ui' {
		start_ui_mode(mut ctx)
	} else {
		run_cli_mode(mut ctx)
	}

	main_loop(mut ctx, args.verbose)
}
