/**
 * 4-FSK Modem - Modulator and Demodulator
 * 
 * Implements 4-level Frequency Shift Keying for embedding data in audio.
 * Each symbol encodes 2 bits using one of 4 frequencies.
 */

#include "modem_fsk.h"
#include <math.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

// Default configuration
#define DEFAULT_SAMPLE_RATE 16000
#define DEFAULT_SYMBOL_RATE 100.0
#define DEFAULT_FREQ_0 600
#define DEFAULT_FREQ_1 900
#define DEFAULT_FREQ_2 1200
#define DEFAULT_FREQ_3 1500

// Sync pattern (0xNADE = 1011101011011110 in binary, 8 symbols)
static const uint8_t SYNC_PATTERN[] = {0xBA, 0xDE}; // "NADE" in hex
#define SYNC_PATTERN_LEN 2

struct fsk_modem {
    int sample_rate;
    double symbol_rate;
    int samples_per_symbol;
    int frequencies[4]; // f0, f1, f2, f3
    
    // Modulator state
    double mod_phase[4]; // Phase accumulator for each frequency
    
    // Demodulator state
    double *demod_history; // Circular buffer for symbol detection
    int history_len;
    int history_pos;
    
    // Goertzel filter state for each frequency
    double goertzel_coeff[4];
    double goertzel_s1[4];
    double goertzel_s2[4];
    
    // Symbol synchronization
    int symbol_counter;
    int sync_locked;
    double timing_error;
    
    // Statistics
    uint64_t symbols_transmitted;
    uint64_t symbols_received;
    uint64_t sync_losses;
};

// Goertzel algorithm coefficient calculation
static double goertzel_coefficient(int freq, int sample_rate, int block_size) {
    double k = (double)(block_size * freq) / sample_rate;
    return 2.0 * cos(2.0 * M_PI * k / block_size);
}

// Reset Goertzel filter state
static void goertzel_reset(fsk_modem_t *modem) {
    for (int i = 0; i < 4; i++) {
        modem->goertzel_s1[i] = 0.0;
        modem->goertzel_s2[i] = 0.0;
    }
}

// Process one sample through Goertzel filter
static void goertzel_process_sample(fsk_modem_t *modem, double sample) {
    for (int i = 0; i < 4; i++) {
        double s0 = sample + modem->goertzel_coeff[i] * modem->goertzel_s1[i] - modem->goertzel_s2[i];
        modem->goertzel_s2[i] = modem->goertzel_s1[i];
        modem->goertzel_s1[i] = s0;
    }
}

// Get magnitude for each frequency
static void goertzel_get_magnitudes(fsk_modem_t *modem, double *mags) {
    for (int i = 0; i < 4; i++) {
        double real = modem->goertzel_s1[i] - modem->goertzel_s2[i] * cos(2.0 * M_PI * i / 4);
        double imag = modem->goertzel_s2[i] * sin(2.0 * M_PI * i / 4);
        mags[i] = real * real + imag * imag; // Power (magnitude squared)
    }
}

fsk_modem_t *fsk_modem_create(const fsk_config_t *config) {
    fsk_modem_t *modem = (fsk_modem_t *)calloc(1, sizeof(fsk_modem_t));
    if (!modem) return NULL;
    
    modem->sample_rate = config ? config->sample_rate : DEFAULT_SAMPLE_RATE;
    modem->symbol_rate = config ? config->symbol_rate : DEFAULT_SYMBOL_RATE;
    modem->samples_per_symbol = (int)(modem->sample_rate / modem->symbol_rate);
    
    if (config && config->frequencies[0] > 0) {
        memcpy(modem->frequencies, config->frequencies, sizeof(modem->frequencies));
    } else {
        modem->frequencies[0] = DEFAULT_FREQ_0;
        modem->frequencies[1] = DEFAULT_FREQ_1;
        modem->frequencies[2] = DEFAULT_FREQ_2;
        modem->frequencies[3] = DEFAULT_FREQ_3;
    }
    
    // Initialize phase accumulators
    for (int i = 0; i < 4; i++) {
        modem->mod_phase[i] = 0.0;
    }
    
    // Initialize Goertzel coefficients
    for (int i = 0; i < 4; i++) {
        modem->goertzel_coeff[i] = goertzel_coefficient(
            modem->frequencies[i],
            modem->sample_rate,
            modem->samples_per_symbol
        );
    }
    
    // Allocate demodulator history buffer (2 symbols worth)
    modem->history_len = modem->samples_per_symbol * 2;
    modem->demod_history = (double *)calloc(modem->history_len, sizeof(double));
    modem->history_pos = 0;
    
    modem->sync_locked = 0;
    modem->timing_error = 0.0;
    
    return modem;
}

void fsk_modem_destroy(fsk_modem_t *modem) {
    if (modem) {
        free(modem->demod_history);
        free(modem);
    }
}

