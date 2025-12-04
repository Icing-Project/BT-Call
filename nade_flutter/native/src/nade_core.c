/*
 * Copyright (c) 2024 Icing Project
 *
 * NADE core implementation responsible for Noise-style key exchange,
 * ChaCha20-Poly1305 transport security, and ADPCM audio framing.
 */

#include "nade_core.h"
#include "monocypher.h"

#include <android/log.h>
#include <jni.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#if defined(_WIN32)
#include <windows.h>
#include <bcrypt.h>
#else
#include <unistd.h>
#if defined(__ANDROID__) && (__ANDROID_API__ >= 28)
#include <sys/random.h>
#endif
#endif

#define TAG "NADECore"

#define MIC_CAPACITY 65536
#define SPK_CAPACITY 65536
#define OUT_CAPACITY 262144
#define IN_CAPACITY 262144
#define AUDIO_FRAME_SAMPLES 320

// -------------------------------------------------------------------------
// 4-FSK Modulation Configuration
// Frequencies chosen for voice-band transmission (300-3400 Hz range)
#define FSK_FREQ_00     1200    // Symbol 00 -> 1200 Hz
#define FSK_FREQ_01     1600    // Symbol 01 -> 1600 Hz
#define FSK_FREQ_10     2000    // Symbol 10 -> 2000 Hz
#define FSK_FREQ_11     2400    // Symbol 11 -> 2400 Hz
#define FSK_SAMPLE_RATE 8000    // 8 kHz sample rate
#define FSK_SYMBOL_RATE 100     // 100 symbols/sec = 200 bits/sec
#define FSK_SAMPLES_PER_SYMBOL (FSK_SAMPLE_RATE / FSK_SYMBOL_RATE)  // 80 samples
#define FSK_AMPLITUDE   16000   // Amplitude for generated tones (< 32767)

// Goertzel detection thresholds
#define FSK_GOERTZEL_THRESHOLD 1000000.0f  // Minimum power to detect a tone
#define FSK_GUARD_SAMPLES 8     // Guard samples at symbol boundaries

// 4-FSK modulation/demodulation ring buffers
#define FSK_MOD_CAPACITY 32768  // PCM samples for modulated output
#define FSK_DEMOD_CAPACITY 8192 // Bytes for demodulated input
#define HANDSHAKE_PAYLOAD_LEN 84
#define FRAME_KIND_HANDSHAKE 0x01
#define FRAME_KIND_CIPHER 0x02
#define FRAME_KIND_PLAINTEXT 0x03
#define FRAME_KIND_CONTROL 0x04
#define AUDIO_PAYLOAD_TYPE 0xA1
#define KEEPALIVE_TYPE 0xCC
#define HANGUP_TYPE 0xDD
#define HANDSHAKE_RESEND_MS 500
#define KEEPALIVE_INTERVAL_MS 1000
#define MAX_FRAME_BODY 2048

typedef enum {
    NADE_ROLE_NONE = 0,
    NADE_ROLE_SERVER = 1,
    NADE_ROLE_CLIENT = 2,
} nade_role_t;

typedef struct {
    int predictor;
    int index;
    bool initialized;
} nade_adpcm_state_t;

typedef struct {
    bool encrypt;
    bool decrypt;
} nade_config_t;

typedef struct {
    bool active;
    bool handshake_ready;
    bool handshake_complete;
    bool handshake_acknowledged;
    bool expect_peer_static;
    bool have_peer_static;
    bool have_peer_ephemeral;
    bool outbound_encrypted;
    bool inbound_encrypted;
    bool peer_accepts_encrypt;
    bool peer_sends_encrypt;
    nade_role_t role;
    uint8_t static_priv[32];
    uint8_t static_pub[32];
    uint8_t expected_peer_static[32];
    uint8_t peer_static[32];
    uint8_t eph_priv[32];
    uint8_t eph_pub[32];
    uint8_t peer_eph_pub[32];
    uint8_t tx_key[32];
    uint8_t rx_key[32];
    uint8_t tx_nonce_base[12];
    uint8_t rx_nonce_base[12];
    uint64_t tx_counter;
    uint64_t rx_counter;
    uint16_t audio_seq;
    uint64_t last_handshake_ms;
    uint64_t last_keepalive_ms;
    bool tx_aead_ready;
    bool rx_aead_ready;
    bool remote_hangup_requested;
    nade_adpcm_state_t enc_state;
    nade_adpcm_state_t dec_state;
} nade_session_state_t;

static nade_session_state_t g_session;
static nade_config_t g_config = {.encrypt = true, .decrypt = true};
static pthread_mutex_t g_session_mutex = PTHREAD_MUTEX_INITIALIZER;
static uint8_t g_identity_priv[32];
static uint8_t g_identity_pub[32];
static bool g_identity_ready = false;

static int16_t g_mic_ring[MIC_CAPACITY];
static size_t g_mic_head = 0;
static size_t g_mic_size = 0;
static pthread_mutex_t g_mic_mutex = PTHREAD_MUTEX_INITIALIZER;

static int16_t g_spk_ring[SPK_CAPACITY];
static size_t g_spk_head = 0;
static size_t g_spk_size = 0;
static pthread_mutex_t g_spk_mutex = PTHREAD_MUTEX_INITIALIZER;

static uint8_t g_out_ring[OUT_CAPACITY];
static size_t g_out_head = 0;
static size_t g_out_size = 0;
static pthread_mutex_t g_out_mutex = PTHREAD_MUTEX_INITIALIZER;

static uint8_t g_in_ring[IN_CAPACITY];
static size_t g_in_head = 0;
static size_t g_in_size = 0;
static pthread_mutex_t g_in_mutex = PTHREAD_MUTEX_INITIALIZER;

// 4-FSK Modulation state
static bool g_fsk_enabled = false;  // Enable/disable 4-FSK modulation (only for audio channel transport)
static int16_t g_fsk_mod_ring[FSK_MOD_CAPACITY];  // Modulated PCM output
static size_t g_fsk_mod_head = 0;
static size_t g_fsk_mod_size = 0;
static pthread_mutex_t g_fsk_mod_mutex = PTHREAD_MUTEX_INITIALIZER;

static uint8_t g_fsk_demod_ring[FSK_DEMOD_CAPACITY];  // Demodulated bytes
static size_t g_fsk_demod_head = 0;
static size_t g_fsk_demod_size = 0;
static pthread_mutex_t g_fsk_demod_mutex = PTHREAD_MUTEX_INITIALIZER;

// Phase accumulators for continuous phase modulation
static float g_fsk_tx_phase = 0.0f;

// Demodulator sample buffer for symbol detection
static int16_t g_fsk_rx_samples[FSK_SAMPLES_PER_SYMBOL];
static size_t g_fsk_rx_sample_count = 0;
static uint8_t g_fsk_rx_byte = 0;
static int g_fsk_rx_nibble_count = 0;

// -------------------------------------------------------------------------
// Utility helpers

static uint64_t now_monotonic_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000ULL + (uint64_t)ts.tv_nsec / 1000000ULL;
}

static size_t min_size(size_t a, size_t b);

static bool is_all_zero(const uint8_t *ptr, size_t len) {
    for (size_t i = 0; i < len; ++i) {
        if (ptr[i] != 0) {
            return false;
        }
    }
    return true;
}

typedef struct {
    uint32_t state[8];
    uint64_t bitlen;
    uint8_t buffer[64];
    size_t buffer_len;
} nade_sha256_ctx_t;

typedef struct {
    nade_sha256_ctx_t inner;
    nade_sha256_ctx_t outer;
} nade_hmac_sha256_ctx_t;

static const uint32_t k_sha256_table[64] = {
    0x428a2f98u, 0x71374491u, 0xb5c0fbcfu, 0xe9b5dba5u,
    0x3956c25bu, 0x59f111f1u, 0x923f82a4u, 0xab1c5ed5u,
    0xd807aa98u, 0x12835b01u, 0x243185beu, 0x550c7dc3u,
    0x72be5d74u, 0x80deb1feu, 0x9bdc06a7u, 0xc19bf174u,
    0xe49b69c1u, 0xefbe4786u, 0x0fc19dc6u, 0x240ca1ccu,
    0x2de92c6fu, 0x4a7484aau, 0x5cb0a9dcu, 0x76f988dau,
    0x983e5152u, 0xa831c66du, 0xb00327c8u, 0xbf597fc7u,
    0xc6e00bf3u, 0xd5a79147u, 0x06ca6351u, 0x14292967u,
    0x27b70a85u, 0x2e1b2138u, 0x4d2c6dfcu, 0x53380d13u,
    0x650a7354u, 0x766a0abbu, 0x81c2c92eu, 0x92722c85u,
    0xa2bfe8a1u, 0xa81a664bu, 0xc24b8b70u, 0xc76c51a3u,
    0xd192e819u, 0xd6990624u, 0xf40e3585u, 0x106aa070u,
    0x19a4c116u, 0x1e376c08u, 0x2748774cu, 0x34b0bcb5u,
    0x391c0cb3u, 0x4ed8aa4au, 0x5b9cca4fu, 0x682e6ff3u,
    0x748f82eeu, 0x78a5636fu, 0x84c87814u, 0x8cc70208u,
    0x90befffau, 0xa4506cebu, 0xbef9a3f7u, 0xc67178f2u,
};

static uint32_t rotr32(uint32_t value, uint32_t bits) {
    return (value >> bits) | (value << (32u - bits));
}

static uint32_t sha256_ch(uint32_t x, uint32_t y, uint32_t z) {
    return (x & y) ^ (~x & z);
}

