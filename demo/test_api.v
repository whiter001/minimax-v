module main

import os
import net.http
import time

// 直接测试 web_search API 端点
fn main() {
	api_key := os.getenv('MINIMAX_API_KEY')
	if api_key.len == 0 {
		eprintln('Error: MINIMAX_API_KEY not set')
		return
	}

	host := 'https://api.minimax.chat'
	url := host + '/v1/search'

	body := '{"q":"hello world"}'

	mut h := http.new_header()
	h.add(.authorization, 'Bearer ${api_key}')
	h.add(.content_type, 'application/json')

	mut req := http.Request{
		method: .post
		url: url
		header: h
		data: body
		read_timeout: 60 * time.second
		write_timeout: 30 * time.second
	}

	println('Testing web_search API via net.http...')
	println('URL: ${url}')
	println('Request body: ${body}')
	println('')

	resp := req.do() or {
		eprintln('Request failed: ${err}')
		return
	}

	println('Status: ${resp.status_code}')
	println('Response:')
	println(resp.body)
}
