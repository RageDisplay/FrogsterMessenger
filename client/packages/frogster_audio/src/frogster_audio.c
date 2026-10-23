#include "frogster_audio.h"

#include <stdlib.h>

#include "opus.h"
#include "rnnoise.h"

#define SAMPLE_RATE 48000
#define FRAME 480

int fa_frame_samples(void) { return FRAME; }

void* fa_denoiser_new(void) { return rnnoise_create(NULL); }

void fa_denoiser_free(void* denoiser) {
  if (denoiser) rnnoise_destroy((DenoiseState*)denoiser);
}

float fa_denoise(void* denoiser, int16_t* frame) {
  // RNNoise works on floats in the 16-bit range.
  float buffer[FRAME];
  for (int i = 0; i < FRAME; i++) buffer[i] = frame[i];
  float speech = rnnoise_process_frame((DenoiseState*)denoiser, buffer, buffer);
  for (int i = 0; i < FRAME; i++) {
    float s = buffer[i];
    if (s > 32767.f) s = 32767.f;
    if (s < -32768.f) s = -32768.f;
    frame[i] = (int16_t)s;
  }
  return speech;
}

void* fa_encoder_new(int32_t bitrate, int32_t expected_loss_percent) {
  int error = 0;
  OpusEncoder* enc = opus_encoder_create(SAMPLE_RATE, 1, OPUS_APPLICATION_VOIP, &error);
  if (error != OPUS_OK || enc == NULL) return NULL;
  opus_encoder_ctl(enc, OPUS_SET_BITRATE(bitrate));
  opus_encoder_ctl(enc, OPUS_SET_SIGNAL(OPUS_SIGNAL_VOICE));
  opus_encoder_ctl(enc, OPUS_SET_COMPLEXITY(9));
  opus_encoder_ctl(enc, OPUS_SET_VBR(1));
  if (expected_loss_percent > 0) {
    // Live speech over the internet: each packet carries enough of the
    // previous one to rebuild it when it is lost.
    opus_encoder_ctl(enc, OPUS_SET_INBAND_FEC(1));
    opus_encoder_ctl(enc, OPUS_SET_PACKET_LOSS_PERC(expected_loss_percent));
    opus_encoder_ctl(enc, OPUS_SET_DTX(1));
  }
  return enc;
}

void fa_encoder_free(void* encoder) {
  if (encoder) opus_encoder_destroy((OpusEncoder*)encoder);
}

int32_t fa_encode(void* encoder, const int16_t* pcm, int32_t samples, uint8_t* out,
                  int32_t max_out) {
  return opus_encode((OpusEncoder*)encoder, pcm, samples, out, max_out);
}

void* fa_decoder_new(void) {
  int error = 0;
  OpusDecoder* dec = opus_decoder_create(SAMPLE_RATE, 1, &error);
  return error == OPUS_OK ? dec : NULL;
}

void fa_decoder_free(void* decoder) {
  if (decoder) opus_decoder_destroy((OpusDecoder*)decoder);
}

int32_t fa_decode(void* decoder, const uint8_t* data, int32_t length, int16_t* pcm,
                  int32_t max_samples, int32_t fec) {
  return opus_decode((OpusDecoder*)decoder, data, length, pcm, max_samples, fec);
}