static uint32_t sha256_maj(uint32_t x, uint32_t y, uint32_t z) {
    return (x & y) ^ (x & z) ^ (y & z);
}

static uint32_t sha256_sigma0(uint32_t x) {
    return rotr32(x, 2) ^ rotr32(x, 13) ^ rotr32(x, 22);
}

static uint32_t sha256_sigma1(uint32_t x) {
    return rotr32(x, 6) ^ rotr32(x, 11) ^ rotr32(x, 25);
}

static uint32_t sha256_gamma0(uint32_t x) {
    return rotr32(x, 7) ^ rotr32(x, 18) ^ (x >> 3);
}

static uint32_t sha256_gamma1(uint32_t x) {
    return rotr32(x, 17) ^ rotr32(x, 19) ^ (x >> 10);
}

static void sha256_digest(const uint8_t *data, size_t len, uint8_t out[32]);

static void sha256_init_ctx(nade_sha256_ctx_t *ctx) {
    ctx->state[0] = 0x6a09e667u;
    ctx->state[1] = 0xbb67ae85u;
    ctx->state[2] = 0x3c6ef372u;
    ctx->state[3] = 0xa54ff53au;
    ctx->state[4] = 0x510e527fu;
    ctx->state[5] = 0x9b05688cu;
    ctx->state[6] = 0x1f83d9abu;
    ctx->state[7] = 0x5be0cd19u;
    ctx->bitlen = 0;
    ctx->buffer_len = 0;
}

static void sha256_process_block(nade_sha256_ctx_t *ctx, const uint8_t block[64]) {
    uint32_t w[64];
    for (size_t i = 0; i < 16; ++i) {
        size_t idx = i * 4;
        w[i] = ((uint32_t)block[idx] << 24) |
               ((uint32_t)block[idx + 1] << 16) |
               ((uint32_t)block[idx + 2] << 8) |
               ((uint32_t)block[idx + 3]);
    }
    for (size_t i = 16; i < 64; ++i) {
        w[i] = sha256_gamma1(w[i - 2]) + w[i - 7] + sha256_gamma0(w[i - 15]) + w[i - 16];
    }
    uint32_t a = ctx->state[0];
    uint32_t b = ctx->state[1];
    uint32_t c = ctx->state[2];
    uint32_t d = ctx->state[3];
    uint32_t e = ctx->state[4];
    uint32_t f = ctx->state[5];
    uint32_t g = ctx->state[6];
    uint32_t h = ctx->state[7];
    for (size_t i = 0; i < 64; ++i) {
        uint32_t t1 = h + sha256_sigma1(e) + sha256_ch(e, f, g) + k_sha256_table[i] + w[i];
        uint32_t t2 = sha256_sigma0(a) + sha256_maj(a, b, c);
        h = g;
        g = f;
        f = e;
        e = d + t1;
        d = c;
        c = b;
        b = a;
        a = t1 + t2;
    }
    ctx->state[0] += a;
    ctx->state[1] += b;
    ctx->state[2] += c;
    ctx->state[3] += d;
    ctx->state[4] += e;
    ctx->state[5] += f;
    ctx->state[6] += g;
    ctx->state[7] += h;
}

static void sha256_update_ctx(nade_sha256_ctx_t *ctx, const uint8_t *data, size_t len) {
    if (len == 0) {
        return;
    }
    ctx->bitlen += (uint64_t)len * 8ull;
    size_t offset = 0;
    if (ctx->buffer_len > 0) {
        size_t to_copy = min_size(len, 64 - ctx->buffer_len);
        memcpy(ctx->buffer + ctx->buffer_len, data, to_copy);
        ctx->buffer_len += to_copy;
        offset += to_copy;
        if (ctx->buffer_len == 64) {
            sha256_process_block(ctx, ctx->buffer);
            ctx->buffer_len = 0;
        }
    }
    while (offset + 64 <= len) {
        sha256_process_block(ctx, data + offset);
        offset += 64;
    }
    if (offset < len) {
        ctx->buffer_len = len - offset;
        memcpy(ctx->buffer, data + offset, ctx->buffer_len);
    }
}

static void sha256_final_ctx(nade_sha256_ctx_t *ctx, uint8_t out[32]) {
    size_t i = ctx->buffer_len;
    ctx->buffer[i++] = 0x80;
    if (i > 56) {
        while (i < 64) {
            ctx->buffer[i++] = 0;
        }
        sha256_process_block(ctx, ctx->buffer);
        i = 0;
    }
    while (i < 56) {
        ctx->buffer[i++] = 0;
    }
    uint64_t bitlen = ctx->bitlen;
    for (int j = 0; j < 8; ++j) {
        ctx->buffer[63 - j] = (uint8_t)((bitlen >> (j * 8)) & 0xFFu);
    }
    sha256_process_block(ctx, ctx->buffer);
    for (int j = 0; j < 8; ++j) {
        out[j * 4 + 0] = (uint8_t)((ctx->state[j] >> 24) & 0xFFu);
        out[j * 4 + 1] = (uint8_t)((ctx->state[j] >> 16) & 0xFFu);
        out[j * 4 + 2] = (uint8_t)((ctx->state[j] >> 8) & 0xFFu);
        out[j * 4 + 3] = (uint8_t)(ctx->state[j] & 0xFFu);
    }
    memset(ctx, 0, sizeof(*ctx));
}

static void hmac_sha256_init_ctx(nade_hmac_sha256_ctx_t *ctx,
                                 const uint8_t *key, size_t key_len) {
    uint8_t key_block[64];
    if (key_len > sizeof(key_block)) {
        sha256_digest(key, key_len, key_block);
        key = key_block;
        key_len = 32;
    }
    memset(key_block, 0, sizeof(key_block));
    if (key_len > 0) {
        memcpy(key_block, key, key_len);
    }
    uint8_t ipad[64];
    uint8_t opad[64];
    for (size_t i = 0; i < 64; ++i) {
        ipad[i] = (uint8_t)(key_block[i] ^ 0x36u);
        opad[i] = (uint8_t)(key_block[i] ^ 0x5cu);
    }
    sha256_init_ctx(&ctx->inner);
    sha256_update_ctx(&ctx->inner, ipad, sizeof(ipad));
    sha256_init_ctx(&ctx->outer);
    sha256_update_ctx(&ctx->outer, opad, sizeof(opad));
    memset(key_block, 0, sizeof(key_block));
    memset(ipad, 0, sizeof(ipad));
    memset(opad, 0, sizeof(opad));
}

static void hmac_sha256_update(nade_hmac_sha256_ctx_t *ctx,
                               const uint8_t *data, size_t len) {
    sha256_update_ctx(&ctx->inner, data, len);
}

static void hmac_sha256_final_ctx(nade_hmac_sha256_ctx_t *ctx, uint8_t out[32]) {
    uint8_t inner_hash[32];
    sha256_final_ctx(&ctx->inner, inner_hash);
    sha256_update_ctx(&ctx->outer, inner_hash, sizeof(inner_hash));
    sha256_final_ctx(&ctx->outer, out);
    memset(inner_hash, 0, sizeof(inner_hash));
}

static void hmac_sha256(uint8_t out[32], const uint8_t *key, size_t key_len,
                        const uint8_t *data, size_t len) {
    nade_hmac_sha256_ctx_t ctx;
    hmac_sha256_init_ctx(&ctx, key, key_len);
    hmac_sha256_update(&ctx, data, len);
    hmac_sha256_final_ctx(&ctx, out);
}

static bool hkdf_sha256(uint8_t *okm, size_t okm_len,
                        const uint8_t *ikm, size_t ikm_len,
                        const uint8_t *salt, size_t salt_len,
                        const uint8_t *info, size_t info_len) {
    if (!okm || okm_len == 0 || okm_len > 255 * 32) {
        return false;
    }
    static const uint8_t zero_salt[32] = {0};
    if (!salt || salt_len == 0) {
        salt = zero_salt;
        salt_len = sizeof(zero_salt);
    }
    uint8_t prk[32];
    hmac_sha256(prk, salt, salt_len, ikm, ikm_len);
    uint8_t previous[32];
    size_t previous_len = 0;
    uint8_t counter = 1;
    size_t produced = 0;
    while (produced < okm_len) {
        nade_hmac_sha256_ctx_t ctx;
        hmac_sha256_init_ctx(&ctx, prk, sizeof(prk));
        if (previous_len > 0) {
            hmac_sha256_update(&ctx, previous, previous_len);
        }
        if (info && info_len > 0) {
            hmac_sha256_update(&ctx, info, info_len);
        }
        hmac_sha256_update(&ctx, &counter, 1);
        hmac_sha256_final_ctx(&ctx, previous);
        previous_len = sizeof(previous);
        size_t to_copy = min_size(previous_len, okm_len - produced);
        memcpy(okm + produced, previous, to_copy);
        produced += to_copy;
        counter++;
    }
    memset(prk, 0, sizeof(prk));
    memset(previous, 0, sizeof(previous));
    return true;
}

static void clamp_x25519(uint8_t key[32]) {
    key[0] &= 248;
    key[31] &= 127;
    key[31] |= 64;
}

static bool derive_public_key(const uint8_t priv[32], uint8_t pub[32]) {
    if (!priv || !pub) {
        return false;
    }
    crypto_x25519_public_key(pub, priv);
    return true;
}

static bool x25519(uint8_t out[32], const uint8_t priv[32], const uint8_t pub[32]) {
    if (!out || !priv || !pub) {
        return false;
    }
    crypto_x25519(out, priv, pub);
    return !is_all_zero(out, 32);
}

