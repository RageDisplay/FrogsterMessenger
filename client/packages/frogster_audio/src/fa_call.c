// A voice channel's sound: the microphone cleaned and encoded into packets
// for the app to send, and the packets of everyone else decoded, put back in
// order and mixed into the speakers.
//
// Two audio threads run here, the microphone's and the speakers'; the app's
// thread hands packets in and takes packets out. Packets travel in 20 ms
// frames, numbered every 20 ms whether sent or not, so a receiver can tell
// a lost packet from a pause in speech.

#include <math.h>
#include <stdlib.h>
#include <string.h>

#include "fa_miniaudio.h"
#include "frogster_audio.h"
#include "opus.h"
#include "rnnoise.h"

#define SUB 480          // RNNoise's frame: 10 ms
#define FRAME 960        // one packet: 20 ms
#define MAX_PEERS 32
#define SLOTS 64         // jitter buffer per peer, by seq: 1.28 s
#define MAX_PACKET 512   // far above what 32 kbit/s speech makes
#define OUT_SLOTS 64     // packets waiting for the app
#define HANGOVER 25      // frames still sent after speech stops: 0.5 s
// Speech starts after 30 ms of it: noise fools the detector for a frame or
// two, never for three. What came before is sent along, so the start of
// the first word is not lost to the wait.
#define ONSET 3
#define PREROLL 2
#define MIN_DEPTH 2      // frames buffered before a peer is played
#define MAX_DEPTH 12
#define START_DEPTH 3

static int seq_diff(uint16_t a, uint16_t b) { return (int16_t)(uint16_t)(a - b); }

static int16_t clamp16(float v) {
  if (v > 32767.f) return 32767;
  if (v < -32768.f) return -32768;
  return (int16_t)v;
}

typedef struct {
  uint16_t seq;
  uint16_t len;
  uint8_t used;
  uint8_t data[MAX_PACKET];
} slot;

typedef struct {
  uint32_t member;  // 0: a free place
  OpusDecoder* decoder;
  slot slots[SLOTS];
  int have_latest;
  uint16_t latest;  // newest seq that arrived
  int have_floor;
  uint16_t floor;   // nothing older than this is played any more
  int playing;
  uint16_t next;    // seq to play next
  int missed;       // packets concealed in a row
  int depth;        // frames buffered before playing starts
  int steady;       // frames played since the depth last grew
  int stopped_mid;  // stopped for want of a packet, not at a pause
  int16_t pcm[FRAME];
  int pcm_len, pcm_pos;
  float volume;
  float level;
} peer;

typedef struct {
  uint16_t seq;
  uint16_t len;
  uint8_t data[MAX_PACKET];
} out_packet;

struct fa_call {
  ma_device capture, playback;
  ma_device_id capture_id, playback_id;
  int capture_open, playback_open;

  // The microphone's thread only.
  DenoiseState* denoiser;
  OpusEncoder* encoder;
  int16_t sub[SUB];
  int sub_len;
  int16_t frame[FRAME];
  int frame_len;
  float frame_vad;
  int onset;  // RNNoise frames in a row that sounded like speech
  int hangover;
  int sending;
  uint16_t seq;
  out_packet before[PREROLL];  // the frames before speech was recognised
  float gain, speech_level;

  volatile int muted, deafened, denoise, agc;
  volatile float mic_level;
  volatile int transmitting;

  volatile ma_spinlock out_lock;
  out_packet out[OUT_SLOTS];
  int out_head, out_count;

  ma_mutex peers_lock;
  peer peers[MAX_PEERS];
};

// --- The microphone ----------------------------------------------------------

static void queue_packet(fa_call* c, const out_packet* p) {
  ma_spinlock_lock(&c->out_lock);
  if (c->out_count == OUT_SLOTS) {
    // The app stopped reading: old sound is worth less than new.
    c->out_head = (c->out_head + 1) % OUT_SLOTS;
    c->out_count--;
  }
  c->out[(c->out_head + c->out_count) % OUT_SLOTS] = *p;
  c->out_count++;
  ma_spinlock_unlock(&c->out_lock);
}

