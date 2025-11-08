/**
 * Noise Protocol XK Pattern Handshake Implementation
 * 
 * Implements secure key exchange over audio channel using Noise XK pattern:
 * -> e
 * <- e, ee, s, es  
 * -> s, se
 */

#ifndef HANDSHAKE_H
#define HANDSHAKE_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Handshake states
#define HANDSHAKE_STATE_UNINIT 0
#define HANDSHAKE_STATE_INIT 1
#define HANDSHAKE_STATE_IN_PROGRESS 2
#define HANDSHAKE_STATE_COMPLETE 3
#define HANDSHAKE_STATE_FAILED 4

// Handshake roles
#define HANDSHAKE_ROLE_INITIATOR 0
#define HANDSHAKE_ROLE_RESPONDER 1

// Key sizes
#define HANDSHAKE_KEY_SIZE 32
#define HANDSHAKE_PUBLIC_KEY_SIZE 32
#define HANDSHAKE_PRIVATE_KEY_SIZE 32
#define HANDSHAKE_MAC_SIZE 16

typedef struct handshake_context handshake_context_t;

/**
 * Create a new handshake context.
 * 
 * @param role HANDSHAKE_ROLE_INITIATOR or HANDSHAKE_ROLE_RESPONDER
 * @param identity_keypair_pem PEM-encoded identity keypair
 * @return Handshake context or NULL on error
 */
handshake_context_t *handshake_create(int role, const char *identity_keypair_pem);

/**
 * Destroy handshake context and free resources.
 */
void handshake_destroy(handshake_context_t *ctx);

/**
 * Start handshake as initiator (send first message).
 * 
 * @param ctx Handshake context
 * @param out_message Output buffer for handshake message
 * @param out_len Input: buffer size, Output: actual message size
 * @return 0 on success, -1 on error
 */
int handshake_start(handshake_context_t *ctx, uint8_t *out_message, size_t *out_len);

/**
 * Process received handshake message.
 * 
 * @param ctx Handshake context
 * @param message Received message
 * @param msg_len Message length
 * @param out_response Output buffer for response (if needed)
 * @param out_len Input: buffer size, Output: actual response size (0 if no response)
 * @return 0 on success, -1 on error
 */
int handshake_process_message(handshake_context_t *ctx, 
                               const uint8_t *message, size_t msg_len,
                               uint8_t *out_response, size_t *out_len);

/**
 * Check if handshake is complete.
 * 
 * @return 1 if complete, 0 otherwise
 */
int handshake_is_complete(handshake_context_t *ctx);

/**
 * Get derived session keys after successful handshake.
 * 
 * @param ctx Handshake context
 * @param tx_key Output buffer for transmit key (32 bytes)
 * @param rx_key Output buffer for receive key (32 bytes)
 * @return 0 on success, -1 if handshake not complete
 */
int handshake_get_keys(handshake_context_t *ctx, uint8_t *tx_key, uint8_t *rx_key);

/**
 * Get remote peer's static public key (for verification).
 * 
 * @param ctx Handshake context
 * @param out_pubkey Output buffer for public key (32 bytes)
 * @return 0 on success, -1 on error
 */
int handshake_get_remote_pubkey(handshake_context_t *ctx, uint8_t *out_pubkey);

/**
 * Get local static public key fingerprint.
 * 
 * @param ctx Handshake context
 * @param out_fingerprint Output buffer (64 bytes for hex string)
 * @return 0 on success, -1 on error
 */
int handshake_get_fingerprint(handshake_context_t *ctx, char *out_fingerprint);

/**
 * Reset handshake for retry.
 */
void handshake_reset(handshake_context_t *ctx);

#ifdef __cplusplus
}
#endif

#endif // HANDSHAKE_H
