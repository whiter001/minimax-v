module minimax

// =============================================================================
// API Types
// =============================================================================

// Voice represents a voice in the system
pub struct Voice {
pub:
	voice_id   string
	voice_name string
}

// VoiceList represents the response from list voices API
pub struct VoiceList {
pub mut:
	system_voice  []Voice
	voice_cloning []Voice
}

// =============================================================================
// TTS Types
// =============================================================================

// TTSRequest represents a text-to-speech request
pub struct TTSRequest {
pub:
	model          string
	text           string
	voice_setting  VoiceSetting
	audio_setting  AudioSetting
	language_boost string
	output_format  string
}

// VoiceSetting represents voice configuration
pub struct VoiceSetting {
pub:
	voice_id string
	speed    f64
	vol      f64
	pitch    int
	emotion  string
}

// AudioSetting represents audio configuration
pub struct AudioSetting {
pub:
	sample_rate int
	bitrate     int
	format      string
	channel     int
}

// =============================================================================
// Video Types
// =============================================================================

// VideoGenerationRequest represents a video generation request
pub struct VideoGenerationRequest {
pub:
	model             string
	prompt            string
	first_frame_image string
	duration          int
	resolution        string
}

// =============================================================================
// Image Types
// =============================================================================

// ImageGenerationRequest represents an image generation request
pub struct ImageGenerationRequest {
pub:
	model            string
	prompt           string
	aspect_ratio     string
	n                int
	prompt_optimizer bool
}

// =============================================================================
// Music Types
// =============================================================================

// MusicGenerationRequest represents a music generation request
pub struct MusicGenerationRequest {
pub:
	model         string
	prompt        string
	lyrics        string
	audio_setting MusicSetting
	output_format string
}

// MusicSetting represents music audio configuration
pub struct MusicSetting {
pub:
	sample_rate int
	bitrate     int
	format      string
}

// =============================================================================
// Voice Clone Types
// =============================================================================

// VoiceCloneRequest represents a voice clone request
pub struct VoiceCloneRequest {
pub:
	file_id  string
	voice_id string
	text     string
	model    string
}

// =============================================================================
// Voice Design Types
// =============================================================================

// VoiceDesignRequest represents a voice design request
pub struct VoiceDesignRequest {
pub:
	prompt       string
	preview_text string
	voice_id     string
}

// =============================================================================
// Default Values
// =============================================================================

pub const default_voice_id = 'female-shaonv'
pub const default_speech_model = 'speech-2.6-hd'
pub const default_t2v_model = 'MiniMax-Hailuo-2.3'
pub const default_t2i_model = 'image-01'
pub const default_music_model = 'music-2.0'
pub const default_speed = f64(1.0)
pub const default_volume = f64(1.0)
pub const default_pitch = 0
pub const default_emotion = 'happy'
pub const default_sample_rate = 32000
pub const default_bitrate = 128000
pub const default_channel = 1
pub const default_format = 'mp3'

// =============================================================================
// API Endpoints
// =============================================================================

pub const endpoint_t2a_v2 = '/v1/t2a_v2'
pub const endpoint_get_voice = '/v1/get_voice'
pub const endpoint_voice_clone = '/v1/voice_clone'
pub const endpoint_video_generation = '/v1/video_generation'
pub const endpoint_image_generation = '/v1/image_generation'
pub const endpoint_music_generation = '/v1/music_generation'
pub const endpoint_voice_design = '/v1/voice_design'
pub const endpoint_files_upload = '/v1/files/upload'
pub const endpoint_files_retrieve = '/v1/files/retrieve'
pub const endpoint_search = '/v1/coding_plan/search'
pub const endpoint_vlm = '/v1/coding_plan/vlm'

// =============================================================================
// Search Types
// =============================================================================

pub struct SearchRequest {
pub:
	query string
}

// =============================================================================
// VLM Types
// =============================================================================

pub struct VLMRequest {
pub:
	prompt    string
	image_url string
}
