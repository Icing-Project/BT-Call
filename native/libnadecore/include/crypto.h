/**
 * Authenticated Encryption with Associated Data (AEAD)
 * 
 * ChaCha20-Poly1305 encryption for secure audio frames
 */

#ifndef CRYPTO_H
#define CRYPTO_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define CRYPTO_KEY_SIZE 32
#define CRYPTO_NONCE_SIZE 12
#define CRYPTO_TAG_SIZE 16

typedef struct crypto_context crypto_context_t;

/**
 * Create crypto context with session key.
 * 
 * @param key 32-byte encryption key (from handshake)
 * @return Crypto context or NULL on error
 */
crypto_context_t *crypto_create(const uint8_t *key);

/**
 * Destroy crypto context.
 */
void crypto_destroy(crypto_context_t *ctx);

/**
 * Encrypt plaintext with AEAD.
 * 
 * @param ctx Crypto context
 * @param nonce 12-byte nonce (should be incremented per message)
 * @param plaintext Input data to encrypt
 * @param plaintext_len Length of plaintext
 * @param ad Additional authenticated data (can be NULL)
 * @param ad_len Length of AD
 * @param out_ciphertext Output buffer (must fit plaintext_len + CRYPTO_TAG_SIZE)
 * @param out_len Output length (will be plaintext_len + CRYPTO_TAG_SIZE)
 * @return 0 on success, -1 on error
 */
int crypto_encrypt(crypto_context_t *ctx, const uint8_t *nonce,
                   const uint8_t *plaintext, size_t plaintext_len,
                   const uint8_t *ad, size_t ad_len,
                   uint8_t *out_ciphertext, size_t *out_len);

/**
 * Decrypt ciphertext with AEAD.
 * 
 * @param ctx Crypto context
 * @param nonce 12-byte nonce (must match encryption nonce)
 * @param ciphertext Input ciphertext (data + tag)
 * @param ciphertext_len Length of ciphertext (including tag)
 * @param ad Additional authenticated data (must match encryption AD)
 * @param ad_len Length of AD
 * @param out_plaintext Output buffer for decrypted data
 * @param out_len Output length (will be ciphertext_len - CRYPTO_TAG_SIZE)
 * @return 0 on success, -1 on authentication failure
 */
int crypto_decrypt(crypto_context_t *ctx, const uint8_t *nonce,
                   const uint8_t *ciphertext, size_t ciphertext_len,
                   const uint8_t *ad, size_t ad_len,
                   uint8_t *out_plaintext, size_t *out_len);

/**
 * Increment nonce counter (for sequential message encryption).
 * 
 * @param nonce 12-byte nonce to increment
 */
void crypto_increment_nonce(uint8_t *nonce);

#ifdef __cplusplus
}
#endif

#endif // CRYPTO_H