// Brings speech to a steady loudness: slowly, from the level of what the
// voice detector calls speech, so a pause is not pumped up into hiss.
static void level_speech(fa_call* c, float vad) {
  float sum = 0;
  for (int i = 0; i < SUB; i++) sum += (float)c->sub[i] * c->sub[i];
  float rms = sqrtf(sum / SUB);
  if (vad > 0.5f && rms > 50.f) c->speech_level = 0.95f * c->speech_level + 0.05f * rms;
  float want = 4000.f / (c->speech_level > 1.f ? c->speech_level : 1.f);
  if (want > 8.f) want = 8.f;
  if (want < 0.5f) want = 0.5f;
  c->gain += (want - c->gain) * 0.02f;
  for (int i = 0; i < SUB; i++) {
    float v = c->sub[i] * c->gain;
    // A soft knee instead of hard clipping, for the odd loud syllable.
    if (v > 24000.f) v = 24000.f + (v - 24000.f) * 0.25f;
    if (v < -24000.f) v = -24000.f + (v + 24000.f) * 0.25f;
    c->sub[i] = clamp16(v);
  }
}

static void finish_frame(fa_call* c) {
  uint16_t seq = ++c->seq;
  // Speech starts after ONSET confident frames and carries on above 0.3,
  // then for HANGOVER frames more, so the ends of words are not cut off.
  int speech = c->onset >= ONSET || (c->sending && c->frame_vad >= 0.3f);
  if (speech) {
    c->hangover = HANGOVER;
  } else if (c->hangover > 0) {
    c->hangover--;
  }
  int send = !c->muted && (speech || c->hangover > 0);

  // Every frame is encoded, sent or not: the encoder's state stays
  // continuous, and the frame before speech is at hand to send with it.
  out_packet p;
  p.seq = seq;
  int n = opus_encode(c->encoder, c->frame, FRAME, p.data, MAX_PACKET);
  p.len = n > 0 ? (uint16_t)n : 0;

  if (send && p.len > 0) {
    if (!c->sending) {
      for (int i = PREROLL - 1; i >= 0; i--) {
        out_packet* b = &c->before[i];
        if (b->len > 0 && b->seq == (uint16_t)(seq - 1 - i)) queue_packet(c, b);
      }
    }
    queue_packet(c, &p);
  }
  c->sending = send;
  c->transmitting = send;
  for (int i = PREROLL - 1; i > 0; i--) c->before[i] = c->before[i - 1];
  c->before[0] = p;
}

static void process_sub(fa_call* c) {
  float buffer[SUB];
  for (int i = 0; i < SUB; i++) buffer[i] = c->sub[i];
  // Run even with suppression off: its voice detection is what decides
  // when to send.
  float vad = rnnoise_process_frame(c->denoiser, buffer, buffer);
  if (c->denoise) {
    for (int i = 0; i < SUB; i++) c->sub[i] = clamp16(buffer[i]);
  }
  if (c->agc) level_speech(c, vad);

  float sum = 0;
  for (int i = 0; i < SUB; i++) sum += (float)c->sub[i] * c->sub[i];
  float level = sqrtf(sum / SUB) / 8000.f;
  c->mic_level = c->muted ? 0.f : (level > 1.f ? 1.f : level);

  if (vad > c->frame_vad) c->frame_vad = vad;
  c->onset = vad >= 0.6f ? c->onset + 1 : 0;
  memcpy(c->frame + c->frame_len, c->sub, sizeof(c->sub));
  c->frame_len += SUB;
  if (c->frame_len == FRAME) {
    finish_frame(c);
    c->frame_len = 0;
    c->frame_vad = 0;
  }
}

static void on_capture(ma_device* device, void* output, const void* input, ma_uint32 frames) {
  (void)output;
  fa_call* c = (fa_call*)device->pUserData;
  const int16_t* in = (const int16_t*)input;
  for (ma_uint32 i = 0; i < frames; i++) {
    c->sub[c->sub_len++] = in[i];
    if (c->sub_len == SUB) {
      process_sub(c);
      c->sub_len = 0;
    }
  }
}

// Exposed for tests, which have no microphone: feeds samples as the
// microphone's thread would.
void fa_call_feed(fa_call* c, const int16_t* pcm, int samples) {
  for (int i = 0; i < samples; i++) {
    c->sub[c->sub_len++] = pcm[i];
    if (c->sub_len == SUB) {
      process_sub(c);
      c->sub_len = 0;
    }
  }
}

