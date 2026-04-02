module main

import os
import minimax

fn main() {
	api_key := os.getenv('MINIMAX_API_KEY')
	if api_key.len == 0 {
		eprintln('Error: MINIMAX_API_KEY not set')
		return
	}

	mut host := os.getenv('MINIMAX_API_HOST')
	if host.len == 0 {
		host = 'https://api.minimax.chat'
	}

	client := minimax.new_client(api_key, host)
	req := minimax.SearchRequest{query: 'hello world'}

	println('Testing web_search...')
	result := client.search(req) or {
		eprintln('Search failed: ${err}')
		return
	}

	println('Result:')
	for key, val in result {
		println('  ${key}: ${val}')
	}
}
