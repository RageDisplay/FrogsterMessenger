// Native audio for Frogster, called from Dart through FFI.
//
// Everything works on 48 kHz mono 16-bit PCM in 10 ms frames of 480
// samples: RNNoise's native format, and a frame size Opus takes as is.

#include <stdint.h>

#if _WIN32
#define FFI_PLUGIN_EXPORT __declspec(dllexport)
#else
#define FFI_PLUGIN_EXPORT __attribute__((visibility("default"))) __attribute__((used))
#endif

// Samples in one frame: 10 ms at 48 kHz.
FFI_PLUGIN_EXPORT int fa_frame_samples(void);

// --- Noise suppression -----------------------------------------------------

FFI_PLUGIN_EXPORT void* fa_denoiser_new(void);
FFI_PLUGIN_EXPORT void fa_denoiser_free(void* denoiser);

// Removes noise from one frame in place. Returns the probability, 0 to 1,
// that the frame holds speech.
FFI_PLUGIN_EXPORT float fa_denoise(void* denoiser, int16_t* frame);

// --- Opus ------------------------------------------------------------------

// A voice encoder at [bitrate] bits per second. Null on failure.
FFI_PLUGIN_EXPORT void* fa_encoder_new(int32_t bitrate, int32_t expected_loss_percent);
FFI_PLUGIN_EXPORT void fa_encoder_free(void* encoder);

// Encodes [samples] samples (a multiple of 120, up to 2880) into [out].
// Returns the packet length, or a negative Opus error.
FFI_PLUGIN_EXPORT int32_t fa_encode(void* encoder, const int16_t* pcm, int32_t samples,
                                    uint8_t* out, int32_t max_out);

FFI_PLUGIN_EXPORT void* fa_decoder_new(void);
FFI_PLUGIN_EXPORT void fa_decoder_free(void* decoder);

// Decodes one packet into [pcm]. A null [data] conceals a lost packet;
// [fec] recovers it from the next one instead. Returns samples decoded, or
// a negative Opus error.
FFI_PLUGIN_EXPORT int32_t fa_decode(void* decoder, const uint8_t* data, int32_t length,
                                    int16_t* pcm, int32_t max_samples, int32_t fec);

// --- Sound devices ---------------------------------------------------------

// Opens the platform's audio system; [null_backend] opens a silent one that
// keeps real time instead, for tests. Safe to call more than once. Returns
// 0, or -1 when there is no audio.
FFI_PLUGIN_EXPORT int fa_audio_init(int null_backend);

// Lists microphones ([capture] set) or speakers into [out] as lines of
// "id\tname\tdefault\n", UTF-8, null-terminated. Returns the length the
// whole list needs, which may exceed [cap]; -1 on failure.
FFI_PLUGIN_EXPORT int fa_audio_devices(int capture, char* out, int cap);

// Recording 48 kHz mono 16-bit from a microphone (null: the default one).
typedef struct fa_capture fa_capture;
FFI_PLUGIN_EXPORT fa_capture* fa_capture_new(const char* device_id, int voice_call);
// Takes up to [max_samples] recorded samples; returns how many.
FFI_PLUGIN_EXPORT int fa_capture_read(fa_capture* capture, int16_t* out, int max_samples);
FFI_PLUGIN_EXPORT void fa_capture_free(fa_capture* capture);

// Playing 48 kHz mono 16-bit samples, copied in, on a speaker.
typedef struct fa_player fa_player;
FFI_PLUGIN_EXPORT fa_player* fa_player_new(const char* device_id, const int16_t* pcm, int64_t samples);
FFI_PLUGIN_EXPORT void fa_player_play(fa_player* player, int playing);
FFI_PLUGIN_EXPORT void fa_player_seek(fa_player* player, int64_t sample);
FFI_PLUGIN_EXPORT int64_t fa_player_position(fa_player* player);
// Whether it is playing: turns 0 by itself at the end.
FFI_PLUGIN_EXPORT int fa_player_playing(fa_player* player);
FFI_PLUGIN_EXPORT void fa_player_free(fa_player* player);

// --- Voice channels --------------------------------------------------------

typedef struct fa_call fa_call;

// Starts a call on the given microphone and speakers (null: defaults).
// [devices] 0 opens neither, for tests that feed and render by hand.
FFI_PLUGIN_EXPORT fa_call* fa_call_new(const char* capture_id, const char* playback_id, int devices);
// Which devices opened: 1 the microphone, 2 the speakers.
FFI_PLUGIN_EXPORT int fa_call_devices(fa_call* call);
FFI_PLUGIN_EXPORT void fa_call_set(fa_call* call, int muted, int deafened, int denoise, int agc);

// The next packet to send, with its sequence number. Returns its length,
// 0 when there is none.
FFI_PLUGIN_EXPORT int fa_call_pop(fa_call* call, uint8_t* out, int cap, uint16_t* seq);
// A packet from someone in the channel.
FFI_PLUGIN_EXPORT void fa_call_push(fa_call* call, uint32_t member, uint16_t seq, const uint8_t* data, int len);
FFI_PLUGIN_EXPORT void fa_call_remove_peer(fa_call* call, uint32_t member);
FFI_PLUGIN_EXPORT void fa_call_set_volume(fa_call* call, uint32_t member, float volume);

// Loudness, 0 to 1: of the microphone, and of what one peer is saying.
FFI_PLUGIN_EXPORT float fa_call_mic_level(fa_call* call);
FFI_PLUGIN_EXPORT float fa_call_peer_level(fa_call* call, uint32_t member);
// Whether the microphone is being sent right now: speech was heard.
FFI_PLUGIN_EXPORT int fa_call_transmitting(fa_call* call);

// For tests: microphone samples in, speaker samples out.
FFI_PLUGIN_EXPORT void fa_call_feed(fa_call* call, const int16_t* pcm, int samples);
FFI_PLUGIN_EXPORT void fa_call_render(fa_call* call, int16_t* out, int samples);

FFI_PLUGIN_EXPORT void fa_call_free(fa_call* call);
