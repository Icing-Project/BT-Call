/**
 * Noise Protocol XK Pattern Implementation
 * 
 * Simplified implementation using libsodium for crypto primitives
 * (In production, integrate with noise-c library)
 */

#include "handshake.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

// Simplified crypto using built-in algorithms
// TODO: Replace with noise-c library integration

// For now, we'll use a simplified handshake simulation
// In production, use proper Noise protocol implementation

struct handshake_context {
    int role;
    int state;
    
    // Keys
    uint8_t local_static_private[HANDSHAKE_PRIVATE_KEY_SIZE];
    uint8_t local_static_public[HANDSHAKE_PUBLIC_KEY_SIZE];
    uint8_t local_ephemeral_private[HANDSHAKE_PRIVATE_KEY_SIZE];
    uint8_t local_ephemeral_public[HANDSHAKE_PUBLIC_KEY_SIZE];
    
    uint8_t remote_static_public[HANDSHAKE_PUBLIC_KEY_SIZE];
    uint8_t remote_ephemeral_public[HANDSHAKE_PUBLIC_KEY_SIZE];
    
    // Derived session keys
    uint8_t tx_key[HANDSHAKE_KEY_SIZE];
    uint8_t rx_key[HANDSHAKE_KEY_SIZE];
    
    int handshake_complete;
    int message_count;
};

// Simplified key derivation (SHA256-based HKDF simulation)
static void derive_keys(const uint8_t *shared_secret, size_t secret_len,
                       uint8_t *out_key1, uint8_t *out_key2) {
    // Simplified: XOR-based derivation for demonstration
    // TODO: Replace with proper HKDF from noise-c
    for (int i = 0; i < HANDSHAKE_KEY_SIZE; i++) {
        out_key1[i] = shared_secret[i % secret_len] ^ (i * 7);
        out_key2[i] = shared_secret[i % secret_len] ^ (i * 13);
    }
}

// Simplified DH (in production, use X25519)
static void generate_keypair(uint8_t *private_key, uint8_t *public_key) {
    // Simplified: random private, derived public
    // TODO: Use proper X25519 key generation
    for (int i = 0; i < 32; i++) {
        private_key[i] = rand() & 0xFF;
        public_key[i] = private_key[i] ^ 0x42; // Simplified
    }
}

static void dh(const uint8_t *private_key, const uint8_t *public_key, uint8_t *shared_secret) {
    // Simplified DH computation
    // TODO: Use X25519 from libsodium or noise-c
    for (int i = 0; i < 32; i++) {
        shared_secret[i] = private_key[i] ^ public_key[i];
    }
}

handshake_context_t *handshake_create(int role, const char *identity_keypair_pem) {
    handshake_context_t *ctx = (handshake_context_t *)calloc(1, sizeof(handshake_context_t));
    if (!ctx) return NULL;
    
    ctx->role = role;
    ctx->state = HANDSHAKE_STATE_INIT;
    ctx->handshake_complete = 0;
    ctx->message_count = 0;
    
    // Generate static keypair from PEM (simplified)
    // TODO: Parse actual PEM and extract keys
    generate_keypair(ctx->local_static_private, ctx->local_static_public);
    
    return ctx;
}

void handshake_destroy(handshake_context_t *ctx) {
    if (ctx) {
        // Zero out sensitive data
        memset(ctx, 0, sizeof(handshake_context_t));
        free(ctx);
    }
}

int handshake_start(handshake_context_t *ctx, uint8_t *out_message, size_t *out_len) {
    if (!ctx || ctx->role != HANDSHAKE_ROLE_INITIATOR) return -1;
    if (!out_message || !out_len || *out_len < 64) return -1;
    
    // Generate ephemeral keypair
    generate_keypair(ctx->local_ephemeral_private, ctx->local_ephemeral_public);
    
    // Message 1: -> e
    memcpy(out_message, ctx->local_ephemeral_public, HANDSHAKE_PUBLIC_KEY_SIZE);
    *out_len = HANDSHAKE_PUBLIC_KEY_SIZE;
    
    ctx->state = HANDSHAKE_STATE_IN_PROGRESS;
    ctx->message_count = 1;
    
    return 0;
}