// Modulate data into audio samples
int fsk_modulate(fsk_modem_t *modem, const uint8_t *data, size_t data_len,
                 int16_t *out_samples, size_t *out_len) {
    if (!modem || !data || !out_samples || !out_len) return -1;
    
    // Add sync pattern
    size_t total_bytes = SYNC_PATTERN_LEN + data_len;
    size_t symbol_count = total_bytes * 4; // 4 symbols per byte (2 bits each)
    size_t sample_count = symbol_count * modem->samples_per_symbol;
    
    if (*out_len < sample_count) {
        *out_len = sample_count;
        return -1; // Buffer too small
    }
    
    size_t sample_idx = 0;
    
    // Helper function to modulate one symbol
    auto modulate_symbol = [&](uint8_t symbol) {
        int freq_idx = symbol & 0x03; // 2 bits -> 0-3
        double freq = modem->frequencies[freq_idx];
        double phase_inc = 2.0 * M_PI * freq / modem->sample_rate;
        
        // Generate samples for this symbol with raised cosine envelope to reduce clicks
        for (int i = 0; i < modem->samples_per_symbol; i++) {
            double t = (double)i / modem->samples_per_symbol;
            double envelope = 0.5 * (1.0 - cos(2.0 * M_PI * t)); // Raised cosine
            
            double sample = sin(modem->mod_phase[freq_idx]) * envelope;
            modem->mod_phase[freq_idx] += phase_inc;
            
            // Normalize phase to avoid overflow
            if (modem->mod_phase[freq_idx] > 2.0 * M_PI) {
                modem->mod_phase[freq_idx] -= 2.0 * M_PI;
            }
            
            // Convert to int16 (scale to 80% to avoid clipping)
            out_samples[sample_idx++] = (int16_t)(sample * 32767.0 * 0.8);
        }
        
        modem->symbols_transmitted++;
    };
    
    // Modulate sync pattern
    for (size_t i = 0; i < SYNC_PATTERN_LEN; i++) {
        uint8_t byte = SYNC_PATTERN[i];
        modulate_symbol((byte >> 6) & 0x03);
        modulate_symbol((byte >> 4) & 0x03);
        modulate_symbol((byte >> 2) & 0x03);
        modulate_symbol(byte & 0x03);
    }
    
    // Modulate data
    for (size_t i = 0; i < data_len; i++) {
        uint8_t byte = data[i];
        modulate_symbol((byte >> 6) & 0x03);
        modulate_symbol((byte >> 4) & 0x03);
        modulate_symbol((byte >> 2) & 0x03);
        modulate_symbol(byte & 0x03);
    }
    
    *out_len = sample_count;
    return 0;
}

// Demodulate audio samples into data
int fsk_demodulate(fsk_modem_t *modem, const int16_t *samples, size_t sample_count,
                   uint8_t *out_data, size_t *out_len) {
    if (!modem || !samples || !out_data || !out_len) return -1;
    
    size_t max_output = *out_len;
    size_t output_idx = 0;
    uint8_t current_byte = 0;
    int bits_in_byte = 0;
    
    int samples_processed = 0;
    
    while (samples_processed < sample_count) {
        // Collect one symbol worth of samples
        int samples_to_process = modem->samples_per_symbol;
        if (samples_processed + samples_to_process > sample_count) {
            samples_to_process = sample_count - samples_processed;
        }
        
        // Reset Goertzel filters
        goertzel_reset(modem);
        
        // Process samples through Goertzel
        for (int i = 0; i < samples_to_process; i++) {
            double sample = samples[samples_processed + i] / 32768.0;
            goertzel_process_sample(modem, sample);
        }
        
        samples_processed += samples_to_process;
        
        // Get frequency magnitudes
        double mags[4];
        goertzel_get_magnitudes(modem, mags);
        
        // Find maximum (detected symbol)
        int max_idx = 0;
        double max_mag = mags[0];
        for (int i = 1; i < 4; i++) {
            if (mags[i] > max_mag) {
                max_mag = mags[i];
                max_idx = i;
            }
        }
        
        // Accumulate bits
        current_byte = (current_byte << 2) | (max_idx & 0x03);
        bits_in_byte += 2;
        
        if (bits_in_byte == 8) {
            if (output_idx < max_output) {
                out_data[output_idx++] = current_byte;
            }
            current_byte = 0;
            bits_in_byte = 0;
        }
        
        modem->symbols_received++;
    }
    
    *out_len = output_idx;
    
    // TODO: Implement sync detection and remove sync pattern from output
    // For now, caller must handle sync pattern
    
    return 0;
}

void fsk_modem_reset(fsk_modem_t *modem) {
    if (!modem) return;
    
    for (int i = 0; i < 4; i++) {
        modem->mod_phase[i] = 0.0;
    }
    
    goertzel_reset(modem);
    modem->history_pos = 0;
    modem->sync_locked = 0;
    modem->timing_error = 0.0;
    modem->symbol_counter = 0;
}

void fsk_modem_get_stats(fsk_modem_t *modem, fsk_stats_t *stats) {
    if (!modem || !stats) return;
    
    stats->symbols_transmitted = modem->symbols_transmitted;
    stats->symbols_received = modem->symbols_received;
    stats->sync_locked = modem->sync_locked;
    stats->timing_error = modem->timing_error;
    stats->sync_losses = modem->sync_losses;
}
