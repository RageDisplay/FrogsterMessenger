// miniaudio as Frogster uses it: device input and output only, on the
// platforms the app runs on. Every file that includes miniaudio includes this
// instead, so they all see the same configuration.
#ifndef FA_MINIAUDIO_H
#define FA_MINIAUDIO_H

#define MA_NO_DECODING
#define MA_NO_ENCODING
#define MA_NO_GENERATION
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_NODE_GRAPH
#define MA_NO_ENGINE

#define MA_ENABLE_ONLY_SPECIFIC_BACKENDS
#define MA_ENABLE_WASAPI
#define MA_ENABLE_AAUDIO
#define MA_ENABLE_OPENSL
// A device with no hardware behind it, keeping real time: what the tests
// play and record through.
#define MA_ENABLE_NULL

#include "third_party/miniaudio/miniaudio.h"

// The one context the library opens devices on. Null before fa_audio_init.
ma_context* fa_context(void);

// Fills [config] for one direction of a device: 48 kHz mono 16-bit, the
// device named by [device_id] (null or unknown: the system's default), and
// the platform's voice-call processing when [voice_call] is set.
void fa_configure(ma_device_config* config, ma_device_type type, const char* device_id,
                  ma_device_id* id_storage, int voice_call, ma_uint32 period_ms);

// Opens a device on the context, on the default device when the chosen one
// will not open.
ma_result fa_open_device(ma_device_config* config, ma_device* device);

#endif