static bool secure_random_bytes(uint8_t *out, size_t len) {
    if (!out || len == 0) {
        return false;
    }
#if defined(_WIN32)
    return BCryptGenRandom(NULL, out, (ULONG)len, BCRYPT_USE_SYSTEM_PREFERRED_RNG) == 0;
#else
#if defined(__ANDROID__) && (__ANDROID_API__ >= 28)
    size_t produced = 0;
    while (produced < len) {
        ssize_t rc = getrandom(out + produced, len - produced, 0);
        if (rc < 0) {
            if (errno == EINTR) {
                continue;
            }
            break;
        }
        produced += (size_t)rc;
    }
    if (produced == len) {
        return true;
    }
#endif
    int fd = open("/dev/urandom", O_RDONLY);
    if (fd < 0) {
        return false;
    }
    size_t total = 0;
    while (total < len) {
        ssize_t rc = read(fd, out + total, len - total);
        if (rc < 0) {
            if (errno == EINTR) {
                continue;
            }
            close(fd);
            return false;
        }
        if (rc == 0) {
            break;
        }
        total += (size_t)rc;
    }
    close(fd);
    return total == len;
#endif
}

static void compose_nonce(uint8_t out[12], const uint8_t base[12], uint64_t counter) {
    memcpy(out, base, 12);
    for (int i = 0; i < 8; ++i) {
        out[4 + i] ^= (uint8_t)((counter >> (i * 8)) & 0xFF);
    }
}

static size_t min_size(size_t a, size_t b) {
    return a < b ? a : b;
}

static void sha256_digest(const uint8_t *data, size_t len, uint8_t out[32]) {
    nade_sha256_ctx_t ctx;
    sha256_init_ctx(&ctx);
    if (len > 0 && data != NULL) {
        sha256_update_ctx(&ctx, data, len);
    }
    sha256_final_ctx(&ctx, out);
}

static void reset_adpcm(nade_adpcm_state_t *state) {
    state->predictor = 0;
    state->index = 0;
    state->initialized = false;
}

// -------------------------------------------------------------------------
// Ring helpers

static void push_int16_ring(int16_t *ring, size_t capacity, size_t *head,
                            size_t *size, const int16_t *samples, size_t count,
                            pthread_mutex_t *guard) {
    pthread_mutex_lock(guard);
    for (size_t i = 0; i < count; ++i) {
        size_t tail = (*head + *size) % capacity;
        ring[tail] = samples[i];
        if (*size == capacity) {
            *head = (*head + 1) % capacity;
        } else {
            (*size)++;
        }
    }
    pthread_mutex_unlock(guard);
}

static size_t pop_int16_ring(int16_t *ring, size_t capacity, size_t *head,
                             size_t *size, int16_t *out, size_t max,
                             pthread_mutex_t *guard) {
    pthread_mutex_lock(guard);
    size_t available = *size < max ? *size : max;
    for (size_t i = 0; i < available; ++i) {
        out[i] = ring[*head];
        *head = (*head + 1) % capacity;
    }
    *size -= available;
    pthread_mutex_unlock(guard);
    return available;
}

static size_t available_int16(const size_t *size_ptr, pthread_mutex_t *guard) {
    pthread_mutex_lock(guard);
    size_t value = *size_ptr;
    pthread_mutex_unlock(guard);
    return value;
}

static void clear_int16_ring(size_t *head, size_t *size, pthread_mutex_t *guard) {
    pthread_mutex_lock(guard);
    *head = 0;
    *size = 0;
    pthread_mutex_unlock(guard);
}

static void outgoing_push(const uint8_t *data, size_t len) {
    pthread_mutex_lock(&g_out_mutex);
    for (size_t i = 0; i < len; ++i) {
        size_t tail = (g_out_head + g_out_size) % OUT_CAPACITY;
        g_out_ring[tail] = data[i];
        if (g_out_size == OUT_CAPACITY) {
            g_out_head = (g_out_head + 1) % OUT_CAPACITY;
        } else {
            g_out_size++;
        }
    }
    pthread_mutex_unlock(&g_out_mutex);
}

static size_t outgoing_pop(uint8_t *dst, size_t max_len) {
    pthread_mutex_lock(&g_out_mutex);
    size_t to_read = min_size(max_len, g_out_size);
    for (size_t i = 0; i < to_read; ++i) {
        dst[i] = g_out_ring[g_out_head];
        g_out_head = (g_out_head + 1) % OUT_CAPACITY;
    }
    g_out_size -= to_read;
    pthread_mutex_unlock(&g_out_mutex);
    return to_read;
}

static void outgoing_clear(void) {
    pthread_mutex_lock(&g_out_mutex);
    g_out_head = 0;
    g_out_size = 0;
    pthread_mutex_unlock(&g_out_mutex);
}

static void incoming_push(const uint8_t *data, size_t len) {
    pthread_mutex_lock(&g_in_mutex);
    for (size_t i = 0; i < len; ++i) {
        size_t tail = (g_in_head + g_in_size) % IN_CAPACITY;
        g_in_ring[tail] = data[i];
        if (g_in_size == IN_CAPACITY) {
            g_in_head = (g_in_head + 1) % IN_CAPACITY;
        } else {
            g_in_size++;
        }
    }
    pthread_mutex_unlock(&g_in_mutex);
}

static size_t incoming_size(void) {
    pthread_mutex_lock(&g_in_mutex);
    size_t sz = g_in_size;
    pthread_mutex_unlock(&g_in_mutex);
    return sz;
}

static bool incoming_peek(uint8_t *dst, size_t len) {
    pthread_mutex_lock(&g_in_mutex);
    if (g_in_size < len) {
        pthread_mutex_unlock(&g_in_mutex);
        return false;
    }
    for (size_t i = 0; i < len; ++i) {
        size_t idx = (g_in_head + i) % IN_CAPACITY;
        dst[i] = g_in_ring[idx];
    }
    pthread_mutex_unlock(&g_in_mutex);
    return true;
}

static void incoming_drop(size_t len) {
    pthread_mutex_lock(&g_in_mutex);
    if (len >= g_in_size) {
        g_in_head = 0;
        g_in_size = 0;
    } else {
        g_in_head = (g_in_head + len) % IN_CAPACITY;
        g_in_size -= len;
    }
    pthread_mutex_unlock(&g_in_mutex);
}

static bool incoming_read(uint8_t *dst, size_t len) {
    if (!incoming_peek(dst, len)) {
        return false;
    }
    incoming_drop(len);
    return true;
}

static void incoming_clear(void) {
    pthread_mutex_lock(&g_in_mutex);
    g_in_head = 0;
    g_in_size = 0;
    pthread_mutex_unlock(&g_in_mutex);
}

// -------------------------------------------------------------------------
// ADPCM codec (IMA 4-bit mono)

static const int kStepTable[89] = {
    7, 8, 9, 10, 11, 12, 13, 14, 16,
    17, 19, 21, 23, 25, 28, 31, 34,
    37, 41, 45, 50, 55, 60, 66, 73,
    80, 88, 97, 107, 118, 130, 143, 157,
    173, 190, 209, 230, 253, 279, 307, 337,
    371, 408, 449, 494, 544, 598, 658, 724,
    796, 876, 963, 1060, 1166, 1282, 1411, 1552,
    1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327,
    3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132,
    7845, 8630, 9493, 10442, 11487, 12635, 13899, 15289,
    16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767
};

static const int kIndexAdjust[16] = {
    -1, -1, -1, -1, 2, 4, 6, 8,
    -1, -1, -1, -1, 2, 4, 6, 8
};

static int clamp_int(int value, int min_v, int max_v) {
    if (value < min_v) return min_v;
    if (value > max_v) return max_v;
    return value;
}

static size_t adpcm_encode_block(const int16_t *samples, size_t count,
                                 uint8_t *out, size_t max_bytes,
                                 nade_adpcm_state_t *state) {
    if (count == 0 || max_bytes < 4) {
        return 0;
    }
    if (!state->initialized) {
        state->predictor = samples[0];
        state->index = 0;
        state->initialized = true;
    }
    const size_t encoded_nibbles = count;
    const size_t encoded_bytes = (encoded_nibbles + 1) / 2;
    if (4 + encoded_bytes > max_bytes) {
        return 0;
    }
    out[0] = (uint8_t)(state->predictor & 0xFF);
    out[1] = (uint8_t)((state->predictor >> 8) & 0xFF);
    out[2] = (uint8_t)state->index;
    out[3] = 0;
    size_t out_idx = 4;
    uint8_t current_byte = 0;
    bool high_nibble = false;
    for (size_t i = 0; i < count; ++i) {
        int diff = samples[i] - state->predictor;
        int step = kStepTable[state->index];
        int nibble = 0;
        if (diff < 0) {
            nibble = 8;
            diff = -diff;
        }
        if (diff >= step) {
            nibble |= 4;
            diff -= step;
        }
        if (diff >= step / 2) {
            nibble |= 2;
            diff -= step / 2;
        }
        if (diff >= step / 4) {
            nibble |= 1;
        }
        int delta = step >> 3;
        if (nibble & 4) delta += step;
        if (nibble & 2) delta += step >> 1;
        if (nibble & 1) delta += step >> 2;
        if (nibble & 8) {
            state->predictor -= delta;
        } else {
            state->predictor += delta;
        }
        state->predictor = clamp_int(state->predictor, -32768, 32767);
        state->index = clamp_int(state->index + kIndexAdjust[nibble & 0x0F], 0, 88);
        if (!high_nibble) {
            current_byte = (uint8_t)(nibble & 0x0F);
            high_nibble = true;
        } else {
            current_byte |= (uint8_t)((nibble & 0x0F) << 4);
            out[out_idx++] = current_byte;
            high_nibble = false;
            current_byte = 0;
        }
    }
    if (high_nibble) {
        out[out_idx++] = current_byte;
    }
    return out_idx;
}

