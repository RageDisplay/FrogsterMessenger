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
