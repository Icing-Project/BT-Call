/**
 * NADE Core Implementation
 * Main entry point and session management
 */

#include "nade_core.h"
#include "modem_fsk.h"
#include "handshake.h"
#include "codec.h"
#include "fec.h"
#include "crypto.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <pthread.h>

#define NADE_VERSION "0.1.0"
#define MAX_FRAME_SIZE 4096
#define MIC_BUFFER_SIZE 8192
#define SPEAKER_BUFFER_SIZE 8192

// Session state
typedef struct {
    char peer_id[256];
    char transport[64];
    int state; // NADE_STATE_*
    
    // Crypto components
    handshake_context_t *handshake;
    codec_context_t *codec;
    fec_context_t *fec;
    crypto_context_t *crypto;
    
    uint8_t session_key[32];
    uint8_t nonce[12];
    int handshake_complete;
    
    // Audio buffers
    int16_t mic_buffer[MIC_BUFFER_SIZE];
    size_t mic_buffer_len;
    
    int16_t speaker_buffer[SPEAKER_BUFFER_SIZE];
    size_t speaker_buffer_len;
    size_t speaker_buffer_pos;
    
    int16_t modulated_output[MIC_BUFFER_SIZE * 4]; // Modulated data
    size_t modulated_output_len;
    size_t modulated_output_pos;
    
    // Statistics
    uint64_t frames_sent;
    uint64_t frames_received;
    uint64_t fec_corrections;
} nade_session_t;

// Global state
static struct {
    int initialized;
    char identity_keypair_pem[8192];
    
    // Configuration
    int sample_rate;
    double symbol_rate;
    int frequencies[4];
    int fec_strength;
    int codec_mode;
    int debug_logging;
    int handshake_timeout_ms;
    int max_handshake_retries;
    
    // FSK modem
    fsk_modem_t *modem;
    
    // Session
    nade_session_t *session;
    pthread_mutex_t session_mutex;
    
    // Event callback
    nade_event_callback_t event_callback;
    void *event_user_data;
} g_nade = {0};

// Forward declarations
static void emit_event(int event_type, const char *message);
static int parse_config_json(const char *config_json);

// Emit event to callback
static void emit_event(int event_type, const char *message) {
    if (g_nade.event_callback) {
        g_nade.event_callback(event_type, message, g_nade.event_user_data);
    }
    
    if (g_nade.debug_logging) {
        const char *event_name = "UNKNOWN";
        switch (event_type) {
            case NADE_EVENT_HANDSHAKE_STARTED: event_name = "HANDSHAKE_STARTED"; break;
            case NADE_EVENT_HANDSHAKE_SUCCESS: event_name = "HANDSHAKE_SUCCESS"; break;
            case NADE_EVENT_HANDSHAKE_FAILED: event_name = "HANDSHAKE_FAILED"; break;
            case NADE_EVENT_SESSION_ESTABLISHED: event_name = "SESSION_ESTABLISHED"; break;
            case NADE_EVENT_SESSION_CLOSED: event_name = "SESSION_CLOSED"; break;
            case NADE_EVENT_FEC_CORRECTION: event_name = "FEC_CORRECTION"; break;
            case NADE_EVENT_SYNC_LOST: event_name = "SYNC_LOST"; break;
            case NADE_EVENT_SYNC_ACQUIRED: event_name = "SYNC_ACQUIRED"; break;
            case NADE_EVENT_REMOTE_NOT_NADE: event_name = "REMOTE_NOT_NADE"; break;
            case NADE_EVENT_ERROR: event_name = "ERROR"; break;
        }
        fprintf(stderr, "[NADE] Event: %s - %s\n", event_name, message);
    }
}

