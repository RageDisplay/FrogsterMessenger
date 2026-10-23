// Sound devices: listing them, recording from one, playing to one.
#define MINIAUDIO_IMPLEMENTATION
#include "fa_miniaudio.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "frogster_audio.h"

#define SAMPLE_RATE 48000

static ma_context g_context;
static int g_ready = 0;
static volatile ma_spinlock g_lock = 0;

int fa_audio_init(int null_backend) {
  ma_spinlock_lock(&g_lock);
  if (!g_ready) {
    ma_context_config config = ma_context_config_init();
    ma_backend none = ma_backend_null;
    ma_result r = null_backend ? ma_context_init(&none, 1, &config, &g_context)
                               : ma_context_init(NULL, 0, &config, &g_context);
    g_ready = r == MA_SUCCESS;
  }
  int ready = g_ready;
  ma_spinlock_unlock(&g_lock);
  return ready ? 0 : -1;
}

ma_context* fa_context(void) { return g_ready ? &g_context : NULL; }

// --- Device ids --------------------------------------------------------------
//
// Each backend names devices its own way; outside this file an id is a
// string: the WASAPI endpoint id as UTF-8 on Windows, the AudioDeviceInfo id
// on Android (which is what AAudio takes), so the app can also list devices
// through Android's own API and open what it found.

static void id_to_string(const ma_device_id* id, char* out, size_t cap) {
  out[0] = 0;
  switch (g_context.backend) {
#ifdef _WIN32
    case ma_backend_wasapi:
      if (WideCharToMultiByte(CP_UTF8, 0, (const wchar_t*)id->wasapi, -1, out, (int)cap, NULL, NULL) == 0) {
        out[0] = 0;
      }
      break;
#endif
    case ma_backend_aaudio:
      snprintf(out, cap, "%d", (int)id->aaudio);
      break;
    case ma_backend_opensl:
      snprintf(out, cap, "%u", (unsigned)id->opensl);
      break;
    case ma_backend_null:
      snprintf(out, cap, "%d", id->nullbackend);
      break;
    default:
      break;
  }
}

static int id_from_string(const char* s, ma_device_id* id) {
  if (s == NULL || s[0] == 0) return 0;
  memset(id, 0, sizeof(*id));
  char* end = NULL;
  switch (g_context.backend) {
#ifdef _WIN32
    case ma_backend_wasapi:
      return MultiByteToWideChar(CP_UTF8, 0, s, -1, (wchar_t*)id->wasapi,
                                 (int)(sizeof(id->wasapi) / sizeof(id->wasapi[0]))) > 0;
#endif
    case ma_backend_aaudio:
      id->aaudio = (ma_int32)strtol(s, &end, 10);
      return end != s && *end == 0 && id->aaudio > 0;
    case ma_backend_opensl:
      id->opensl = (ma_uint32)strtoul(s, &end, 10);
      return end != s && *end == 0;
    case ma_backend_null:
      id->nullbackend = (int)strtol(s, &end, 10);
      return end != s && *end == 0;
    default:
      return 0;
  }
}

typedef struct {
  ma_device_type type;
  char* out;
  int cap;
  int len;
} device_list;

static void append(device_list* list, const char* text) {
  for (const char* p = text; *p; p++) {
    // Tabs and line breaks separate the fields; a name never needs one.
    char c = (*p == '\t' || *p == '\n' || *p == '\r') ? ' ' : *p;
    if (list->len + 1 < list->cap) list->out[list->len] = c;
    list->len++;
  }
}

static ma_bool32 on_device(ma_context* context, ma_device_type type, const ma_device_info* info,
                           void* user) {
  (void)context;
  device_list* list = (device_list*)user;
  if (type != list->type) return MA_TRUE;
  char id[512];
  id_to_string(&info->id, id, sizeof(id));
  if (id[0] == 0) return MA_TRUE;
  append(list, id);
  append(list, "\t");
  append(list, info->name);
  append(list, info->isDefault ? "\t1\n" : "\t0\n");
  return MA_TRUE;
}