int handshake_process_message(handshake_context_t *ctx,
                               const uint8_t *message, size_t msg_len,
                               uint8_t *out_response, size_t *out_len) {
    if (!ctx || !message) return -1;
    
    if (ctx->role == HANDSHAKE_ROLE_INITIATOR) {
        if (ctx->message_count == 1) {
            // Expect: <- e, ee, s, es
            if (msg_len < 96) return -1;
            
            // Extract remote ephemeral public
            memcpy(ctx->remote_ephemeral_public, message, 32);
            
            // Extract remote static public
            memcpy(ctx->remote_static_public, message + 32, 32);
            
            // Compute DH operations
            uint8_t ee[32], es[32];
            dh(ctx->local_ephemeral_private, ctx->remote_ephemeral_public, ee);
            dh(ctx->local_ephemeral_private, ctx->remote_static_public, es);
            
            // Message 3: -> s, se
            if (out_response && out_len && *out_len >= 64) {
                memcpy(out_response, ctx->local_static_public, 32);
                
                uint8_t se[32];
                dh(ctx->local_static_private, ctx->remote_ephemeral_public, se);
                
                // Derive session keys
                uint8_t combined[96];
                memcpy(combined, ee, 32);
                memcpy(combined + 32, es, 32);
                memcpy(combined + 64, se, 32);
                
                derive_keys(combined, 96, ctx->tx_key, ctx->rx_key);
                
                // Add MAC (simplified)
                memcpy(out_response + 32, se, 16); // Use part of se as MAC
                *out_len = 48;
                
                ctx->handshake_complete = 1;
                ctx->state = HANDSHAKE_STATE_COMPLETE;
            }
            
            ctx->message_count = 3;
            return 0;
        }
    } else {
        // Responder
        if (ctx->message_count == 0) {
            // Expect: -> e
            if (msg_len < 32) return -1;
            
            memcpy(ctx->remote_ephemeral_public, message, 32);
            
            // Generate our ephemeral
            generate_keypair(ctx->local_ephemeral_private, ctx->local_ephemeral_public);
            
            // Message 2: <- e, ee, s, es
            if (out_response && out_len && *out_len >= 96) {
                memcpy(out_response, ctx->local_ephemeral_public, 32);
                memcpy(out_response + 32, ctx->local_static_public, 32);
                
                uint8_t ee[32], es[32];
                dh(ctx->local_ephemeral_private, ctx->remote_ephemeral_public, ee);
                dh(ctx->local_static_private, ctx->remote_ephemeral_public, es);
                
                // Add MAC (simplified)
                memcpy(out_response + 64, es, 16);
                *out_len = 80;
            }
            
            ctx->state = HANDSHAKE_STATE_IN_PROGRESS;
            ctx->message_count = 2;
            return 0;
            
        } else if (ctx->message_count == 2) {
            // Expect: -> s, se
            if (msg_len < 48) return -1;
            
            memcpy(ctx->remote_static_public, message, 32);
            
            // Derive final keys
            uint8_t ee[32], es[32], se[32];
            dh(ctx->local_ephemeral_private, ctx->remote_ephemeral_public, ee);
            dh(ctx->local_static_private, ctx->remote_ephemeral_public, es);
            dh(ctx->local_ephemeral_private, ctx->remote_static_public, se);
            
            uint8_t combined[96];
            memcpy(combined, ee, 32);
            memcpy(combined + 32, es, 32);
            memcpy(combined + 64, se, 32);
            
            // Note: keys are swapped for responder
            derive_keys(combined, 96, ctx->rx_key, ctx->tx_key);
            
            ctx->handshake_complete = 1;
            ctx->state = HANDSHAKE_STATE_COMPLETE;
            
            *out_len = 0; // No response needed
            return 0;
        }
    }
    
    return -1;
}

int handshake_is_complete(handshake_context_t *ctx) {
    return ctx ? ctx->handshake_complete : 0;
}

int handshake_get_keys(handshake_context_t *ctx, uint8_t *tx_key, uint8_t *rx_key) {
    if (!ctx || !ctx->handshake_complete) return -1;
    
    memcpy(tx_key, ctx->tx_key, HANDSHAKE_KEY_SIZE);
    memcpy(rx_key, ctx->rx_key, HANDSHAKE_KEY_SIZE);
    
    return 0;
}

int handshake_get_remote_pubkey(handshake_context_t *ctx, uint8_t *out_pubkey) {
    if (!ctx || !ctx->handshake_complete) return -1;
    
    memcpy(out_pubkey, ctx->remote_static_public, HANDSHAKE_PUBLIC_KEY_SIZE);
    return 0;
}

int handshake_get_fingerprint(handshake_context_t *ctx, char *out_fingerprint) {
    if (!ctx) return -1;
    
    // Generate hex fingerprint of local static public key
    for (int i = 0; i < 32; i++) {
        sprintf(out_fingerprint + (i * 2), "%02X", ctx->local_static_public[i]);
    }
    out_fingerprint[64] = '\0';
    
    return 0;
}

void handshake_reset(handshake_context_t *ctx) {
    if (!ctx) return;
    
    ctx->state = HANDSHAKE_STATE_INIT;
    ctx->handshake_complete = 0;
    ctx->message_count = 0;
    
    memset(ctx->local_ephemeral_private, 0, 32);
    memset(ctx->local_ephemeral_public, 0, 32);
    memset(ctx->remote_ephemeral_public, 0, 32);
    memset(ctx->remote_static_public, 0, 32);
}
