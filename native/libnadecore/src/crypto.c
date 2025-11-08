/**
 * ChaCha20-Poly1305 AEAD Implementation
 * 
 * Simplified implementation - in production use libsodium or similar
 */

#include "crypto.h"
#include <stdlib.h>
#include <string.h>

// TODO: Replace with libsodium's crypto_aead_chacha20poly1305_ietf_*
// This is a simplified demonstration implementation

struct crypto_context {
    uint8_t key[CRYPTO_KEY_SIZE];
};

// Simplified ChaCha20 quarter round
static void quarter_round(uint32_t *a, uint32_t *b, uint32_t *c, uint32_t *d) {
    *a += *b; *d ^= *a; *d = (*d << 16) | (*d >> 16);
    *c += *d; *b ^= *c; *b = (*b << 12) | (*b >> 20);
    *a += *b; *d ^= *a; *d = (*d << 8) | (*d >> 24);
    *c += *d; *b ^= *c; *b = (*b << 7) | (*b >> 25);
}

// Simplified ChaCha20 block function
static void chacha20_block(const uint8_t key[32], const uint8_t nonce[12],
                           uint32_t counter, uint8_t output[64]) {
    uint32_t state[16];
    
    // Initialize state
    state[0] = 0x61707865; // "expa"
    state[1] = 0x3320646e; // "nd 3"
    state[2] = 0x79622d32; // "2-by"
    state[3] = 0x6b206574; // "te k"
    
    // Key
    for (int i = 0; i < 8; i++) {
        state[4 + i] = ((uint32_t)key[i * 4 + 0] << 0) |
                       ((uint32_t)key[i * 4 + 1] << 8) |
                       ((uint32_t)key[i * 4 + 2] << 16) |
                       ((uint32_t)key[i * 4 + 3] << 24);
    }
    
    // Counter + nonce
    state[12] = counter;
    state[13] = ((uint32_t)nonce[0] << 0) | ((uint32_t)nonce[1] << 8) |
                ((uint32_t)nonce[2] << 16) | ((uint32_t)nonce[3] << 24);
    state[14] = ((uint32_t)nonce[4] << 0) | ((uint32_t)nonce[5] << 8) |
                ((uint32_t)nonce[6] << 16) | ((uint32_t)nonce[7] << 24);
    state[15] = ((uint32_t)nonce[8] << 0) | ((uint32_t)nonce[9] << 8) |
                ((uint32_t)nonce[10] << 16) | ((uint32_t)nonce[11] << 24);
    
    uint32_t working[16];
    memcpy(working, state, sizeof(working));
    
    // 20 rounds (10 double rounds)
    for (int i = 0; i < 10; i++) {
        // Column rounds
        quarter_round(&working[0], &working[4], &working[8], &working[12]);
        quarter_round(&working[1], &working[5], &working[9], &working[13]);
        quarter_round(&working[2], &working[6], &working[10], &working[14]);
        quarter_round(&working[3], &working[7], &working[11], &working[15]);
        
        // Diagonal rounds
        quarter_round(&working[0], &working[5], &working[10], &working[15]);
        quarter_round(&working[1], &working[6], &working[11], &working[12]);
        quarter_round(&working[2], &working[7], &working[8], &working[13]);
        quarter_round(&working[3], &working[4], &working[9], &working[14]);
    }
    
    // Add original state
    for (int i = 0; i < 16; i++) {
        working[i] += state[i];
    }
    
    // Serialize to bytes
    for (int i = 0; i < 16; i++) {
        output[i * 4 + 0] = (working[i] >> 0) & 0xff;
        output[i * 4 + 1] = (working[i] >> 8) & 0xff;
        output[i * 4 + 2] = (working[i] >> 16) & 0xff;
        output[i * 4 + 3] = (working[i] >> 24) & 0xff;
    }
}

// Simplified Poly1305 MAC
static void poly1305_mac(const uint8_t *msg, size_t msg_len,
                         const uint8_t key[32], uint8_t mac[16]) {
    // Simplified: use first 16 bytes of key for demonstration
    // Real Poly1305 uses 256-bit arithmetic
    // TODO: Replace with proper implementation
    
    memset(mac, 0, 16);
    
    for (size_t i = 0; i < msg_len; i++) {
        mac[i % 16] ^= msg[i] ^ key[i % 32];
    }
    
    // Simple mixing
    for (int round = 0; round < 4; round++) {
        for (int i = 0; i < 16; i++) {
            mac[i] = (mac[i] + mac[(i + 1) % 16] + key[(i + round) % 32]) & 0xff;
        }
    }
}

