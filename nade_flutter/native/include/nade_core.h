#ifndef NADE_CORE_H
#define NADE_CORE_H

#include <stddef.h>
#include <stdint.h>

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

#ifdef __cplusplus
}
#endif

#endif // NADE_CORE_H