static size_t adpcm_decode_block(const uint8_t *data, size_t len,
                                 int16_t *out, size_t max_samples,
                                 nade_adpcm_state_t *state) {
    if (len < 4 || max_samples == 0) {
        return 0;
    }
    int predictor = (int16_t)(data[0] | (data[1] << 8));
    int index = clamp_int(data[2], 0, 88);
    size_t produced = 0;
    for (size_t i = 4; i < len && produced < max_samples; ++i) {
        uint8_t byte = data[i];
        for (int shift = 0; shift <= 4 && produced < max_samples; shift += 4) {
            int nibble = (byte >> shift) & 0x0F;
            int step = kStepTable[index];
            int delta = step >> 3;
            if (nibble & 4) delta += step;
            if (nibble & 2) delta += step >> 1;
            if (nibble & 1) delta += step >> 2;
            if (nibble & 8) {
                predictor -= delta;
            } else {
                predictor += delta;
            }
            predictor = clamp_int(predictor, -32768, 32767);
            index = clamp_int(index + kIndexAdjust[nibble], 0, 88);
            out[produced++] = (int16_t)predictor;
        }
    }
    state->predictor = predictor;
    state->index = index;
    state->initialized = true;
    return produced;
}

// -------------------------------------------------------------------------
// 4-FSK Modulation / Demodulation
// Converts bytes <-> audio tones for "audio over audio" transmission

#include <math.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

// Lookup table for 4-FSK frequencies (2 bits -> frequency)
static const int kFskFrequencies[4] = {
    FSK_FREQ_00,  // 00 -> 1200 Hz
    FSK_FREQ_01,  // 01 -> 1600 Hz
    FSK_FREQ_10,  // 10 -> 2000 Hz
    FSK_FREQ_11   // 11 -> 2400 Hz
};

// Precomputed Goertzel coefficients for each frequency
typedef struct {
    float coeff;
    float omega;
} goertzel_coeff_t;

static goertzel_coeff_t g_goertzel_coeffs[4];
static bool g_goertzel_initialized = false;

static void init_goertzel_coeffs(void) {
    if (g_goertzel_initialized) return;
    
    for (int i = 0; i < 4; i++) {
        float k = (float)(kFskFrequencies[i] * FSK_SAMPLES_PER_SYMBOL) / (float)FSK_SAMPLE_RATE;
        g_goertzel_coeffs[i].omega = (2.0f * (float)M_PI * k) / (float)FSK_SAMPLES_PER_SYMBOL;
        g_goertzel_coeffs[i].coeff = 2.0f * cosf(g_goertzel_coeffs[i].omega);
    }
    g_goertzel_initialized = true;
}

// Goertzel algorithm to detect power at a specific frequency
static float goertzel_power(const int16_t *samples, size_t count, int freq_idx) {
    if (freq_idx < 0 || freq_idx > 3) return 0.0f;
    
    float coeff = g_goertzel_coeffs[freq_idx].coeff;
    float s0 = 0.0f, s1 = 0.0f, s2 = 0.0f;
    
    for (size_t i = 0; i < count; i++) {
        s0 = (float)samples[i] + coeff * s1 - s2;
        s2 = s1;
        s1 = s0;
    }
    
    // Power = s1^2 + s2^2 - coeff * s1 * s2
    float power = s1 * s1 + s2 * s2 - coeff * s1 * s2;
    return power;
}

// Detect which of the 4 FSK frequencies is present in a symbol period
static int detect_fsk_symbol(const int16_t *samples, size_t count) {
    init_goertzel_coeffs();
    
    float max_power = 0.0f;
    int best_symbol = 0;
    
    for (int i = 0; i < 4; i++) {
        float power = goertzel_power(samples, count, i);
        if (power > max_power) {
            max_power = power;
            best_symbol = i;
        }
    }
    
    // Only return valid symbol if power exceeds threshold
    if (max_power < FSK_GOERTZEL_THRESHOLD) {
        return -1;  // No valid symbol detected (silence or noise)
    }
    
    return best_symbol;
}

// Modulate a single symbol (2 bits) into PCM samples
// Uses continuous phase to avoid clicks at symbol boundaries
static size_t fsk_modulate_symbol(int symbol, int16_t *out, size_t max_samples) {
    if (symbol < 0 || symbol > 3 || max_samples < FSK_SAMPLES_PER_SYMBOL) {
        return 0;
    }
    
    int freq = kFskFrequencies[symbol];
    float phase_increment = (2.0f * (float)M_PI * (float)freq) / (float)FSK_SAMPLE_RATE;
    
    for (size_t i = 0; i < FSK_SAMPLES_PER_SYMBOL; i++) {
        out[i] = (int16_t)(FSK_AMPLITUDE * sinf(g_fsk_tx_phase));
        g_fsk_tx_phase += phase_increment;
        
        // Keep phase in [0, 2*PI) to avoid float precision issues
        if (g_fsk_tx_phase >= 2.0f * (float)M_PI) {
            g_fsk_tx_phase -= 2.0f * (float)M_PI;
        }
    }
    
    return FSK_SAMPLES_PER_SYMBOL;
}

// Modulate a byte into PCM samples (4 symbols, each carrying 2 bits)
// Returns number of samples written
static size_t fsk_modulate_byte(uint8_t byte, int16_t *out, size_t max_samples) {
    if (max_samples < FSK_SAMPLES_PER_SYMBOL * 4) {
        return 0;
    }
    
    size_t total = 0;
    
    // Extract 4 symbols (2 bits each) from the byte, LSB first
    for (int i = 0; i < 4; i++) {
        int symbol = (byte >> (i * 2)) & 0x03;
        size_t written = fsk_modulate_symbol(symbol, out + total, max_samples - total);
        total += written;
    }
    
    return total;
}

// Modulate a buffer of bytes into PCM audio
// Returns number of PCM samples written
static size_t fsk_modulate_buffer(const uint8_t *data, size_t len, 
                                   int16_t *out, size_t max_samples) {
    size_t total_samples = 0;
    
    for (size_t i = 0; i < len; i++) {
        size_t needed = FSK_SAMPLES_PER_SYMBOL * 4;
        if (total_samples + needed > max_samples) {
            break;
        }
        
        size_t written = fsk_modulate_byte(data[i], out + total_samples, 
                                           max_samples - total_samples);
        total_samples += written;
    }
    
    return total_samples;
}

// Push modulated PCM samples to the FSK output ring
static void fsk_mod_push(const int16_t *samples, size_t count) {
    pthread_mutex_lock(&g_fsk_mod_mutex);
    for (size_t i = 0; i < count; i++) {
        size_t tail = (g_fsk_mod_head + g_fsk_mod_size) % FSK_MOD_CAPACITY;
        g_fsk_mod_ring[tail] = samples[i];
        if (g_fsk_mod_size == FSK_MOD_CAPACITY) {
            g_fsk_mod_head = (g_fsk_mod_head + 1) % FSK_MOD_CAPACITY;
        } else {
            g_fsk_mod_size++;
        }
    }
    pthread_mutex_unlock(&g_fsk_mod_mutex);
}

// Pull modulated PCM samples from the FSK output ring
static size_t fsk_mod_pull(int16_t *out, size_t max_samples) {
    pthread_mutex_lock(&g_fsk_mod_mutex);
    size_t to_read = min_size(max_samples, g_fsk_mod_size);
    for (size_t i = 0; i < to_read; i++) {
        out[i] = g_fsk_mod_ring[g_fsk_mod_head];
        g_fsk_mod_head = (g_fsk_mod_head + 1) % FSK_MOD_CAPACITY;
    }
    g_fsk_mod_size -= to_read;
    pthread_mutex_unlock(&g_fsk_mod_mutex);
    return to_read;
}

// Push demodulated bytes to the FSK demod ring
static void fsk_demod_push(const uint8_t *data, size_t len) {
    pthread_mutex_lock(&g_fsk_demod_mutex);
    for (size_t i = 0; i < len; i++) {
        size_t tail = (g_fsk_demod_head + g_fsk_demod_size) % FSK_DEMOD_CAPACITY;
        g_fsk_demod_ring[tail] = data[i];
        if (g_fsk_demod_size == FSK_DEMOD_CAPACITY) {
            g_fsk_demod_head = (g_fsk_demod_head + 1) % FSK_DEMOD_CAPACITY;
        } else {
            g_fsk_demod_size++;
        }
    }
    pthread_mutex_unlock(&g_fsk_demod_mutex);
}

// Pull demodulated bytes from the FSK demod ring
static size_t fsk_demod_pull(uint8_t *out, size_t max_len) {
    pthread_mutex_lock(&g_fsk_demod_mutex);
    size_t to_read = min_size(max_len, g_fsk_demod_size);
    for (size_t i = 0; i < to_read; i++) {
        out[i] = g_fsk_demod_ring[g_fsk_demod_head];
        g_fsk_demod_head = (g_fsk_demod_head + 1) % FSK_DEMOD_CAPACITY;
    }
    g_fsk_demod_size -= to_read;
    pthread_mutex_unlock(&g_fsk_demod_mutex);
    return to_read;
}