// Parse JSON configuration
static int parse_config_json(const char *config_json) {
    if (!config_json || strlen(config_json) == 0) {
        // Use defaults
        g_nade.sample_rate = 16000;
        g_nade.symbol_rate = 100.0;
        g_nade.frequencies[0] = 600;
        g_nade.frequencies[1] = 900;
        g_nade.frequencies[2] = 1200;
        g_nade.frequencies[3] = 1500;
        g_nade.fec_strength = 32;
        g_nade.codec_mode = 1400;
        g_nade.debug_logging = 0;
        g_nade.handshake_timeout_ms = 10000;
        g_nade.max_handshake_retries = 5;
        return NADE_OK;
    }
    
    // TODO: Proper JSON parsing (for now, use defaults)
    // In production, use a JSON library like cJSON or jsmn
    return NADE_OK;
}

NADE_API int nade_init(const char *identity_keypair_pem, const char *config_json) {
    if (g_nade.initialized) {
        return NADE_ERROR_ALREADY_INITIALIZED;
    }
    
    if (!identity_keypair_pem || strlen(identity_keypair_pem) == 0) {
        return NADE_ERROR_INVALID_PARAM;
    }
    
    // Store identity keypair
    strncpy(g_nade.identity_keypair_pem, identity_keypair_pem, sizeof(g_nade.identity_keypair_pem) - 1);
    
    // Parse configuration
    if (parse_config_json(config_json) != NADE_OK) {
        return NADE_ERROR_INVALID_PARAM;
    }
    
    // Initialize mutex
    pthread_mutex_init(&g_nade.session_mutex, NULL);
    
    // Create FSK modem
    fsk_config_t fsk_config = {
        .sample_rate = g_nade.sample_rate,
        .symbol_rate = g_nade.symbol_rate,
        .frequencies = {
            g_nade.frequencies[0],
            g_nade.frequencies[1],
            g_nade.frequencies[2],
            g_nade.frequencies[3]
        }
    };
    
    g_nade.modem = fsk_modem_create(&fsk_config);
    if (!g_nade.modem) {
        return NADE_ERROR;
    }
    
    g_nade.initialized = 1;
    emit_event(NADE_EVENT_LOG, "NADE core initialized");
    
    return NADE_OK;
}

NADE_API int nade_shutdown(void) {
    if (!g_nade.initialized) {
        return NADE_OK;
    }
    
    // Stop any active session
    nade_stop_session();
    
    // Destroy modem
    if (g_nade.modem) {
        fsk_modem_destroy(g_nade.modem);
        g_nade.modem = NULL;
    }
    
    pthread_mutex_destroy(&g_nade.session_mutex);
    
    g_nade.initialized = 0;
    emit_event(NADE_EVENT_LOG, "NADE core shutdown");
    
    return NADE_OK;
}

NADE_API int nade_start_session(const char *peer_id, const char *transport) {
    if (!g_nade.initialized) {
        return NADE_ERROR_NOT_INITIALIZED;
    }
    
    if (!peer_id || !transport) {
        return NADE_ERROR_INVALID_PARAM;
    }
    
    pthread_mutex_lock(&g_nade.session_mutex);
    
    // Check if session already exists
    if (g_nade.session) {
        pthread_mutex_unlock(&g_nade.session_mutex);
        return NADE_ERROR;
    }
    
    // Create new session
    g_nade.session = (nade_session_t *)calloc(1, sizeof(nade_session_t));
    if (!g_nade.session) {
        pthread_mutex_unlock(&g_nade.session_mutex);
        return NADE_ERROR;
    }
    
    strncpy(g_nade.session->peer_id, peer_id, sizeof(g_nade.session->peer_id) - 1);
    strncpy(g_nade.session->transport, transport, sizeof(g_nade.session->transport) - 1);
    g_nade.session->state = NADE_STATE_HANDSHAKING;
    
    // Initialize crypto components
    g_nade.session->handshake = handshake_create(1); // 1 = initiator
    g_nade.session->codec = codec_create(g_nade.codec_mode);
    g_nade.session->fec = fec_create(FEC_RS_255_223);
    
    // Crypto context will be created after handshake completes
    g_nade.session->crypto = NULL;
    
    memset(g_nade.session->nonce, 0, sizeof(g_nade.session->nonce));
    
    pthread_mutex_unlock(&g_nade.session_mutex);
    
    emit_event(NADE_EVENT_HANDSHAKE_STARTED, "Starting Noise XK handshake");
    
    // TODO: Start actual Noise XK handshake
    // For now, simulate immediate success with a dummy session key
    memset(g_nade.session->session_key, 0x42, 32);
    g_nade.session->crypto = crypto_create(g_nade.session->session_key);
    g_nade.session->handshake_complete = 1;
    g_nade.session->state = NADE_STATE_ESTABLISHED;
    
    emit_event(NADE_EVENT_HANDSHAKE_SUCCESS, "Handshake completed");
    emit_event(NADE_EVENT_SESSION_ESTABLISHED, "Session established");
    
    return NADE_OK;
}

