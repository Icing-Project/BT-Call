/**
 * 4-FSK Modem Header
 */

#ifndef MODEM_FSK_H
#define MODEM_FSK_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct fsk_modem fsk_modem_t;

typedef struct {
    int sample_rate;
    double symbol_rate;
    int frequencies[4]; // Four FSK frequencies
} fsk_config_t;

typedef struct {
    uint64_t symbols_transmitted;
    uint64_t symbols_received;
    int sync_locked;
    double timing_error;
    uint64_t sync_losses;
} fsk_stats_t;

/**
 * Create a new FSK modem instance.
 */
fsk_modem_t *fsk_modem_create(const fsk_config_t *config);

/**
 * Destroy FSK modem and free resources.
 */
void fsk_modem_destroy(fsk_modem_t *modem);

/**
 * Modulate data into audio samples.
 * 
 * @param data Input data bytes
 * @param data_len Length of input data
 * @param out_samples Output PCM buffer (int16)
 * @param out_len Input: buffer size, Output: actual samples written
 * @return 0 on success, -1 on error
 */
int fsk_modulate(fsk_modem_t *modem, const uint8_t *data, size_t data_len,
                 int16_t *out_samples, size_t *out_len);

/**
 * Demodulate audio samples into data.
 * 
 * @param samples Input PCM samples (int16)
 * @param sample_count Number of input samples
 * @param out_data Output data buffer
 * @param out_len Input: buffer size, Output: actual bytes written
 * @return 0 on success, -1 on error
 */
int fsk_demodulate(fsk_modem_t *modem, const int16_t *samples, size_t sample_count,
                   uint8_t *out_data, size_t *out_len);

/**
 * Reset modem state.
 */
void fsk_modem_reset(fsk_modem_t *modem);

/**
 * Get modem statistics.
 */
void fsk_modem_get_stats(fsk_modem_t *modem, fsk_stats_t *stats);

#ifdef __cplusplus
}
#endif

#endif // MODEM_FSK_H