// Process incoming PCM samples and demodulate to bytes
// Call this with speaker/received audio samples
static void fsk_demodulate_samples(const int16_t *samples, size_t count) {
    init_goertzel_coeffs();
    
    for (size_t i = 0; i < count; i++) {
        g_fsk_rx_samples[g_fsk_rx_sample_count++] = samples[i];
        
        // When we have a full symbol's worth of samples
        if (g_fsk_rx_sample_count >= FSK_SAMPLES_PER_SYMBOL) {
            // Detect which symbol (0-3) is present
            int symbol = detect_fsk_symbol(g_fsk_rx_samples, g_fsk_rx_sample_count);
            
            if (symbol >= 0) {
                // Accumulate symbol into current byte (LSB first)
                g_fsk_rx_byte |= (uint8_t)(symbol << (g_fsk_rx_nibble_count * 2));
                g_fsk_rx_nibble_count++;
                
                // When we have 4 symbols (8 bits), output the byte
                if (g_fsk_rx_nibble_count >= 4) {
                    fsk_demod_push(&g_fsk_rx_byte, 1);
                    g_fsk_rx_byte = 0;
                    g_fsk_rx_nibble_count = 0;
                }
            }
            
            g_fsk_rx_sample_count = 0;
        }
    }
}

// Reset FSK state (call when starting new session)
static void fsk_reset_state(void) {
    g_fsk_tx_phase = 0.0f;
    g_fsk_rx_sample_count = 0;
    g_fsk_rx_byte = 0;
    g_fsk_rx_nibble_count = 0;
    
    pthread_mutex_lock(&g_fsk_mod_mutex);
    g_fsk_mod_head = 0;
    g_fsk_mod_size = 0;
    pthread_mutex_unlock(&g_fsk_mod_mutex);
    
    pthread_mutex_lock(&g_fsk_demod_mutex);
    g_fsk_demod_head = 0;
    g_fsk_demod_size = 0;
    pthread_mutex_unlock(&g_fsk_demod_mutex);
}

// -------------------------------------------------------------------------
// Session + framing helpers

static void session_reset_locked(void) {
    uint8_t priv_copy[32];
    uint8_t pub_copy[32];
    bool preserve_identity = g_identity_ready;
    if (preserve_identity) {
        memcpy(priv_copy, g_identity_priv, 32);
        memcpy(pub_copy, g_identity_pub, 32);
    }
    memset(&g_session, 0, sizeof(g_session));
    g_session.tx_aead_ready = false;
    g_session.rx_aead_ready = false;
    if (preserve_identity) {
        memcpy(g_session.static_priv, priv_copy, 32);
        memcpy(g_session.static_pub, pub_copy, 32);
    }
    reset_adpcm(&g_session.enc_state);
    reset_adpcm(&g_session.dec_state);
    fsk_reset_state();  // Reset 4-FSK modulation state
}

static void queue_frame(uint8_t kind, const uint8_t *payload, uint16_t length) {
    uint8_t header[3];
    header[0] = kind;
    header[1] = (uint8_t)(length & 0xFF);
    header[2] = (uint8_t)((length >> 8) & 0xFF);
    outgoing_push(header, sizeof(header));
    if (length > 0 && payload != NULL) {
        outgoing_push(payload, length);
    }
}

static void ensure_ephemeral_locked(void) {
    if (!secure_random_bytes(g_session.eph_priv, sizeof(g_session.eph_priv))) {
        __android_log_print(ANDROID_LOG_ERROR, TAG, "Failed to gather entropy for ephemeral key");
        memset(g_session.eph_priv, 0, sizeof(g_session.eph_priv));
        return;
    }
    clamp_x25519(g_session.eph_priv);
    if (!derive_public_key(g_session.eph_priv, g_session.eph_pub)) {
        __android_log_print(ANDROID_LOG_ERROR, TAG, "Failed to derive ephemeral public key");
    }
    g_session.have_peer_ephemeral = false;
}

static size_t build_handshake_payload_locked(uint8_t *out, size_t max_len) {
    if (max_len < HANDSHAKE_PAYLOAD_LEN) {
        return 0;
    }
    uint8_t capabilities = 0;
    if (g_config.encrypt) capabilities |= 0x01;
    if (g_config.decrypt) capabilities |= 0x02;
    out[0] = 1; // version
    out[1] = (uint8_t)g_session.role;
    out[2] = capabilities;
    out[3] = 0;
    memcpy(out + 4, g_session.eph_pub, 32);
    memcpy(out + 36, g_session.static_pub, 32);
    uint8_t digest[32];
    sha256_digest(g_session.static_pub, 32, digest);
    memcpy(out + 68, digest, 16);
    return HANDSHAKE_PAYLOAD_LEN;
}

static bool derive_keys_locked(void) {
    if (!g_session.have_peer_static || !g_session.have_peer_ephemeral) {
        return false;
    }
    uint8_t dh1[32], dh2[32], dh3[32];
    if (!x25519(dh1, g_session.eph_priv, g_session.peer_eph_pub)) return false;
    if (!x25519(dh2, g_session.static_priv, g_session.peer_eph_pub)) return false;
    if (!x25519(dh3, g_session.eph_priv, g_session.peer_static)) return false;
    uint8_t material[96];
    memcpy(material, dh1, 32);
    // Ensure eS (Client Ephemeral * Server Static) precedes sE (Client Static * Server Ephemeral)
    // Client: dh3 = eS, dh2 = sE
    // Server: dh2 = eS, dh3 = sE
    if (g_session.role == NADE_ROLE_CLIENT) {
        memcpy(material + 32, dh3, 32);
        memcpy(material + 64, dh2, 32);
    } else {
        // Server logic: dh2 is eS (Server Ephemeral * Client Static), dh3 is sE (Server Static * Client Ephemeral)
        // We want to match Client's order: dh1 || dh3 || dh2
        // Client dh3 is eS. Server dh2 is eS.
        // Client dh2 is sE. Server dh3 is sE.
        // So Server must use: dh1 || dh2 || dh3
        memcpy(material + 32, dh2, 32);
        memcpy(material + 64, dh3, 32);
    }
    uint8_t derived[96];
    const uint8_t salt[] = {'N','A','D','E','v','1'};
    // HKDF info must be identical for both parties. Do not include role.
    const uint8_t info[] = {'N','A','D','E','_','S','E','S','S'};
    __android_log_print(ANDROID_LOG_DEBUG, TAG,
                        "Deriving keys (role=%d) dh1=%02x%02x%02x%02x dh2=%02x%02x%02x%02x dh3=%02x%02x%02x%02x",
                        g_session.role,
                        dh1[0], dh1[1], dh1[2], dh1[3],
                        material[32], material[33], material[34], material[35],
                        material[64], material[65], material[66], material[67]);
    if (!hkdf_sha256(derived, sizeof(derived), material, sizeof(material),
                     salt, sizeof(salt), info, sizeof(info))) {
        __android_log_print(ANDROID_LOG_ERROR, TAG, "HKDF failed (role=%d)", g_session.role);
        return false;
    }
    uint8_t client_key[32], server_key[32];
    uint8_t client_nonce[12], server_nonce[12];
    memcpy(client_key, derived, 32);
    memcpy(server_key, derived + 32, 32);
    memcpy(client_nonce, derived + 64, 12);
    memcpy(server_nonce, derived + 76, 12);
    if (g_session.role == NADE_ROLE_CLIENT) {
        memcpy(g_session.tx_key, client_key, 32);
        memcpy(g_session.rx_key, server_key, 32);
        memcpy(g_session.tx_nonce_base, client_nonce, 12);
        memcpy(g_session.rx_nonce_base, server_nonce, 12);
    } else {
        memcpy(g_session.tx_key, server_key, 32);
        memcpy(g_session.rx_key, client_key, 32);
        memcpy(g_session.tx_nonce_base, server_nonce, 12);
        memcpy(g_session.rx_nonce_base, client_nonce, 12);
    }
    
    // Log the derived keys for debugging (only first few bytes)
    __android_log_print(ANDROID_LOG_DEBUG, TAG, "Keys derived. Role: %d", g_session.role);
    __android_log_print(ANDROID_LOG_DEBUG, TAG, "TX Key: %02x%02x%02x...", g_session.tx_key[0], g_session.tx_key[1], g_session.tx_key[2]);
    __android_log_print(ANDROID_LOG_DEBUG, TAG, "RX Key: %02x%02x%02x...", g_session.rx_key[0], g_session.rx_key[1], g_session.rx_key[2]);

    g_session.tx_aead_ready = true;
    g_session.rx_aead_ready = true;
    g_session.tx_counter = 0;
    g_session.rx_counter = 0;
    g_session.audio_seq = 0;
    reset_adpcm(&g_session.enc_state);
    reset_adpcm(&g_session.dec_state);
    g_session.handshake_complete = true;
    memset(dh1, 0, sizeof(dh1));
    memset(dh2, 0, sizeof(dh2));
    memset(dh3, 0, sizeof(dh3));
    memset(material, 0, sizeof(material));
    memset(derived, 0, sizeof(derived));
    memset(client_key, 0, sizeof(client_key));
    memset(server_key, 0, sizeof(server_key));
    memset(client_nonce, 0, sizeof(client_nonce));
    memset(server_nonce, 0, sizeof(server_nonce));
    return true;
}

static void queue_handshake_locked(void) {
    uint64_t now = now_monotonic_ms();
    if (!g_session.handshake_ready) {
        __android_log_print(ANDROID_LOG_DEBUG, TAG,
                            "Handshake skip: not ready (role=%d)",
                            g_session.role);
        return;
    }
    if (g_session.last_handshake_ms != 0 &&
        now - g_session.last_handshake_ms < HANDSHAKE_RESEND_MS) {
        return;
    }
    uint8_t payload[HANDSHAKE_PAYLOAD_LEN];
    size_t len = build_handshake_payload_locked(payload, sizeof(payload));
    if (len > 0) {
        queue_frame(FRAME_KIND_HANDSHAKE, payload, (uint16_t)len);
        g_session.last_handshake_ms = now;
        __android_log_print(ANDROID_LOG_DEBUG, TAG,
                            "Queued handshake frame (role=%d, complete=%d, ack=%d)",
                            g_session.role,
                            g_session.handshake_complete ? 1 : 0,
                            g_session.handshake_acknowledged ? 1 : 0);
    }
}