int fa_call_pop(fa_call* c, uint8_t* out, int cap, uint16_t* seq) {
  int len = 0;
  ma_spinlock_lock(&c->out_lock);
  if (c->out_count > 0) {
    out_packet* p = &c->out[c->out_head];
    if (p->len <= cap) {
      memcpy(out, p->data, p->len);
      *seq = p->seq;
      len = p->len;
    }
    c->out_head = (c->out_head + 1) % OUT_SLOTS;
    c->out_count--;
  }
  ma_spinlock_unlock(&c->out_lock);
  return len;
}

// --- Everyone else -----------------------------------------------------------

static peer* find_peer(fa_call* c, uint32_t member, int create) {
  peer* free_place = NULL;
  for (int i = 0; i < MAX_PEERS; i++) {
    if (c->peers[i].member == member) return &c->peers[i];
    if (c->peers[i].member == 0 && free_place == NULL) free_place = &c->peers[i];
  }
  if (!create || free_place == NULL) return NULL;
  int error = 0;
  OpusDecoder* decoder = opus_decoder_create(48000, 1, &error);
  if (error != OPUS_OK || decoder == NULL) return NULL;
  memset(free_place, 0, sizeof(*free_place));
  free_place->member = member;
  free_place->decoder = decoder;
  free_place->depth = START_DEPTH;
  free_place->volume = 1.f;
  return free_place;
}

void fa_call_push(fa_call* c, uint32_t member, uint16_t seq, const uint8_t* data, int len) {
  if (member == 0 || len <= 0 || len > MAX_PACKET) return;
  ma_mutex_lock(&c->peers_lock);
  peer* p = find_peer(c, member, 1);
  if (p == NULL) goto done;
  // Too late to be of use, or from before a pause already played out.
  if (p->playing && seq_diff(seq, p->next) < 0) goto done;
  if (!p->playing && p->have_floor && seq_diff(seq, p->floor) < 0) goto done;
  if (!p->have_latest || seq_diff(seq, p->latest) > 0) {
    p->latest = seq;
    p->have_latest = 1;
  }
  if (seq_diff(p->latest, seq) >= SLOTS) goto done;
  slot* s = &p->slots[seq % SLOTS];
  s->seq = seq;
  s->len = (uint16_t)len;
  memcpy(s->data, data, (size_t)len);
  s->used = 1;
done:
  ma_mutex_unlock(&c->peers_lock);
}

static void stop_peer(peer* p, int maybe_stall) {
  p->playing = 0;
  p->floor = p->next;
  p->have_floor = 1;
  p->stopped_mid = maybe_stall;
  p->missed = 0;
}

// Decodes the peer's next 20 ms. Returns 0 when there is nothing to play:
// they are silent, or the buffer is still filling.
static int decode_next(peer* p) {
  if (!p->playing) {
    if (!p->have_latest) return 0;
    int found = 0;
    uint16_t first = 0;
    for (int k = SLOTS - 1; k >= 0; k--) {
      uint16_t s = (uint16_t)(p->latest - k);
      if (p->have_floor && seq_diff(s, p->floor) < 0) continue;
      slot* sl = &p->slots[s % SLOTS];
      if (sl->used && sl->seq == s) {
        first = s;
        found = 1;
        break;
      }
    }
    if (!found) return 0;
    if (seq_diff(p->latest, first) + 1 < p->depth) return 0;
    // Starved in the middle of speech: the network is jumpier than the
    // buffer allowed for.
    if (p->stopped_mid && p->have_floor && seq_diff(first, p->floor) < 3 && p->depth < MAX_DEPTH) {
      p->depth++;
      p->steady = 0;
    }
    p->stopped_mid = 0;
    p->next = first;
    p->playing = 1;
    p->missed = 0;
  }

  // Further behind than needed: skip ahead, or the delay only ever grows.
  if (seq_diff(p->latest, p->next) > p->depth + 6) {
    p->next = (uint16_t)(p->latest - p->depth);
  }

  slot* sl = &p->slots[p->next % SLOTS];
  int n;
  if (sl->used && sl->seq == p->next) {
    n = opus_decode(p->decoder, sl->data, sl->len, p->pcm, FRAME, 0);
    sl->used = 0;
    p->missed = 0;
  } else if (seq_diff(p->latest, p->next) > 0 && p->missed < 3) {
    // Lost, and something newer is here: rebuild it from the next
    // packet's redundancy if that one came, guess it otherwise.
    slot* after = &p->slots[(uint16_t)(p->next + 1) % SLOTS];
    if (after->used && after->seq == (uint16_t)(p->next + 1)) {
      n = opus_decode(p->decoder, after->data, after->len, p->pcm, FRAME, 1);
    } else {
      n = opus_decode(p->decoder, NULL, 0, p->pcm, FRAME, 0);
    }
    p->missed++;
  } else {
    // Nothing newer, or too much lost: they paused, or the network
    // stalled. Which one shows when they come back: right where this
    // stopped means a stall (see the start above).
    stop_peer(p, 1);
    return 0;
  }
  p->next++;
  if (n <= 0) {
    p->pcm_len = 0;
    return 0;
  }
  p->pcm_len = n;
  p->pcm_pos = 0;

  if (++p->steady >= 500 && p->depth > MIN_DEPTH) {
    // Ten seconds without starving: try a little less delay.
    p->depth--;
    p->steady = 0;
  }
  float sum = 0;
  for (int i = 0; i < n; i++) sum += (float)p->pcm[i] * p->pcm[i];
  float level = sqrtf(sum / n) / 8000.f;
  p->level = level > p->level ? level : p->level * 0.8f;
  return 1;
}