NADE_API int nade_stop_session(void) {
    if (!g_nade.initialized) {
        return NADE_ERROR_NOT_INITIALIZED;
    }
    
    pthread_mutex_lock(&g_nade.session_mutex);
    
    if (g_nade.session) {
        // Clean up crypto components
        if (g_nade.session->handshake) handshake_destroy(g_nade.session->handshake);
        if (g_nade.session->codec) codec_destroy(g_nade.session->codec);
        if (g_nade.session->fec) fec_destroy(g_nade.session->fec);
        if (g_nade.session->crypto) crypto_destroy(g_nade.session->crypto);
        
        free(g_nade.session);
        g_nade.session = NULL;
        emit_event(NADE_EVENT_SESSION_CLOSED, "Session stopped");
    }
    
    pthread_mutex_unlock(&g_nade.session_mutex);
    
    return NADE_OK;
}

NADE_API int nade_feed_mic_frame(const int16_t *pcm_samples, size_t sample_count) {
    if (!g_nade.initialized) return NADE_ERROR_NOT_INITIALIZED;
    if (!pcm_samples || sample_count == 0) return NADE_ERROR_INVALID_PARAM;
    
    pthread_mutex_lock(&g_nade.session_mutex);
    
    if (!g_nade.session || g_nade.session->state != NADE_STATE_ESTABLISHED) {
        pthread_mutex_unlock(&g_nade.session_mutex);
        return NADE_ERROR_NO_SESSION;
    }
    
    // Full pipeline: PCM → Codec2 → FEC → Crypto → FSK
    
    // 1. Encode voice with Codec2
    uint8_t codec_bits[256];
    size_t codec_bits_len = sizeof(codec_bits);
    if (codec_encode(g_nade.session->codec, pcm_samples, sample_count,
                     codec_bits, &codec_bits_len) != 0) {
        pthread_mutex_unlock(&g_nade.session_mutex);
        return NADE_ERROR;
    }
    
    // 2. Apply FEC (Reed-Solomon)
    uint8_t fec_encoded[512];
    size_t fec_len = sizeof(fec_encoded);
    if (fec_encode(g_nade.session->fec, codec_bits, codec_bits_len,
                   fec_encoded, &fec_len) != 0) {
        pthread_mutex_unlock(&g_nade.session_mutex);
        return NADE_ERROR;
    }
    
    // 3. Encrypt with ChaCha20-Poly1305
    uint8_t encrypted[1024];
    size_t encrypted_len = sizeof(encrypted);
    if (crypto_encrypt(g_nade.session->crypto, g_nade.session->nonce,
                       fec_encoded, fec_len, NULL, 0,
                       encrypted, &encrypted_len) != 0) {
        pthread_mutex_unlock(&g_nade.session_mutex);
        return NADE_ERROR;
    }
    
    // Increment nonce for next message
    crypto_increment_nonce(g_nade.session->nonce);
    
    // 4. Modulate with 4-FSK
    size_t out_len = sizeof(g_nade.session->modulated_output);
    if (fsk_modulate(g_nade.modem, encrypted, encrypted_len,
                     g_nade.session->modulated_output, &out_len) == 0) {
        g_nade.session->modulated_output_len = out_len;
        g_nade.session->modulated_output_pos = 0;
        g_nade.session->frames_sent++;
    }
    
    pthread_mutex_unlock(&g_nade.session_mutex);
    
    return NADE_OK;
}