int fa_audio_devices(int capture, char* out, int cap) {
  if (!g_ready) return -1;
  device_list list = {capture ? ma_device_type_capture : ma_device_type_playback, out, cap, 0};
  if (ma_context_enumerate_devices(&g_context, on_device, &list) != MA_SUCCESS) return -1;
  if (cap > 0) out[list.len < cap ? list.len : cap - 1] = 0;
  return list.len;
}

void fa_configure(ma_device_config* config, ma_device_type type, const char* device_id,
                  ma_device_id* id_storage, int voice_call, ma_uint32 period_ms) {
  const ma_device_id* id = id_from_string(device_id, id_storage) ? id_storage : NULL;
  if (type == ma_device_type_capture) {
    config->capture.format = ma_format_s16;
    config->capture.channels = 1;
    config->capture.pDeviceID = id;
  } else {
    config->playback.format = ma_format_s16;
    config->playback.channels = 1;
    config->playback.pDeviceID = id;
  }
  config->sampleRate = SAMPLE_RATE;
  config->periodSizeInMilliseconds = period_ms;
  config->performanceProfile = ma_performance_profile_low_latency;
  // Android: a call gets the phone's echo cancellation and is routed as a
  // call; a message is recorded as plainly as the phone allows, since our
  // own noise suppression does the cleaning.
  config->aaudio.inputPreset =
      voice_call ? ma_aaudio_input_preset_voice_communication : ma_aaudio_input_preset_voice_recognition;
  config->aaudio.usage = voice_call ? ma_aaudio_usage_voice_communication : ma_aaudio_usage_media;
  config->aaudio.contentType = ma_aaudio_content_type_speech;
  config->opensl.recordingPreset = voice_call ? ma_opensl_recording_preset_voice_communication
                                              : ma_opensl_recording_preset_voice_recognition;
  config->opensl.streamType = voice_call ? ma_opensl_stream_type_voice : ma_opensl_stream_type_media;
}

// Opens a device, falling back to the default one when the chosen device is
// gone (unplugged, or a saved choice from another machine).
static ma_result open_device(ma_device_config* config, ma_device* device) {
  ma_result r = ma_device_init(&g_context, config, device);
  if (r != MA_SUCCESS && (config->capture.pDeviceID != NULL || config->playback.pDeviceID != NULL)) {
    config->capture.pDeviceID = NULL;
    config->playback.pDeviceID = NULL;
    r = ma_device_init(&g_context, config, device);
  }
  return r;
}

ma_result fa_open_device(ma_device_config* config, ma_device* device) {
  return open_device(config, device);
}

// --- Recording ---------------------------------------------------------------

struct fa_capture {
  ma_device device;
  ma_device_id id;
  ma_pcm_rb ring;
};

static void capture_callback(ma_device* device, void* output, const void* input, ma_uint32 frames) {
  (void)output;
  fa_capture* c = (fa_capture*)device->pUserData;
  const ma_int16* in = (const ma_int16*)input;
  while (frames > 0) {
    ma_uint32 n = frames;
    void* buffer;
    if (ma_pcm_rb_acquire_write(&c->ring, &n, &buffer) != MA_SUCCESS || n == 0) return;  // full: drop
    memcpy(buffer, in, n * sizeof(ma_int16));
    ma_pcm_rb_commit_write(&c->ring, n);
    in += n;
    frames -= n;
  }
}

fa_capture* fa_capture_new(const char* device_id, int voice_call) {
  if (!g_ready) return NULL;
  fa_capture* c = (fa_capture*)calloc(1, sizeof(fa_capture));
  if (c == NULL) return NULL;
  // Four seconds: the app reads every few tens of milliseconds, and a
  // stall longer than this loses sound rather than memory.
  if (ma_pcm_rb_init(ma_format_s16, 1, SAMPLE_RATE * 4, NULL, NULL, &c->ring) != MA_SUCCESS) {
    free(c);
    return NULL;
  }
  ma_device_config config = ma_device_config_init(ma_device_type_capture);
  fa_configure(&config, ma_device_type_capture, device_id, &c->id, voice_call, 20);
  config.dataCallback = capture_callback;
  config.pUserData = c;
  if (open_device(&config, &c->device) != MA_SUCCESS) {
    ma_pcm_rb_uninit(&c->ring);
    free(c);
    return NULL;
  }
  if (ma_device_start(&c->device) != MA_SUCCESS) {
    ma_device_uninit(&c->device);
    ma_pcm_rb_uninit(&c->ring);
    free(c);
    return NULL;
  }
  return c;
}