static void pull(peer* p, int16_t* out, int n) {
  int done = 0;
  while (done < n) {
    if (p->pcm_pos >= p->pcm_len && !decode_next(p)) {
      memset(out + done, 0, (size_t)(n - done) * sizeof(int16_t));
      p->level *= 0.9f;
      return;
    }
    int k = p->pcm_len - p->pcm_pos;
    if (k > n - done) k = n - done;
    memcpy(out + done, p->pcm + p->pcm_pos, (size_t)k * sizeof(int16_t));
    p->pcm_pos += k;
    done += k;
  }
}

static void mix(fa_call* c, int16_t* out, ma_uint32 frames) {
  memset(out, 0, frames * sizeof(int16_t));
  int16_t one[FRAME];
  float sum[FRAME];
  ma_mutex_lock(&c->peers_lock);
  for (ma_uint32 at = 0; at < frames; at += FRAME) {
    int n = frames - at < FRAME ? (int)(frames - at) : FRAME;
    memset(sum, 0, sizeof(sum));
    for (int i = 0; i < MAX_PEERS; i++) {
      peer* p = &c->peers[i];
      if (p->member == 0) continue;
      // Pulled even while deafened, so the buffers keep moving.
      pull(p, one, n);
      for (int k = 0; k < n; k++) sum[k] += one[k] * p->volume;
    }
    if (!c->deafened) {
      for (int k = 0; k < n; k++) {
        float v = sum[k];
        if (v > 24000.f) v = 24000.f + (v - 24000.f) * 0.25f;
        if (v < -24000.f) v = -24000.f + (v + 24000.f) * 0.25f;
        out[at + k] = clamp16(v);
      }
    }
  }
  ma_mutex_unlock(&c->peers_lock);
}

static void on_playback(ma_device* device, void* output, const void* input, ma_uint32 frames) {
  (void)input;
  mix((fa_call*)device->pUserData, (int16_t*)output, frames);
}

// Exposed for tests: what the speakers would be given next.
void fa_call_render(fa_call* c, int16_t* out, int samples) { mix(c, out, (ma_uint32)samples); }

void fa_call_remove_peer(fa_call* c, uint32_t member) {
  ma_mutex_lock(&c->peers_lock);
  peer* p = find_peer(c, member, 0);
  if (p != NULL) {
    opus_decoder_destroy(p->decoder);
    memset(p, 0, sizeof(*p));
  }
  ma_mutex_unlock(&c->peers_lock);
}

void fa_call_set_volume(fa_call* c, uint32_t member, float volume) {
  ma_mutex_lock(&c->peers_lock);
  peer* p = find_peer(c, member, 0);
  if (p != NULL) p->volume = volume < 0 ? 0 : (volume > 2 ? 2 : volume);
  ma_mutex_unlock(&c->peers_lock);
}