static void queue_control_payload_locked(uint8_t type) {
    uint8_t payload[1] = {type};
    queue_frame(FRAME_KIND_CONTROL, payload, sizeof(payload));
}

static void queue_keepalive_locked(void) {
    queue_control_payload_locked(KEEPALIVE_TYPE);
    g_session.last_keepalive_ms = now_monotonic_ms();
}

static void queue_hangup_locked(void) {
    __android_log_print(ANDROID_LOG_INFO, TAG, "Queueing hangup control frame");
    outgoing_clear();
    queue_control_payload_locked(HANGUP_TYPE);
}

static void queue_audio_frames_locked(void) {
    if (!g_session.handshake_complete) {
        return;
    }
    while (available_int16(&g_mic_size, &g_mic_mutex) >= AUDIO_FRAME_SAMPLES) {
        int16_t pcm[AUDIO_FRAME_SAMPLES];
        size_t pulled = pop_int16_ring(g_mic_ring, MIC_CAPACITY, &g_mic_head, &g_mic_size,
                                       pcm, AUDIO_FRAME_SAMPLES, &g_mic_mutex);
        if (pulled == 0) {
            break;
        }
        uint8_t adpcm_buf[200];
        size_t adpcm_len = adpcm_encode_block(pcm, pulled, adpcm_buf, sizeof(adpcm_buf), &g_session.enc_state);
        if (adpcm_len == 0) {
            break;
        }
        uint8_t plain[MAX_FRAME_BODY];
        if (adpcm_len + 8 > sizeof(plain)) {
            break;
        }
        uint16_t seq = g_session.audio_seq++;
        plain[0] = AUDIO_PAYLOAD_TYPE;
        plain[1] = 1; // codec version
        plain[2] = (uint8_t)(seq & 0xFF);
        plain[3] = (uint8_t)(seq >> 8);
        plain[4] = (uint8_t)(pulled & 0xFF);
        plain[5] = (uint8_t)(pulled >> 8);
        plain[6] = (uint8_t)(adpcm_len & 0xFF);
        plain[7] = (uint8_t)(adpcm_len >> 8);
        memcpy(plain + 8, adpcm_buf, adpcm_len);
        size_t plain_len = adpcm_len + 8;
        if (g_session.outbound_encrypted && g_session.tx_aead_ready) {
            uint8_t cipher[MAX_FRAME_BODY + 16];
            uint8_t nonce[12];
            compose_nonce(nonce, g_session.tx_nonce_base, g_session.tx_counter++);
            crypto_aead_ctx ctx;
            crypto_aead_init_ietf(&ctx, g_session.tx_key, nonce);
            crypto_aead_write(&ctx, cipher, cipher + plain_len,
                              NULL, 0, plain, plain_len);
            crypto_wipe(&ctx, sizeof(ctx));
            queue_frame(FRAME_KIND_CIPHER, cipher, (uint16_t)(plain_len + 16));
        } else {
            queue_frame(FRAME_KIND_PLAINTEXT, plain, (uint16_t)plain_len);
        }
    }
}

static void build_outgoing_locked(void) {
    if (!g_session.active) {
        return;
    }
    bool need_handshake = !g_session.handshake_complete || !g_session.handshake_acknowledged;
    if (need_handshake) {
        queue_handshake_locked();
        if (!g_session.handshake_complete) {
            return;
        }
    }
    queue_audio_frames_locked();
    uint64_t now = now_monotonic_ms();
    if (now - g_session.last_keepalive_ms > KEEPALIVE_INTERVAL_MS) {
        queue_keepalive_locked();
    }
}

static void handle_audio_plain_locked(const uint8_t *data, size_t len) {
    if (len < 8 || data[0] != AUDIO_PAYLOAD_TYPE) {
        return;
    }
    uint16_t sample_count = (uint16_t)(data[4] | (data[5] << 8));
    uint16_t payload_len = (uint16_t)(data[6] | (data[7] << 8));
    if (payload_len + 8 > len) {
        return;
    }
    int16_t pcm_buffer[AUDIO_FRAME_SAMPLES];
    size_t decoded = adpcm_decode_block(data + 8, payload_len, pcm_buffer,
                                        min_size(sample_count, (uint16_t)AUDIO_FRAME_SAMPLES),
                                        &g_session.dec_state);
    if (decoded > 0) {
        push_int16_ring(g_spk_ring, SPK_CAPACITY, &g_spk_head, &g_spk_size,
                        pcm_buffer, decoded, &g_spk_mutex);
    }
}

static void handle_control_plain_locked(const uint8_t *data, size_t len) {
    if (len == 0) {
        return;
    }
    uint8_t subtype = data[0];
    if (subtype == KEEPALIVE_TYPE) {
        g_session.last_keepalive_ms = now_monotonic_ms();
        return;
    }
    if (subtype == HANGUP_TYPE) {
        if (!g_session.remote_hangup_requested) {
            __android_log_print(ANDROID_LOG_INFO, TAG, "Remote hangup signal received");
        }
        g_session.remote_hangup_requested = true;
    }
}

static void handle_encrypted_payload_locked(const uint8_t *data, size_t len, bool encrypted) {
    if (!g_session.handshake_complete) {
        return;
    }
    uint8_t plain[MAX_FRAME_BODY];
    size_t plain_len = len;
    if (encrypted && len > 16 && g_session.rx_aead_ready) {
        size_t cipher_len = len - 16;
        uint8_t nonce[12];
        compose_nonce(nonce, g_session.rx_nonce_base, g_session.rx_counter++);
        crypto_aead_ctx ctx;
        crypto_aead_init_ietf(&ctx, g_session.rx_key, nonce);
        // The tag is at the END of the message in ChaCha20-Poly1305
        // data = [ciphertext (len-16)] [tag (16)]
        // crypto_aead_read expects:
        // - message: output buffer for plaintext
        // - mac: pointer to the tag (last 16 bytes of input)
        // - ad: associated data (NULL here)
        // - ad_size: 0
        // - nonce: the nonce
        // - key: the key
        // - ciphertext: pointer to ciphertext (start of input)
        // - ciphertext_size: length of ciphertext (len - 16)
        if (crypto_aead_read(&ctx, plain, data + cipher_len,
                              NULL, 0, data, cipher_len) != 0) {
            crypto_wipe(&ctx, sizeof(ctx));
            // If decryption fails, we MUST NOT increment the counter, or we will be out of sync forever.
            // Actually, for security we SHOULD increment, but if we are debugging a sync issue,
            // let's log the nonce to see what's happening.
            __android_log_print(ANDROID_LOG_WARN, TAG, "Failed to decrypt frame. Nonce counter: %llu", (unsigned long long)(g_session.rx_counter - 1));
            return;
        }
        crypto_wipe(&ctx, sizeof(ctx));
        plain_len = cipher_len;
        if (!g_session.handshake_acknowledged) {
            g_session.handshake_acknowledged = true;
            __android_log_print(ANDROID_LOG_DEBUG, TAG,
                                "Handshake acknowledged via decrypted frame (role=%d)",
                                g_session.role);
        }
    } else {
        memcpy(plain, data, min_size(len, sizeof(plain)));
        plain_len = min_size(len, sizeof(plain));
    }
    if (plain_len == 0) {
        return;
    }
    if (plain[0] == AUDIO_PAYLOAD_TYPE) {
        handle_audio_plain_locked(plain, plain_len);
    } else {
        handle_control_plain_locked(plain, plain_len);
    }
}

static void handle_handshake_payload_locked(const uint8_t *payload, size_t len) {
    if (len < HANDSHAKE_PAYLOAD_LEN) {
        return;
    }
    uint8_t version = payload[0];
    uint8_t capabilities = payload[2];
    if (version != 1) {
        return;
    }
    __android_log_print(ANDROID_LOG_DEBUG, TAG,
                        "Handshake payload received (role=%d, cap=%u)",
                        g_session.role, capabilities);
    memcpy(g_session.peer_eph_pub, payload + 4, 32);
    memcpy(g_session.peer_static, payload + 36, 32);
    g_session.have_peer_ephemeral = true;
    g_session.have_peer_static = true;
    g_session.peer_accepts_encrypt = (capabilities & 0x02) != 0;
    g_session.peer_sends_encrypt = (capabilities & 0x01) != 0;
    g_session.outbound_encrypted = g_config.encrypt && g_session.peer_accepts_encrypt;
    g_session.inbound_encrypted = g_config.decrypt && g_session.peer_sends_encrypt;
    if (g_session.expect_peer_static &&
        memcmp(g_session.expected_peer_static, g_session.peer_static, 32) != 0) {
        __android_log_print(ANDROID_LOG_ERROR, TAG, "Peer public key mismatch");
        return;
    }
    if (derive_keys_locked()) {
        if (!g_session.handshake_complete) {
            queue_handshake_locked();
        }
        __android_log_print(ANDROID_LOG_DEBUG, TAG,
                            "Handshake complete locally (role=%d)",
                            g_session.role);
        g_session.handshake_complete = true;
    }
}

