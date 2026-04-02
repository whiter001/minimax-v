module main

import os
import net.http
import time

// 测试 net.http POST multipart/form-data 文件上传
fn main() {
	println('=== 测试 net.http POST multipart/form-data 文件上传 ===')
	println('')

	// 创建测试文件
	text_content := 'Hello from net.http file upload test!'
	os.write_file('demo/test.txt', text_content)!

	// 使用手动构建的 multipart/form-data POST 请求上传到 httpbin.org
	resp := http_post_multipart('https://httpbin.org/post', 'demo/test.txt', 'file') or {
		eprintln('上传失败: ${err}')
		return
	}

	println('HTTP 状态: ${resp.status_code}')
	println('响应 files.file: ${resp.body}')
	println('')
	println('上传成功!')
}

// 手动构建 multipart/form-data POST 请求
fn http_post_multipart(url string, filepath string, field_name string) !http.Response {
	boundary := '----WebKitFormBoundary7MA4YWxkTrZu0gW'

	file_data := os.read_file(filepath)!
	mut file_name := filepath.all_after_last('/')
	if file_name == filepath {
		file_name = filepath.all_after('\\')
	}

	// 构建 multipart body
	mut body := '--${boundary}\r\n'
	body += 'Content-Disposition: form-data; name="${field_name}"; filename="${file_name}"\r\n'
	body += 'Content-Type: application/octet-stream\r\n\r\n'
	body += file_data
	body += '\r\n'
	body += '--${boundary}--\r\n'

	mut h := http.new_header()
	h.add(.content_type, 'multipart/form-data; boundary=${boundary}')

mut req := http.Request{
		method: .post
		url: url
		header: h
		data: body
		read_timeout: 30 * time.second
		write_timeout: 30 * time.second
	}

	resp := req.do()!
	return resp
}
