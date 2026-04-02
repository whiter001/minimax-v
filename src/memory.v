module main

import os
import time

// SessionNoteEntry represents a structured note entry with timestamp.
struct SessionNoteEntry {
mut:
	content   string
	timestamp string
}

// WorkingCheckpoint stores short-term working memory with structured fields.
pub struct WorkingCheckpoint {
mut:
	key_info    string
	related_sop string
}

// MemoryService manages persistent memory across sessions including session notes,
// working checkpoints, and context summarization.
pub struct MemoryService {
mut:
	checkpoint_loaded bool
	loaded_checkpoint WorkingCheckpoint
}

// new_memory_service creates a new MemoryService instance.
pub fn new_memory_service() MemoryService {
	return MemoryService{
		checkpoint_loaded: false
		loaded_checkpoint: WorkingCheckpoint{}
	}
}

// get_config_dir returns the minimax config directory path, creating it if needed.
fn get_config_dir() string {
	config_home := get_minimax_config_dir()
	if !os.is_dir(config_home) {
		os.mkdir_all(config_home) or {}
	}
	return config_home
}

// session_notes_path returns the path to the session notes file.
fn (s MemoryService) session_notes_path() string {
	return os.join_path(get_config_dir(), 'session_notes.md')
}

// checkpoint_path returns the path to the working checkpoint file.
fn (s MemoryService) checkpoint_path() string {
	return os.join_path(get_config_dir(), 'working_checkpoint.md')
}

// append_note appends content to the session notes file.
// Returns the number of characters written.
pub fn (mut s MemoryService) append_note(content string) string {
	if content.trim_space().len == 0 {
		return 'Note content is empty'
	}
	path := s.session_notes_path()
	existing := os.read_file(path) or { '' }
	now := time.now().format()
	new_content := if existing.len > 0 {
		'${existing}\n${content}\n<!-- ${now} -->'
	} else {
		'${content}\n<!-- ${now} -->'
	}
	os.write_file(path, new_content) or {
		return 'Error: Failed to append to session notes: ${err.msg}'
	}
	return 'Note appended (${new_content.len} chars)'
}

// get_notes returns all session notes content.
pub fn (s MemoryService) get_notes() string {
	path := s.session_notes_path()
	if !os.exists(path) {
		return '(No session notes yet)'
	}
	content := os.read_file(path) or { return '(Failed to read notes)' }
	if content.len == 0 {
		return '(Session notes file is empty)'
	}
	return content
}

// load_checkpoint loads the working checkpoint from disk if not already loaded.
fn (mut s MemoryService) load_checkpoint() {
	if s.checkpoint_loaded {
		return
	}
	s.checkpoint_loaded = true
	path := s.checkpoint_path()
	if !os.exists(path) {
		return
	}
	content := os.read_file(path) or { return }
	s.loaded_checkpoint = s.parse_checkpoint(content)
}

// parse_checkpoint parses the working checkpoint from file content.
fn (s MemoryService) parse_checkpoint(content string) WorkingCheckpoint {
	mut cp := WorkingCheckpoint{}
	key_marker := '[KEY_INFO]'
	sop_marker := '[RELATED_SOP]'
	key_idx := content.index(key_marker) or { -1 }
	sop_idx := content.index(sop_marker) or { -1 }
	if key_idx >= 0 && sop_idx >= 0 && key_idx < sop_idx {
		cp.key_info = content[key_idx + key_marker.len..sop_idx].trim_space()
		cp.related_sop = content[sop_idx + sop_marker.len..].trim_space()
		return cp
	}
	cp.key_info = content.trim_space()
	return cp
}

// serialize_checkpoint serializes the working checkpoint to file format.
fn (s MemoryService) serialize_checkpoint(cp WorkingCheckpoint) string {
	return '[KEY_INFO]\n${cp.key_info.trim_space()}\n\n[RELATED_SOP]\n${cp.related_sop.trim_space()}\n'
}

// save_checkpoint saves the working checkpoint to disk.
fn (mut s MemoryService) save_checkpoint() ! {
	path := s.checkpoint_path()
	os.write_file(path, s.serialize_checkpoint(s.loaded_checkpoint))!
}

// format_checkpoint formats the working checkpoint for display.
fn (s MemoryService) format_checkpoint(cp WorkingCheckpoint) string {
	mut sections := []string{}
	if cp.key_info.trim_space().len > 0 {
		sections << '<key_info>\n${cp.key_info.trim_space()}\n</key_info>'
	}
	if cp.related_sop.trim_space().len > 0 {
		sections << '<related_sop>\n${cp.related_sop.trim_space()}\n</related_sop>'
	}
	return sections.join('\n')
}

// update_checkpoint updates the working checkpoint with new key_info and/or related_sop.
// If both are empty, returns the current checkpoint content.
pub fn (mut s MemoryService) update_checkpoint(key_info string, related_sop string) string {
	s.load_checkpoint()
	trimmed_key := key_info.trim_space()
	trimmed_sop := related_sop.trim_space()
	if trimmed_key.len == 0 && trimmed_sop.len == 0 {
		current := s.format_checkpoint(s.loaded_checkpoint)
		if current.len == 0 {
			return '(No working checkpoint yet)'
		}
		return current
	}
	if trimmed_key.len > 0 {
		s.loaded_checkpoint.key_info = trimmed_key
	}
	if trimmed_sop.len > 0 {
		s.loaded_checkpoint.related_sop = trimmed_sop
	}
	s.save_checkpoint() or { return 'Error: Failed to save checkpoint: ${err.msg()}' }
	return s.format_checkpoint(s.loaded_checkpoint)
}

// get_checkpoint_context returns the formatted working checkpoint context.
pub fn (mut s MemoryService) get_checkpoint_context() string {
	s.load_checkpoint()
	formatted := s.format_checkpoint(s.loaded_checkpoint)
	if formatted.len == 0 {
		return ''
	}
	return 'Working checkpoint:\n${formatted}'
}

// estimate_tokens estimates the token count for a given text.
// Uses a simple heuristic: ~4 characters per token on average.
fn estimate_tokens(text string) int {
	if text.len == 0 {
		return 0
	}
	// Split by whitespace and count tokens, then apply heuristic
	tokens := text.split(' ')
	// Heuristic: 4 chars per token average
	return (text.len / 4) + tokens.len
}

// summarize truncates text to fit within the specified token limit.
// If text exceeds the limit, preserves beginning and end, marking the truncation.
pub fn (s MemoryService) summarize(text string, max_tokens int) string {
	if max_tokens <= 0 {
		return text
	}
	tokens := estimate_tokens(text)
	if tokens <= max_tokens {
		return text
	}
	// Calculate how many characters to keep based on token ratio
	ratio := f64(max_tokens) / f64(tokens)
	mut keep_chars := int(f64(text.len) * ratio * 0.9) // 0.9 safety margin
	if keep_chars < text.len / 2 {
		keep_chars = text.len / 2
	}
	begin := text[..keep_chars]
	mut end_idx := text.len - keep_chars
	if end_idx > keep_chars {
		end_idx = keep_chars
	}
	end := text[text.len - end_idx..]
	return '${begin}\n... [${tokens - max_tokens} tokens truncated] ...\n${end}'
}