NADE_API int nade_get_modulated_output(int16_t *out_pcm_buf, size_t max_samples, size_t *samples_read) {
    if (!g_nade.initialized) return NADE_ERROR_NOT_INITIALIZED;
    if (!out_pcm_buf || !samples_read) return NADE_ERROR_INVALID_PARAM;
    
    pthread_mutex_lock(&g_nade.session_mutex);
    
    if (!g_nade.session) {
        *samples_read = 0;
        pthread_mutex_unlock(&g_nade.session_mutex);
        return NADE_OK;
    }
    
    size_t available = g_nade.session->modulated_output_len - g_nade.session->modulated_output_pos;
    size_t to_copy = (available < max_samples) ? available : max_samples;
    
    if (to_copy > 0) {
        memcpy(out_pcm_buf,
               g_nade.session->modulated_output + g_nade.session->modulated_output_pos,
               to_copy * sizeof(int16_t));
        g_nade.session->modulated_output_pos += to_copy;
    }
    
    *samples_read = to_copy;
    
    pthread_mutex_unlock(&g_nade.session_mutex);
    
    return NADE_OK;
}

NADE_API int nade_process_remote_input(const int16_t *pcm_samples, size_t sample_count) {
    if (!g_nade.initialized) return NADE_ERROR_NOT_INITIALIZED;
    if (!pcm_samples || sample_count == 0) return NADE_ERROR_INVALID_PARAM;
    
    pthread_mutex_lock(&g_nade.session_mutex);
    
    if (!g_nade.session || g_nade.session->state != NADE_STATE_ESTABLISHED) {
        pthread_mutex_unlock(&g_nade.session_mutex);
        return NADE_ERROR_NO_SESSION;
    }
    
    // Full pipeline: FSK → Crypto → FEC → Codec2 → PCM
    
    // 1. Demodulate FSK symbols
    uint8_t demod_data[1024];
    size_t demod_len = sizeof(demod_data);
    if (fsk_demodulate(g_nade.modem, pcm_samples, sample_count, demod_data, &demod_len) != 0) {
        pthread_mutex_unlock(&g_nade.session_mutex);
        return NADE_ERROR;
    }
    
    // 2. Decrypt with ChaCha20-Poly1305
    uint8_t decrypted[512];
    size_t decrypted_len = sizeof(decrypted);
    
    // Note: nonce must match sender's nonce (typically frame counter)
    // For now using our local nonce counter
    if (crypto_decrypt(g_nade.session->crypto, g_nade.session->nonce,
                       demod_data, demod_len, NULL, 0,
                       decrypted, &decrypted_len) != 0) {
        pthread_mutex_unlock(&g_nade.session_mutex);
        emit_event(NADE_EVENT_ERROR, "Decryption failed");
        return NADE_ERROR;
    }
    
    // 3. Apply FEC decoding (error correction)
    uint8_t fec_decoded[256];
    size_t fec_decoded_len = sizeof(fec_decoded);
    int errors_corrected = fec_decode(g_nade.session->fec, decrypted, decrypted_len,
                                       fec_decoded, &fec_decoded_len);
    
    if (errors_corrected < 0) {
        pthread_mutex_unlock(&g_nade.session_mutex);
        emit_event(NADE_EVENT_ERROR, "Uncorrectable FEC errors");
        return NADE_ERROR;
    }
    
    if (errors_corrected > 0) {
        g_nade.session->fec_corrections += errors_corrected;
        emit_event(NADE_EVENT_FEC_CORRECTION, "FEC corrected errors");
    }
    
    // 4. Decode with Codec2
    size_t decoded_samples = sizeof(g_nade.session->speaker_buffer);
    if (codec_decode(g_nade.session->codec, fec_decoded, fec_decoded_len,
                     g_nade.session->speaker_buffer, &decoded_samples) != 0) {
        pthread_mutex_unlock(&g_nade.session_mutex);
        return NADE_ERROR;
    }
    
    g_nade.session->speaker_buffer_len = decoded_samples;
    g_nade.session->speaker_buffer_pos = 0;
    g_nade.session->frames_received++;
    
    pthread_mutex_unlock(&g_nade.session_mutex);
    
    return NADE_OK;
}

