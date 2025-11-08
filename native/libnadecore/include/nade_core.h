/**
 * NADE Core - Native library for Noise-encrypted Audio Data Exchange
 * 
 * This library provides:
 * - Noise XK handshake over audio channel
 * - Codec2 voice compression
 * - Reed-Solomon FEC
 * - ChaCha20-Poly1305 AEAD encryption
 * - 4-FSK modulation/demodulation
 */

#ifndef NADE_CORE_H
#define NADE_CORE_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Platform-specific export macros
#ifdef _WIN32
  #ifdef NADE_EXPORTS
    #define NADE_API __declspec(dllexport)
  #else
    #define NADE_API __declspec(dllimport)
  #endif
#else
  #define NADE_API __attribute__((visibility("default")))
#endif

// Return codes
#define NADE_OK 0
#define NADE_ERROR -1
#define NADE_ERROR_NOT_INITIALIZED -2
#define NADE_ERROR_ALREADY_INITIALIZED -3
#define NADE_ERROR_INVALID_PARAM -4
#define NADE_ERROR_HANDSHAKE_FAILED -5
#define NADE_ERROR_CRYPTO_FAILED -6
#define NADE_ERROR_NO_SESSION -7
#define NADE_ERROR_BUFFER_TOO_SMALL -8

// Session states
#define NADE_STATE_IDLE 0
#define NADE_STATE_HANDSHAKING 1
#define NADE_STATE_ESTABLISHED 2
#define NADE_STATE_ERROR 3

// Event types for callbacks
#define NADE_EVENT_HANDSHAKE_STARTED 1
#define NADE_EVENT_HANDSHAKE_SUCCESS 2
#define NADE_EVENT_HANDSHAKE_FAILED 3
#define NADE_EVENT_SESSION_ESTABLISHED 4
#define NADE_EVENT_SESSION_CLOSED 5
#define NADE_EVENT_FEC_CORRECTION 6
#define NADE_EVENT_SYNC_LOST 7
#define NADE_EVENT_SYNC_ACQUIRED 8
#define NADE_EVENT_REMOTE_NOT_NADE 9
#define NADE_EVENT_LOG 10
#define NADE_EVENT_ERROR 11

// Event callback
typedef void (*nade_event_callback_t)(int event_type, const char* message, void* user_data);

/**
 * Initialize NADE core with identity keypair and configuration.
 * 
 * @param identity_keypair_pem PEM-encoded identity keypair for Noise protocol
 * @param config_json JSON configuration string (can be NULL for defaults)
 * @return NADE_OK on success, error code otherwise
 */
NADE_API int nade_init(const char* identity_keypair_pem, const char* config_json);

/**
 * Shutdown NADE core and free all resources.
 * 
 * @return NADE_OK on success
 */
NADE_API int nade_shutdown(void);

/**
 * Start a NADE session with a peer.
 * 
 * @param peer_id Identifier for the remote peer (phone number, device ID, etc.)
 * @param transport Transport type: "bluetooth", "audio_loopback", "wasapi", "sco"
 * @return NADE_OK on success, error code otherwise
 */
NADE_API int nade_start_session(const char* peer_id, const char* transport);

/**
 * Stop the current NADE session.
 * 
 * @return NADE_OK on success
 */
NADE_API int nade_stop_session(void);

/**
 * Feed captured microphone PCM samples to NADE for processing and transmission.
 * Input is processed through: Codec2 -> FEC -> AEAD -> 4-FSK modulation
 * 
 * @param pcm_samples Input PCM samples (int16, mono)
 * @param sample_count Number of samples
 * @return NADE_OK on success, error code otherwise
 */
NADE_API int nade_feed_mic_frame(const int16_t* pcm_samples, size_t sample_count);

/**
 * Pull rendered/decoded PCM samples from NADE for speaker playback.
 * Output has been: demodulated -> AEAD decrypted -> FEC decoded -> Codec2 decoded
 * 
 * @param out_pcm_buf Output buffer for PCM samples (int16, mono)
 * @param max_samples Maximum samples the buffer can hold
 * @param samples_read Pointer to store actual number of samples written
 * @return NADE_OK on success, error code otherwise
 */
NADE_API int nade_pull_speaker_frame(int16_t* out_pcm_buf, size_t max_samples, size_t* samples_read);

/**
 * Get modulated audio that should be sent to the audio output (Bluetooth/speaker).
 * This is the FSK-modulated encrypted data.
 * 
 * @param out_pcm_buf Output buffer for modulated PCM
 * @param max_samples Maximum samples the buffer can hold
 * @param samples_read Pointer to store actual number of samples written
 * @return NADE_OK on success, error code otherwise
 */
NADE_API int nade_get_modulated_output(int16_t* out_pcm_buf, size_t max_samples, size_t* samples_read);

/**
 * Process incoming audio from remote peer (Bluetooth/microphone input).
 * This demodulates FSK, decrypts, and decodes the voice.
 * 
 * @param pcm_samples Incoming PCM samples from remote
 * @param sample_count Number of samples
 * @return NADE_OK on success, error code otherwise
 */
NADE_API int nade_process_remote_input(const int16_t* pcm_samples, size_t sample_count);

/**
 * Update NADE configuration dynamically.
 * 
 * @param config_json JSON configuration string
 * @return NADE_OK on success, error code otherwise
 */
NADE_API int nade_set_config(const char* config_json);

/**
 * Get current NADE status and statistics.
 * 
 * @param out_json_buf Output buffer for JSON status
 * @param buf_size Size of output buffer
 * @return NADE_OK on success, error code otherwise
 */
NADE_API int nade_get_status(char* out_json_buf, size_t buf_size);

/**
 * Set event callback for NADE events.
 * 
 * @param callback Callback function pointer
 * @param user_data User data passed to callback
 * @return NADE_OK on success
 */
NADE_API int nade_set_event_callback(nade_event_callback_t callback, void* user_data);

/**
 * Check if a peer is NADE-capable (send capability ping).
 * This is an async operation; result comes via event callback.
 * 
 * @param peer_id Peer identifier
 * @return NADE_OK if ping sent successfully
 */
NADE_API int nade_ping_capability(const char* peer_id);

/**
 * Get version string.
 * 
 * @return Version string (e.g., "0.1.0")
 */
NADE_API const char* nade_get_version(void);

#ifdef __cplusplus
}
#endif

#endif // NADE_CORE_H