crypto_context_t *crypto_create(const uint8_t *key) {
    if (!key) return NULL;
    
    crypto_context_t *ctx = (crypto_context_t *)malloc(sizeof(crypto_context_t));
    if (!ctx) return NULL;
    
    memcpy(ctx->key, key, CRYPTO_KEY_SIZE);
    
    return ctx;
}

void crypto_destroy(crypto_context_t *ctx) {
    if (ctx) {
        // Zero key material
        memset(ctx->key, 0, CRYPTO_KEY_SIZE);
        free(ctx);
    }
}

int crypto_encrypt(crypto_context_t *ctx, const uint8_t *nonce,
                   const uint8_t *plaintext, size_t plaintext_len,
                   const uint8_t *ad, size_t ad_len,
                   uint8_t *out_ciphertext, size_t *out_len) {
    if (!ctx || !nonce || !plaintext || !out_ciphertext || !out_len) {
        return -1;
    }
    
    // Encrypt with ChaCha20
    size_t num_blocks = (plaintext_len + 63) / 64;
    
    for (size_t block = 0; block < num_blocks; block++) {
        uint8_t keystream[64];
        chacha20_block(ctx->key, nonce, (uint32_t)block, keystream);
        
        size_t offset = block * 64;
        size_t len = (offset + 64 <= plaintext_len) ? 64 : (plaintext_len - offset);
        
        for (size_t i = 0; i < len; i++) {
            out_ciphertext[offset + i] = plaintext[offset + i] ^ keystream[i];
        }
    }
    
    // Compute Poly1305 MAC over AD + ciphertext
    uint8_t mac_input[4096]; // Simplified buffer
    size_t mac_len = 0;
    
    if (ad && ad_len > 0) {
        memcpy(mac_input, ad, ad_len);
        mac_len += ad_len;
    }
    
    memcpy(mac_input + mac_len, out_ciphertext, plaintext_len);
    mac_len += plaintext_len;
    
    // Generate MAC key from ChaCha20
    uint8_t mac_key[32];
    chacha20_block(ctx->key, nonce, 0xFFFFFFFF, mac_key);
    
    poly1305_mac(mac_input, mac_len, mac_key, out_ciphertext + plaintext_len);
    
    *out_len = plaintext_len + CRYPTO_TAG_SIZE;
    
    return 0;
}

int crypto_decrypt(crypto_context_t *ctx, const uint8_t *nonce,
                   const uint8_t *ciphertext, size_t ciphertext_len,
                   const uint8_t *ad, size_t ad_len,
                   uint8_t *out_plaintext, size_t *out_len) {
    if (!ctx || !nonce || !ciphertext || !out_plaintext || !out_len) {
        return -1;
    }
    
    if (ciphertext_len < CRYPTO_TAG_SIZE) {
        return -1;
    }
    
    size_t plaintext_len = ciphertext_len - CRYPTO_TAG_SIZE;
    
    // Verify MAC first
    uint8_t mac_input[4096]; // Simplified buffer
    size_t mac_len = 0;
    
    if (ad && ad_len > 0) {
        memcpy(mac_input, ad, ad_len);
        mac_len += ad_len;
    }
    
    memcpy(mac_input + mac_len, ciphertext, plaintext_len);
    mac_len += plaintext_len;
    
    // Generate MAC key from ChaCha20
    uint8_t mac_key[32];
    chacha20_block(ctx->key, nonce, 0xFFFFFFFF, mac_key);
    
    uint8_t computed_mac[CRYPTO_TAG_SIZE];
    poly1305_mac(mac_input, mac_len, mac_key, computed_mac);
    
    // Constant-time comparison (simplified)
    int mac_valid = 1;
    for (int i = 0; i < CRYPTO_TAG_SIZE; i++) {
        if (computed_mac[i] != ciphertext[plaintext_len + i]) {
            mac_valid = 0;
        }
    }
    
    if (!mac_valid) {
        return -1; // Authentication failed
    }
    
    // Decrypt with ChaCha20
    size_t num_blocks = (plaintext_len + 63) / 64;
    
    for (size_t block = 0; block < num_blocks; block++) {
        uint8_t keystream[64];
        chacha20_block(ctx->key, nonce, (uint32_t)block, keystream);
        
        size_t offset = block * 64;
        size_t len = (offset + 64 <= plaintext_len) ? 64 : (plaintext_len - offset);
        
        for (size_t i = 0; i < len; i++) {
            out_plaintext[offset + i] = ciphertext[offset + i] ^ keystream[i];
        }
    }
    
    *out_len = plaintext_len;
    
    return 0;
}

void crypto_increment_nonce(uint8_t *nonce) {
    if (!nonce) return;
    
    // Increment as little-endian counter
    for (int i = 0; i < CRYPTO_NONCE_SIZE; i++) {
        nonce[i]++;
        if (nonce[i] != 0) break; // No carry
    }
}