NADE_API int nade_pull_speaker_frame(int16_t *out_pcm_buf, size_t max_samples, size_t *samples_read) {
    if (!g_nade.initialized) return NADE_ERROR_NOT_INITIALIZED;
    if (!out_pcm_buf || !samples_read) return NADE_ERROR_INVALID_PARAM;
    
    pthread_mutex_lock(&g_nade.session_mutex);
    
    if (!g_nade.session) {
        *samples_read = 0;
        pthread_mutex_unlock(&g_nade.session_mutex);
        return NADE_OK;
    }
    
    // Return decoded voice PCM from speaker buffer
    size_t available = g_nade.session->speaker_buffer_len - g_nade.session->speaker_buffer_pos;
    size_t to_copy = (available < max_samples) ? available : max_samples;
    
    if (to_copy > 0) {
        memcpy(out_pcm_buf,
               g_nade.session->speaker_buffer + g_nade.session->speaker_buffer_pos,
               to_copy * sizeof(int16_t));
        g_nade.session->speaker_buffer_pos += to_copy;
    } else {
        // No data available, return silence
        memset(out_pcm_buf, 0, max_samples * sizeof(int16_t));
        to_copy = max_samples;
    }
    
    *samples_read = to_copy;
    
    pthread_mutex_unlock(&g_nade.session_mutex);
    
    return NADE_OK;
}

NADE_API int nade_set_config(const char *config_json) {
    if (!g_nade.initialized) return NADE_ERROR_NOT_INITIALIZED;
    
    return parse_config_json(config_json);
}

NADE_API int nade_get_status(char *out_json_buf, size_t buf_size) {
    if (!g_nade.initialized) return NADE_ERROR_NOT_INITIALIZED;
    if (!out_json_buf || buf_size == 0) return NADE_ERROR_INVALID_PARAM;
    
    pthread_mutex_lock(&g_nade.session_mutex);
    
    int state = g_nade.session ? g_nade.session->state : NADE_STATE_IDLE;
    int handshake_complete = g_nade.session ? g_nade.session->handshake_complete : 0;
    uint64_t frames_sent = g_nade.session ? g_nade.session->frames_sent : 0;
    uint64_t frames_received = g_nade.session ? g_nade.session->frames_received : 0;
    
    pthread_mutex_unlock(&g_nade.session_mutex);
    
    snprintf(out_json_buf, buf_size,
             "{\"state\":%d,\"handshake_complete\":%d,\"frames_sent\":%llu,\"frames_received\":%llu}",
             state, handshake_complete, (unsigned long long)frames_sent, (unsigned long long)frames_received);
    
    return NADE_OK;
}

NADE_API int nade_set_event_callback(nade_event_callback_t callback, void *user_data) {
    g_nade.event_callback = callback;
    g_nade.event_user_data = user_data;
    return NADE_OK;
}

NADE_API int nade_ping_capability(const char *peer_id) {
    // TODO: Send capability ping frame
    emit_event(NADE_EVENT_LOG, "Capability ping not yet implemented");
    return NADE_OK;
}

NADE_API const char *nade_get_version(void) {
    return NADE_VERSION;
}
