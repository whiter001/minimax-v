module main

fn is_headless_plain_output(output_format string) bool {
	return output_format == 'plain'
}

fn is_headless_json_output(output_format string) bool {
	return output_format == 'json'
}

fn print_headless_banner(client ApiClient, prompt string, output_format string) {
	if is_headless_plain_output(output_format) || is_headless_json_output(output_format) {
		return
	}
	println('\x1b[1;36m🤖 MiniMax CLI ${version}\x1b[0m — Headless')
	if client.enable_tools {
		println('\x1b[2m🔧 AI工具调用: 开启\x1b[0m')
	}
	println('\x1b[1;34m提问:\x1b[0m ${prompt}')
	println('')
}

fn print_headless_error(output_format string, err_msg string, exit_code int) {
	if is_headless_json_output(output_format) {
		escaped := escape_json_string(err_msg)
		println('{"error":"${escaped}","exit_code":${exit_code}}')
		return
	}
	if is_headless_plain_output(output_format) {
		eprintln('Error: ${err_msg}')
		return
	}
	println('\x1b[31m❌ 错误: ${err_msg}\x1b[0m')
}

fn print_headless_basic_response(output_format string, response string) {
	if is_headless_json_output(output_format) {
		escaped := escape_json_string(response)
		println('{"response":"${escaped}","exit_code":0}')
		return
	}
	if is_headless_plain_output(output_format) {
		println(response)
		return
	}
	println('\x1b[32m回答:\x1b[0m ${response}')
}

fn print_headless_chat_response(client ApiClient, output_format string, response string) {
	if is_headless_json_output(output_format) {
		escaped := escape_json_string(response)
		println('{"response":"${escaped}","model":"${client.model}","messages":${client.messages.len},"exit_code":0}')
		return
	}
	if is_headless_plain_output(output_format) {
		println(response)
		return
	}
	if !client.use_streaming {
		println('\x1b[32m回答:\x1b[0m ${response}')
	}
}
