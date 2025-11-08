/**
 * Codec2 Voice Codec Wrapper
 * 
 * Provides voice compression/decompression using Codec2 library
 */

#ifndef CODEC_H
#define CODEC_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Codec2 modes (bitrates)
#define CODEC_MODE_3200 3200
#define CODEC_MODE_2400 2400
#define CODEC_MODE_1600 1600
#define CODEC_MODE_1400 1400
#define CODEC_MODE_1300 1300
#define CODEC_MODE_1200 1200
#define CODEC_MODE_700C 700

// Frame sizes (samples per frame at 8kHz)
#define CODEC_SAMPLES_PER_FRAME_8K 160
#define CODEC_SAMPLES_PER_FRAME_16K 320

typedef struct codec_context codec_context_t;

/**
 * Create codec context.
 * 
 * @param mode Codec2 mode (bitrate)
 * @param sample_rate Sample rate (8000 or 16000)
 * @return Codec context or NULL on error
 */
codec_context_t *codec_create(int mode, int sample_rate);

/**
 * Destroy codec context.
 */
void codec_destroy(codec_context_t *ctx);

/**
 * Encode PCM samples to compressed bits.
 * 
 * @param ctx Codec context
 * @param pcm_in Input PCM samples (int16)
 * @param sample_count Number of samples (must be frame size)
 * @param bits_out Output buffer for compressed bits
 * @param max_bytes Maximum size of output buffer
 * @return Number of bytes written, or -1 on error
 */
int codec_encode(codec_context_t *ctx, const int16_t *pcm_in, size_t sample_count,
                 uint8_t *bits_out, size_t max_bytes);

/**
 * Decode compressed bits to PCM samples.
 * 
 * @param ctx Codec context
 * @param bits_in Compressed bits
 * @param num_bytes Number of bytes of compressed data
 * @param pcm_out Output PCM buffer (int16)
 * @param max_samples Maximum samples output buffer can hold
 * @return Number of samples written, or -1 on error
 */
int codec_decode(codec_context_t *ctx, const uint8_t *bits_in, size_t num_bytes,
                 int16_t *pcm_out, size_t max_samples);

/**
 * Get frame size in samples for current mode.
 */
int codec_get_samples_per_frame(codec_context_t *ctx);

/**
 * Get bits per frame for current mode.
 */
int codec_get_bits_per_frame(codec_context_t *ctx);

/**
 * Get bytes per frame for current mode.
 */
int codec_get_bytes_per_frame(codec_context_t *ctx);

#ifdef __cplusplus
}
#endif

#endif // CODEC_H