float fa_call_peer_level(fa_call* c, uint32_t member) {
  float level = 0;
  ma_mutex_lock(&c->peers_lock);
  peer* p = find_peer(c, member, 0);
  if (p != NULL) level = p->level;
  ma_mutex_unlock(&c->peers_lock);
  return level;
}

// --- The call ----------------------------------------------------------------

fa_call* fa_call_new(const char* capture_id, const char* playback_id, int devices) {
  if (fa_context() == NULL) return NULL;
  fa_call* c = (fa_call*)calloc(1, sizeof(fa_call));
  if (c == NULL) return NULL;
  int error = 0;
  c->denoiser = rnnoise_create(NULL);
  c->encoder = opus_encoder_create(48000, 1, OPUS_APPLICATION_VOIP, &error);
  if (c->denoiser == NULL || error != OPUS_OK || ma_mutex_init(&c->peers_lock) != MA_SUCCESS) {
    if (c->denoiser) rnnoise_destroy(c->denoiser);
    if (c->encoder) opus_encoder_destroy(c->encoder);
    free(c);
    return NULL;
  }
  opus_encoder_ctl(c->encoder, OPUS_SET_BITRATE(32000));
  opus_encoder_ctl(c->encoder, OPUS_SET_SIGNAL(OPUS_SIGNAL_VOICE));
  opus_encoder_ctl(c->encoder, OPUS_SET_COMPLEXITY(8));
  opus_encoder_ctl(c->encoder, OPUS_SET_VBR(1));
  // Each packet carries a rough copy of the one before, which the receiver
  // uses when that one is lost.
  opus_encoder_ctl(c->encoder, OPUS_SET_INBAND_FEC(1));
  opus_encoder_ctl(c->encoder, OPUS_SET_PACKET_LOSS_PERC(10));
  c->denoise = 1;
  c->agc = 1;
  c->gain = 1.f;
  c->speech_level = 4000.f;

  // Tests drive the call by hand, without devices.
  if (!devices) return c;

  ma_device_config config = ma_device_config_init(ma_device_type_capture);
  fa_configure(&config, ma_device_type_capture, capture_id, &c->capture_id, 1, 10);
  config.dataCallback = on_capture;
  config.pUserData = c;
  if (fa_open_device(&config, &c->capture) == MA_SUCCESS) {
    c->capture_open = ma_device_start(&c->capture) == MA_SUCCESS;
    if (!c->capture_open) ma_device_uninit(&c->capture);
  }

  config = ma_device_config_init(ma_device_type_playback);
  fa_configure(&config, ma_device_type_playback, playback_id, &c->playback_id, 1, 10);
  config.dataCallback = on_playback;
  config.pUserData = c;
  if (fa_open_device(&config, &c->playback) == MA_SUCCESS) {
    c->playback_open = ma_device_start(&c->playback) == MA_SUCCESS;
    if (!c->playback_open) ma_device_uninit(&c->playback);
  }
  if (!c->capture_open && !c->playback_open) {
    fa_call_free(c);
    return NULL;
  }
  return c;
}

int fa_call_devices(fa_call* c) { return (c->capture_open ? 1 : 0) | (c->playback_open ? 2 : 0); }

void fa_call_set(fa_call* c, int muted, int deafened, int denoise, int agc) {
  c->muted = muted || deafened;
  c->deafened = deafened;
  c->denoise = denoise;
  c->agc = agc;
}

float fa_call_mic_level(fa_call* c) { return c->mic_level; }

int fa_call_transmitting(fa_call* c) { return c->transmitting; }

void fa_call_free(fa_call* c) {
  if (c == NULL) return;
  // Uninitialising a device waits for its thread to leave the callback.
  if (c->capture_open) ma_device_uninit(&c->capture);
  if (c->playback_open) ma_device_uninit(&c->playback);
  for (int i = 0; i < MAX_PEERS; i++) {
    if (c->peers[i].member != 0) opus_decoder_destroy(c->peers[i].decoder);
  }
  ma_mutex_uninit(&c->peers_lock);
  rnnoise_destroy(c->denoiser);
  opus_encoder_destroy(c->encoder);
  free(c);
}
