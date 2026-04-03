module main

fn (mut c ApiClient) runtime_mark_shutting_down() bool {
	if c.shutting_down {
		return true
	}
	c.shutting_down = true
	return false
}

fn (mut c ApiClient) runtime_stop_all_mcp() {
	if c.mcp_manager.servers.len > 0 {
		c.mcp_manager.stop_all()
	}
}

fn (mut c ApiClient) runtime_set_acp_mode(enabled bool) {
	c.acp_mode = enabled
}

fn (c &ApiClient) runtime_is_acp_mode() bool {
	return c.acp_mode
}
