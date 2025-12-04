#ifndef NADE_CORE_H
#define NADE_CORE_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

int nade_init(const uint8_t *seed32);
int nade_start_session_server(const uint8_t *peer_pubkey, size_t len);
int nade_start_session_client(const uint8_t *peer_pubkey, size_t len);
int nade_stop_session(void);

int nade_feed_mic_frame(const int16_t *pcm, size_t samples);
size_t nade_generate_outgoing_frame(uint8_t *buffer, size_t max_len);
int nade_handle_incoming_frame(const uint8_t *data, size_t len);
int nade_pull_speaker_frame(int16_t *out_buf, size_t max_samples);

int nade_set_config(const char *json);

int nade_send_hangup_signal(void);
int nade_consume_remote_hangup(void);

// -------------------------------------------------------------------------
// 4-FSK Modulation API
// Converts encrypted data bytes <-> audio tones for "audio over audio" transport

// Enable or disable 4-FSK modulation (enabled by default)
int nade_fsk_set_enabled(bool enabled);
bool nade_fsk_is_enabled(void);

// Modulate data bytes into PCM audio samples (for transmission)
// Returns number of PCM samples written to pcm_out
size_t nade_fsk_modulate(const uint8_t *data, size_t len, int16_t *pcm_out, size_t max_samples);

// Feed received PCM audio for demodulation
int nade_fsk_feed_audio(const int16_t *pcm, size_t samples);

// Pull demodulated bytes (call after feeding audio)
size_t nade_fsk_pull_demodulated(uint8_t *out, size_t max_len);

// Calculate number of PCM samples needed to modulate given bytes
// (4 symbols per byte * 80 samples per symbol = 320 samples per byte)
size_t nade_fsk_samples_for_bytes(size_t byte_count);

// -------------------------------------------------------------------------
// Reed-Solomon Error Correction API
// RS(255, 223) - can correct up to 16 byte errors per block

// Enable or disable Reed-Solomon error correction
// When enabled, RS encoding is automatically applied to FSK transmissions
int nade_rs_set_enabled(bool enabled);
bool nade_rs_is_enabled(void);

// Encode data with Reed-Solomon parity (adds 32 parity bytes)
// Returns total encoded length, or 0 on error
size_t nade_rs_encode(const uint8_t *data, size_t len, uint8_t *out, size_t max_out);

// Decode and correct errors in Reed-Solomon codeword
// Corrects data in-place, returns number of errors corrected or -1 if uncorrectable
int nade_rs_decode(uint8_t *codeword, size_t len);

// Get encoded length for given data length (data_len + 32 parity bytes)
size_t nade_rs_encoded_len(size_t data_len);

// Get data length from encoded length (encoded_len - 32 parity bytes)
size_t nade_rs_data_len(size_t encoded_len);

#ifdef __cplusplus
}
#endif

#endif // NADE_CORE_H