static void process_incoming_locked(void) {
    while (true) {
        uint8_t header[3];
        if (!incoming_peek(header, sizeof(header))) {
            break;
        }
        uint16_t body_len = (uint16_t)(header[1] | (header[2] << 8));
        if (incoming_size() < body_len + sizeof(header)) {
            break;
        }
        incoming_drop(sizeof(header));
        uint8_t body[MAX_FRAME_BODY + 32];
        if (body_len > sizeof(body)) {
            incoming_drop(body_len);
            continue;
        }
        incoming_read(body, body_len);
        switch (header[0]) {
            case FRAME_KIND_HANDSHAKE:
                handle_handshake_payload_locked(body, body_len);
                break;
            case FRAME_KIND_CIPHER:
                handle_encrypted_payload_locked(body, body_len, true);
                break;
            case FRAME_KIND_PLAINTEXT:
                handle_encrypted_payload_locked(body, body_len, false);
                break;
            default:
                break;
        }
    }
}

// -------------------------------------------------------------------------
// Public NADE API

int nade_init(const uint8_t *seed32) {
    if (!seed32) {
        return -1;
    }
    pthread_mutex_lock(&g_session_mutex);
    memcpy(g_identity_priv, seed32, 32);
    clamp_x25519(g_identity_priv);
    if (!derive_public_key(g_identity_priv, g_identity_pub)) {
        pthread_mutex_unlock(&g_session_mutex);
        return -1;
    }
    g_identity_ready = true;
    session_reset_locked();
    memcpy(g_session.static_priv, g_identity_priv, 32);
    memcpy(g_session.static_pub, g_identity_pub, 32);
    clear_int16_ring(&g_mic_head, &g_mic_size, &g_mic_mutex);
    clear_int16_ring(&g_spk_head, &g_spk_size, &g_spk_mutex);
    outgoing_clear();
    incoming_clear();
    pthread_mutex_unlock(&g_session_mutex);
    return 0;
}

static int start_session_common(const uint8_t *peer_pubkey, size_t len, nade_role_t role) {
    pthread_mutex_lock(&g_session_mutex);
    if (!g_identity_ready) {
        pthread_mutex_unlock(&g_session_mutex);
        return -1;
    }
    session_reset_locked();
    g_session.active = true;
    g_session.role = role;
    if (peer_pubkey && len == 32 && !is_all_zero(peer_pubkey, 32)) {
        memcpy(g_session.expected_peer_static, peer_pubkey, 32);
        g_session.expect_peer_static = true;
    } else {
        g_session.expect_peer_static = false;
    }
    ensure_ephemeral_locked();
    g_session.handshake_ready = true;
    g_session.last_handshake_ms = 0;
    g_session.last_keepalive_ms = now_monotonic_ms();
    g_session.outbound_encrypted = g_config.encrypt;
    g_session.inbound_encrypted = g_config.decrypt;
    pthread_mutex_unlock(&g_session_mutex);
    return 0;
}

int nade_start_session_server(const uint8_t *peer_pubkey, size_t len) {
    return start_session_common(peer_pubkey, len, NADE_ROLE_SERVER);
}

int nade_start_session_client(const uint8_t *peer_pubkey, size_t len) {
    return start_session_common(peer_pubkey, len, NADE_ROLE_CLIENT);
}

int nade_stop_session(void) {
    pthread_mutex_lock(&g_session_mutex);
    session_reset_locked();
    pthread_mutex_unlock(&g_session_mutex);
    clear_int16_ring(&g_mic_head, &g_mic_size, &g_mic_mutex);
    clear_int16_ring(&g_spk_head, &g_spk_size, &g_spk_mutex);
    outgoing_clear();
    incoming_clear();
    return 0;
}

int nade_feed_mic_frame(const int16_t *pcm, size_t samples) {
    if (!pcm || samples == 0) {
        return -1;
    }
    pthread_mutex_lock(&g_session_mutex);
    bool active = g_session.active;
    pthread_mutex_unlock(&g_session_mutex);
    if (!active) {
        return -1;
    }
    push_int16_ring(g_mic_ring, MIC_CAPACITY, &g_mic_head, &g_mic_size, pcm, samples, &g_mic_mutex);
    return 0;
}

size_t nade_generate_outgoing_frame(uint8_t *buffer, size_t max_len) {
    if (!buffer || max_len == 0) {
        return 0;
    }
    pthread_mutex_lock(&g_session_mutex);
    build_outgoing_locked();
    pthread_mutex_unlock(&g_session_mutex);
    return outgoing_pop(buffer, max_len);
}

int nade_handle_incoming_frame(const uint8_t *data, size_t len) {
    if (!data || len == 0) {
        return -1;
    }
    pthread_mutex_lock(&g_session_mutex);
    bool active = g_session.active;
    pthread_mutex_unlock(&g_session_mutex);
    if (!active) {
        return -1;
    }
    incoming_push(data, len);
    pthread_mutex_lock(&g_session_mutex);
    process_incoming_locked();
    pthread_mutex_unlock(&g_session_mutex);
    return 0;
}

int nade_pull_speaker_frame(int16_t *out_buf, size_t max_samples) {
    if (!out_buf || max_samples == 0) {
        return 0;
    }
    return (int)pop_int16_ring(g_spk_ring, SPK_CAPACITY, &g_spk_head, &g_spk_size,
                               out_buf, max_samples, &g_spk_mutex);
}

int nade_send_hangup_signal(void) {
    pthread_mutex_lock(&g_session_mutex);
    bool can_signal = g_session.active;
    __android_log_print(ANDROID_LOG_INFO, TAG,
                        "Hangup signal requested (active=%d)",
                        can_signal ? 1 : 0);
    if (can_signal) {
        queue_hangup_locked();
    }
    pthread_mutex_unlock(&g_session_mutex);
    return can_signal ? 0 : -1;
}

int nade_consume_remote_hangup(void) {
    pthread_mutex_lock(&g_session_mutex);
    bool requested = g_session.remote_hangup_requested;
    g_session.remote_hangup_requested = false;
    pthread_mutex_unlock(&g_session_mutex);
    return requested ? 1 : 0;
}

static bool parse_bool_flag(const char *json, const char *key, bool fallback) {
    const char *found = strstr(json, key);
    if (!found) {
        return fallback;
    }
    const char *colon = strchr(found, ':');
    if (!colon) {
        return fallback;
    }
    const char *ptr = colon + 1;
    while (*ptr == ' ' || *ptr == '\t' || *ptr == '\n' || *ptr == '\r') {
        ++ptr;
    }
    if (strncmp(ptr, "true", 4) == 0) return true;
    if (strncmp(ptr, "false", 5) == 0) return false;
    return fallback;
}
JNIEXPORT jbyteArray JNICALL
Java_com_icing_nade_1flutter_NadeCore_nativeDerivePublicKey(JNIEnv *env, jobject thiz, jbyteArray seed_array) {
    if (!seed_array) {
        return NULL;
    }
    jsize len = (*env)->GetArrayLength(env, seed_array);
    if (len != 32) {
        return NULL;
    }
    uint8_t priv[32];
    uint8_t pub[32];
    (*env)->GetByteArrayRegion(env, seed_array, 0, len, (jbyte *)priv);
    clamp_x25519(priv);
    if (!derive_public_key(priv, pub)) {
        memset(priv, 0, sizeof(priv));
        memset(pub, 0, sizeof(pub));
        return NULL;
    }
    jbyteArray out = (*env)->NewByteArray(env, 32);
    if (!out) {
        memset(priv, 0, sizeof(priv));
        memset(pub, 0, sizeof(pub));
        return NULL;
    }
    (*env)->SetByteArrayRegion(env, out, 0, 32, (const jbyte *)pub);
    memset(priv, 0, sizeof(priv));
    memset(pub, 0, sizeof(pub));
    return out;
}

int nade_set_config(const char *json) {
    if (!json) {
        return -1;
    }
    pthread_mutex_lock(&g_session_mutex);
    g_config.encrypt = parse_bool_flag(json, "\"encrypt\"", g_config.encrypt);
    g_config.decrypt = parse_bool_flag(json, "\"decrypt\"", g_config.decrypt);
    g_fsk_enabled = parse_bool_flag(json, "\"fsk_enabled\"", g_fsk_enabled);
    g_session.outbound_encrypted = g_config.encrypt && g_session.peer_accepts_encrypt;
    g_session.inbound_encrypted = g_config.decrypt && g_session.peer_sends_encrypt;
    pthread_mutex_unlock(&g_session_mutex);
    __android_log_print(ANDROID_LOG_DEBUG, TAG, "Config updated: fsk_enabled=%d", g_fsk_enabled);
    return 0;
}

// -------------------------------------------------------------------------
// 4-FSK Public API

int nade_fsk_set_enabled(bool enabled) {
    pthread_mutex_lock(&g_session_mutex);
    g_fsk_enabled = enabled;
    if (enabled) {
        fsk_reset_state();
    }
    pthread_mutex_unlock(&g_session_mutex);
    __android_log_print(ANDROID_LOG_INFO, TAG, "4-FSK modulation %s", enabled ? "enabled" : "disabled");
    return 0;
}

bool nade_fsk_is_enabled(void) {
    pthread_mutex_lock(&g_session_mutex);
    bool enabled = g_fsk_enabled;
    pthread_mutex_unlock(&g_session_mutex);
    return enabled;
}

// Modulate outgoing frame bytes into PCM audio tones
// Call after nade_generate_outgoing_frame to convert bytes to audio
size_t nade_fsk_modulate(const uint8_t *data, size_t len, int16_t *pcm_out, size_t max_samples) {
    if (!data || len == 0 || !pcm_out || max_samples == 0) {
        return 0;
    }
    if (!g_fsk_enabled) {
        return 0;  // FSK disabled, use raw bytes instead
    }
    return fsk_modulate_buffer(data, len, pcm_out, max_samples);
}

