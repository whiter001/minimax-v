module main

struct RuntimeState {
mut:
	mcp_manager   &McpManager
	shutting_down bool
	acp_mode      bool
}

__global runtime_state = RuntimeState{
	mcp_manager: unsafe { nil }
}

fn runtime_mark_shutting_down() bool {
	if runtime_state.shutting_down {
		return true
	}
	runtime_state.shutting_down = true
	return false
}

fn runtime_set_mcp_manager(manager &McpManager) {
	unsafe {
		runtime_state.mcp_manager = manager
	}
}

fn runtime_stop_all_mcp() {
	if runtime_state.mcp_manager != unsafe { nil } {
		unsafe {
			runtime_state.mcp_manager.stop_all()
		}
	}
}

fn runtime_set_acp_mode(enabled bool) {
	runtime_state.acp_mode = enabled
}

fn runtime_is_acp_mode() bool {
	return runtime_state.acp_mode
}