int fa_capture_read(fa_capture* c, int16_t* out, int max_samples) {
  int total = 0;
  while (total < max_samples) {
    ma_uint32 n = (ma_uint32)(max_samples - total);
    void* buffer;
    if (ma_pcm_rb_acquire_read(&c->ring, &n, &buffer) != MA_SUCCESS || n == 0) break;
    memcpy(out + total, buffer, n * sizeof(int16_t));
    ma_pcm_rb_commit_read(&c->ring, n);
    total += (int)n;
  }
  return total;
}

void fa_capture_free(fa_capture* c) {
  if (c == NULL) return;
  ma_device_uninit(&c->device);
  ma_pcm_rb_uninit(&c->ring);
  free(c);
}

// --- Playing -----------------------------------------------------------------

struct fa_player {
  ma_device device;
  ma_device_id id;
  int16_t* pcm;
  ma_uint64 length;
  ma_uint64 position;  // atomic
  ma_uint32 playing;   // atomic
};

static void player_callback(ma_device* device, void* output, const void* input, ma_uint32 frames) {
  (void)input;
  fa_player* p = (fa_player*)device->pUserData;
  ma_int16* out = (ma_int16*)output;
  ma_uint32 n = 0;
  if (ma_atomic_load_32(&p->playing)) {
    ma_uint64 start = ma_atomic_load_64(&p->position);
    ma_uint64 at = start;
    if (at < p->length) {
      ma_uint64 left = p->length - at;
      n = left < frames ? (ma_uint32)left : frames;
      memcpy(out, p->pcm + at, n * sizeof(ma_int16));
      at += n;
      // Only if the app did not seek meanwhile: its seek wins.
      ma_atomic_compare_and_swap_64(&p->position, start, at);
    }
    if (at >= p->length) ma_atomic_store_32(&p->playing, 0);
  }
  if (n < frames) memset(out + n, 0, (frames - n) * sizeof(ma_int16));
}

fa_player* fa_player_new(const char* device_id, const int16_t* pcm, int64_t samples) {
  if (!g_ready || samples < 0) return NULL;
  fa_player* p = (fa_player*)calloc(1, sizeof(fa_player));
  if (p == NULL) return NULL;
  p->pcm = (int16_t*)malloc((size_t)(samples > 0 ? samples : 1) * sizeof(int16_t));
  if (p->pcm == NULL) {
    free(p);
    return NULL;
  }
  if (samples > 0) memcpy(p->pcm, pcm, (size_t)samples * sizeof(int16_t));
  p->length = (ma_uint64)samples;
  ma_device_config config = ma_device_config_init(ma_device_type_playback);
  fa_configure(&config, ma_device_type_playback, device_id, &p->id, 0, 20);
  config.dataCallback = player_callback;
  config.pUserData = p;
  if (open_device(&config, &p->device) != MA_SUCCESS || ma_device_start(&p->device) != MA_SUCCESS) {
    ma_device_uninit(&p->device);
    free(p->pcm);
    free(p);
    return NULL;
  }
  return p;
}

void fa_player_play(fa_player* p, int playing) {
  if (playing && ma_atomic_load_64(&p->position) >= p->length) ma_atomic_store_64(&p->position, 0);
  ma_atomic_store_32(&p->playing, playing ? 1 : 0);
}

void fa_player_seek(fa_player* p, int64_t sample) {
  if (sample < 0) sample = 0;
  if ((ma_uint64)sample > p->length) sample = (int64_t)p->length;
  ma_atomic_store_64(&p->position, (ma_uint64)sample);
}

int64_t fa_player_position(fa_player* p) { return (int64_t)ma_atomic_load_64(&p->position); }

int fa_player_playing(fa_player* p) { return (int)ma_atomic_load_32(&p->playing); }

void fa_player_free(fa_player* p) {
  if (p == NULL) return;
  ma_device_uninit(&p->device);
  free(p->pcm);
  free(p);
}
