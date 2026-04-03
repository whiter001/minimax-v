module main

// ConversationGuard prevents overlapping prompt execution and mirrors the
// dispatch/running guard used by Claude Code-style loops.
pub struct ConversationGuard {
mut:
	active    bool
	generation int
}

pub fn new_conversation_guard() ConversationGuard {
	return ConversationGuard{}
}

pub fn (mut g ConversationGuard) try_start() ?int {
	if g.active {
		return none
	}
	g.active = true
	g.generation++
	return g.generation
}

pub fn (mut g ConversationGuard) end(generation int) bool {
	if !g.active || g.generation != generation {
		return false
	}
	g.active = false
	return true
}

// PromptSession keeps a queue of prompts and processes them sequentially
// through a single ApiClient conversation.
pub struct PromptSession {
mut:
	client  ApiClient
	guard   ConversationGuard
	queue   []string
}

pub fn new_prompt_session(config Config, executor ToolExecutor) PromptSession {
	return PromptSession{
		client: new_api_client(config, executor)
		guard:  new_conversation_guard()
		queue:  []string{}
	}
}

pub fn (mut s PromptSession) enqueue(prompt string) {
	trimmed := prompt.trim_space()
	if trimmed.len == 0 {
		return
	}
	s.queue << trimmed
}

pub fn (mut s PromptSession) run() !string {
	mut last_answer := ''
	for s.queue.len > 0 {
		generation := s.guard.try_start() or {
			return error('conversation already in progress')
		}
		prompt := s.queue[0]
		s.queue = s.queue[1..]
		last_answer = s.client.chat(prompt) or {
			s.guard.end(generation)
			return err
		}
		if !s.guard.end(generation) {
			return error('conversation guard state became stale')
		}
	}
	if last_answer.len == 0 {
		return error('no prompt was queued')
	}
	return last_answer
}