// Demodulate incoming PCM audio into bytes
// Call with received audio samples, then call nade_fsk_pull_demodulated to get bytes
int nade_fsk_feed_audio(const int16_t *pcm, size_t samples) {
    if (!pcm || samples == 0) {
        return -1;
    }
    if (!g_fsk_enabled) {
        return -1;  // FSK disabled
    }
    fsk_demodulate_samples(pcm, samples);
    return 0;
}

// Pull demodulated bytes after feeding audio
size_t nade_fsk_pull_demodulated(uint8_t *out, size_t max_len) {
    if (!out || max_len == 0) {
        return 0;
    }
    return fsk_demod_pull(out, max_len);
}

// Get estimated samples needed to modulate given number of bytes
size_t nade_fsk_samples_for_bytes(size_t byte_count) {
    // 4 symbols per byte, FSK_SAMPLES_PER_SYMBOL samples per symbol
    return byte_count * 4 * FSK_SAMPLES_PER_SYMBOL;
}

// JNI bridge helpers -------------------------------------------------------

JNIEXPORT jint JNICALL
Java_com_icing_nade_1flutter_NadeCore_nativeInit(JNIEnv *env, jobject thiz, jbyteArray seed) {
    (void)thiz;
    if (seed == NULL || (*env)->GetArrayLength(env, seed) < 32) {
        return -1;
    }
    jbyte *ptr = (*env)->GetByteArrayElements(env, seed, NULL);
    int rc = nade_init((const uint8_t *)ptr);
    (*env)->ReleaseByteArrayElements(env, seed, ptr, JNI_ABORT);
    return rc;
}

JNIEXPORT jint JNICALL
Java_com_icing_nade_1flutter_NadeCore_nativeStartServer(JNIEnv *env, jobject thiz, jbyteArray peer) {
    (void)thiz;
    if (peer == NULL) {
        return -1;
    }
    jsize len = (*env)->GetArrayLength(env, peer);
    jbyte *ptr = (*env)->GetByteArrayElements(env, peer, NULL);
    int rc = nade_start_session_server((const uint8_t *)ptr, (size_t)len);
    (*env)->ReleaseByteArrayElements(env, peer, ptr, JNI_ABORT);
    return rc;
}

JNIEXPORT jint JNICALL
Java_com_icing_nade_1flutter_NadeCore_nativeStartClient(JNIEnv *env, jobject thiz, jbyteArray peer) {
    (void)thiz;
    if (peer == NULL) {
        return -1;
    }
    jsize len = (*env)->GetArrayLength(env, peer);
    jbyte *ptr = (*env)->GetByteArrayElements(env, peer, NULL);
    int rc = nade_start_session_client((const uint8_t *)ptr, (size_t)len);
    (*env)->ReleaseByteArrayElements(env, peer, ptr, JNI_ABORT);
    return rc;
}

JNIEXPORT jint JNICALL
Java_com_icing_nade_1flutter_NadeCore_nativeStopSession(JNIEnv *env, jobject thiz) {
    (void)env;
    (void)thiz;
    return nade_stop_session();
}

JNIEXPORT jint JNICALL
Java_com_icing_nade_1flutter_NadeCore_nativeFeedMicFrame(JNIEnv *env, jobject thiz,
                                                         jshortArray samples, jint sample_count) {
    (void)thiz;
    if (samples == NULL) {
        return -1;
    }
    jshort *ptr = (*env)->GetShortArrayElements(env, samples, NULL);
    int rc = nade_feed_mic_frame((const int16_t *)ptr, (size_t)sample_count);
    (*env)->ReleaseShortArrayElements(env, samples, ptr, JNI_ABORT);
    return rc;
}

JNIEXPORT jint JNICALL
Java_com_icing_nade_1flutter_NadeCore_nativePullSpeakerFrame(JNIEnv *env, jobject thiz,
                                                             jshortArray buffer, jint max_samples) {
    (void)thiz;
    if (buffer == NULL) {
        return 0;
    }
    jshort *ptr = (*env)->GetShortArrayElements(env, buffer, NULL);
    int pulled = nade_pull_speaker_frame((int16_t *)ptr, (size_t)max_samples);
    (*env)->ReleaseShortArrayElements(env, buffer, ptr, 0);
    return pulled;
}

JNIEXPORT jint JNICALL
Java_com_icing_nade_1flutter_NadeCore_nativeHandleIncoming(JNIEnv *env, jobject thiz,
                                                           jbyteArray data, jint length) {
    (void)thiz;
    if (data == NULL) {
        return -1;
    }
    jbyte *ptr = (*env)->GetByteArrayElements(env, data, NULL);
    int rc = nade_handle_incoming_frame((const uint8_t *)ptr, (size_t)length);
    (*env)->ReleaseByteArrayElements(env, data, ptr, JNI_ABORT);
    return rc;
}

JNIEXPORT jint JNICALL
Java_com_icing_nade_1flutter_NadeCore_nativeGenerateOutgoing(JNIEnv *env, jobject thiz,
                                                             jbyteArray buffer, jint max_len) {
    (void)thiz;
    if (buffer == NULL) {
        return 0;
    }
    jbyte *ptr = (*env)->GetByteArrayElements(env, buffer, NULL);
    size_t produced = nade_generate_outgoing_frame((uint8_t *)ptr, (size_t)max_len);
    (*env)->ReleaseByteArrayElements(env, buffer, ptr, 0);
    return (jint)produced;
}

JNIEXPORT jint JNICALL
Java_com_icing_nade_1flutter_NadeCore_nativeSendHangupSignal(JNIEnv *env, jobject thiz) {
    (void)env;
    (void)thiz;
    return nade_send_hangup_signal();
}

JNIEXPORT jboolean JNICALL
Java_com_icing_nade_1flutter_NadeCore_nativeConsumeRemoteHangup(JNIEnv *env, jobject thiz) {
    (void)env;
    (void)thiz;
    return nade_consume_remote_hangup() ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jint JNICALL
Java_com_icing_nade_1flutter_NadeCore_nativeSetConfig(JNIEnv *env, jobject thiz, jstring json) {
    (void)thiz;
    if (json == NULL) {
        return -1;
    }
    const char *chars = (*env)->GetStringUTFChars(env, json, NULL);
    int rc = nade_set_config(chars);
    (*env)->ReleaseStringUTFChars(env, json, chars);
    return rc;
}

// -------------------------------------------------------------------------
// 4-FSK JNI Bridge

JNIEXPORT jint JNICALL
Java_com_icing_nade_1flutter_NadeCore_nativeFskSetEnabled(JNIEnv *env, jobject thiz, jboolean enabled) {
    (void)env;
    (void)thiz;
    return nade_fsk_set_enabled(enabled == JNI_TRUE);
}

JNIEXPORT jboolean JNICALL
Java_com_icing_nade_1flutter_NadeCore_nativeFskIsEnabled(JNIEnv *env, jobject thiz) {
    (void)env;
    (void)thiz;
    return nade_fsk_is_enabled() ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jint JNICALL
Java_com_icing_nade_1flutter_NadeCore_nativeFskModulate(JNIEnv *env, jobject thiz,
                                                         jbyteArray data, jint data_len,
                                                         jshortArray pcm_out, jint max_samples) {
    (void)thiz;
    if (data == NULL || pcm_out == NULL) {
        return 0;
    }
    jbyte *data_ptr = (*env)->GetByteArrayElements(env, data, NULL);
    jshort *pcm_ptr = (*env)->GetShortArrayElements(env, pcm_out, NULL);
    
    size_t produced = nade_fsk_modulate((const uint8_t *)data_ptr, (size_t)data_len,
                                        (int16_t *)pcm_ptr, (size_t)max_samples);
    
    (*env)->ReleaseByteArrayElements(env, data, data_ptr, JNI_ABORT);
    (*env)->ReleaseShortArrayElements(env, pcm_out, pcm_ptr, 0);
    return (jint)produced;
}

JNIEXPORT jint JNICALL
Java_com_icing_nade_1flutter_NadeCore_nativeFskFeedAudio(JNIEnv *env, jobject thiz,
                                                          jshortArray pcm, jint samples) {
    (void)thiz;
    if (pcm == NULL) {
        return -1;
    }
    jshort *ptr = (*env)->GetShortArrayElements(env, pcm, NULL);
    int rc = nade_fsk_feed_audio((const int16_t *)ptr, (size_t)samples);
    (*env)->ReleaseShortArrayElements(env, pcm, ptr, JNI_ABORT);
    return rc;
}

JNIEXPORT jint JNICALL
Java_com_icing_nade_1flutter_NadeCore_nativeFskPullDemodulated(JNIEnv *env, jobject thiz,
                                                                jbyteArray out, jint max_len) {
    (void)thiz;
    if (out == NULL) {
        return 0;
    }
    jbyte *ptr = (*env)->GetByteArrayElements(env, out, NULL);
    size_t pulled = nade_fsk_pull_demodulated((uint8_t *)ptr, (size_t)max_len);
    (*env)->ReleaseByteArrayElements(env, out, ptr, 0);
    return (jint)pulled;
}

JNIEXPORT jint JNICALL
Java_com_icing_nade_1flutter_NadeCore_nativeFskSamplesForBytes(JNIEnv *env, jobject thiz, jint byte_count) {
    (void)env;
    (void)thiz;
    return (jint)nade_fsk_samples_for_bytes((size_t)byte_count);
}
