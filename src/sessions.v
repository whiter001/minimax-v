/**
 * sessions.v - 会话管理模块
 *
 * 支持多会话隔离，保留对话历史和上下文。
 * - 会话持久化到 ~/.config/minimax/sessions/
 * - 支持会话切换和上下文恢复
 * - 自动保存消息历史
 */
import json
import os
import time

pub struct Message {
	role      string // "user" / "assistant"
	content   string
	timestamp i64
}

pub struct Session {
pub mut:
	id          string
	name        string
	model       string
	temperature f64
	messages    []Message
	context     map[string]string
	created_at  i64
	updated_at  i64
}

pub struct SessionManager {
pub mut:
	sessions          map[string]Session
	active_session_id string
	storage_path      string
}

// 创建新的会话管理器
pub fn new_session_manager(storage_path string) !SessionManager {
	// 创建存储目录
	if !os.is_dir(storage_path) {
		os.mkdir_all(storage_path)!
	}

	mut manager := SessionManager{
		sessions:     map[string]Session{}
		storage_path: storage_path
	}

	// 加载已有会话
	manager.load()!

	// 如果没有会话，创建默认会话
	if manager.sessions.len == 0 {
		mut default_session := manager.create_session('default')!
		manager.active_session_id = default_session.id
	} else if manager.active_session_id == '' {
		// 获取第一个会话作为活跃会话
		for id, _ in manager.sessions {
			manager.active_session_id = id
			break
		}
	}

	return manager
}

// 创建新会话
pub fn (mut manager SessionManager) create_session(name string) !Session {
	id := generate_session_id()
	now := time.now().unix()

	mut session := Session{
		id:          id
		name:        name
		model:       'MiniMax-M2.7'
		temperature: 0.7
		messages:    []
		context:     map[string]string{}
		created_at:  now
		updated_at:  now
	}

	manager.sessions[id] = session
	manager.active_session_id = id
	manager.save()!

	return session
}

// 切换到指定会话
pub fn (mut manager SessionManager) switch_session(id string) ! {
	if id !in manager.sessions {
		return error('会话 "${id}" 不存在')
	}
	manager.active_session_id = id
}

// 获取当前活跃会话
pub fn (manager SessionManager) get_active_session() !Session {
	if manager.active_session_id == '' {
		return error('没有活跃会话')
	}
	if manager.active_session_id !in manager.sessions {
		return error('活跃会话不存在')
	}
	return manager.sessions[manager.active_session_id]
}

// 向当前会话添加消息
pub fn (mut manager SessionManager) add_message(role string, content string) ! {
	mut session := manager.get_active_session()!

	message := Message{
		role:      role
		content:   content
		timestamp: time.now().unix()
	}

	session.messages << message
	session.updated_at = time.now().unix()
	manager.sessions[manager.active_session_id] = session

	// 自动保存
	manager.save()!
}

// 列出所有会话
pub fn (manager SessionManager) list_sessions() []Session {
	mut sessions := []Session{}
	for _, session in manager.sessions {
		sessions << session
	}
	return sessions
}

// 获取会话的消息历史
pub fn (manager SessionManager) get_messages(session_id string) ![]Message {
	if session_id !in manager.sessions {
		return error('会话不存在')
	}
	return manager.sessions[session_id].messages
}

// 删除会话
pub fn (mut manager SessionManager) delete_session(id string) ! {
	if id !in manager.sessions {
		return error('会话不存在')
	}

	manager.sessions.delete(id)

	// 如果删除的是活跃会话，切换到其他会话
	if manager.active_session_id == id {
		if manager.sessions.len > 0 {
			for session_id, _ in manager.sessions {
				manager.active_session_id = session_id
				break
			}
		} else {
			manager.active_session_id = ''
		}
	}

	manager.save()!
}

// 清空会话的消息
pub fn (mut manager SessionManager) clear_messages(session_id string) ! {
	if session_id !in manager.sessions {
		return error('会话不存在')
	}

	mut session := manager.sessions[session_id]
	session.messages = []
	session.updated_at = time.now().unix()
	manager.sessions[session_id] = session

	manager.save()!
}

// 更新会话的上下文
pub fn (mut manager SessionManager) update_context(key string, value string) ! {
	mut session := manager.get_active_session()!
	session.context[key] = value
	session.updated_at = time.now().unix()
	manager.sessions[manager.active_session_id] = session

	manager.save()!
}

// 导出会话为 JSON（包括消息历史）
pub fn (manager SessionManager) export_session(session_id string) !string {
	if session_id !in manager.sessions {
		return error('会话不存在')
	}

	session := manager.sessions[session_id]
	return json.encode(session)
}

// 保存所有会话到磁盘
pub fn (manager SessionManager) save() ! {
	for id, session in manager.sessions {
		file_path := os.join_path(manager.storage_path, '${id}.json')
		data := json.encode(session)
		os.write_file(file_path, data)!
	}
}

// 从磁盘加载会话
pub fn (mut manager SessionManager) load() ! {
	if !os.is_dir(manager.storage_path) {
		return
	}

	files := os.ls(manager.storage_path)!
	for file in files {
		if file.ends_with('.json') {
			file_path := os.join_path(manager.storage_path, file)
			content := os.read_file(file_path)!

			session := json.decode(Session, content) or { continue }

			manager.sessions[session.id] = session
		}
	}
}

// 获取会话统计信息
pub fn (manager SessionManager) get_stats(session_id string) !map[string]int {
	if session_id !in manager.sessions {
		return error('会话不存在')
	}

	session := manager.sessions[session_id]
	mut user_msgs := 0
	mut assistant_msgs := 0

	for msg in session.messages {
		if msg.role == 'user' {
			user_msgs++
		} else if msg.role == 'assistant' {
			assistant_msgs++
		}
	}

	return {
		'total_messages':     session.messages.len
		'user_messages':      user_msgs
		'assistant_messages': assistant_msgs
		'context_size':       session.context.len
	}
}

// 生成唯一的会话 ID
fn generate_session_id() string {
	timestamp := time.now().unix_milli()
	return 'sess_${timestamp}'
}
