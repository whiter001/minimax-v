module main

// RuntimeContext holds runtime state for the application.
// This replaces the previous global runtime_state variable.
pub struct RuntimeContext {
mut:
	shutting_down bool
	acp_mode      bool
}

// new_runtime_context creates a new RuntimeContext instance.
pub fn new_runtime_context() RuntimeContext {
	return RuntimeContext{
		shutting_down: false
		acp_mode:      false
	}
}

// mark_shutting_down signals that the application is shutting down.
pub fn (mut ctx RuntimeContext) mark_shutting_down() {
	ctx.shutting_down = true
}

// set_acp_mode sets the ACP mode state.
pub fn (mut ctx RuntimeContext) set_acp_mode(mode bool) {
	ctx.acp_mode = mode
}

// is_acp_mode returns whether ACP mode is enabled.
pub fn (ctx RuntimeContext) is_acp_mode() bool {
	return ctx.acp_mode
}

// is_shutting_down returns whether the application is shutting down.
pub fn (ctx RuntimeContext) is_shutting_down() bool {
	return ctx.shutting_down
}
