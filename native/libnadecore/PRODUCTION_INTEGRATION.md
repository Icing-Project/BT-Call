# Production Library Integration Guide

This guide explains how to replace the simplified placeholder implementations with production-ready cryptographic and codec libraries.

---

## Overview

Currently, NADE uses simplified implementations for:
1. **Noise XK Handshake** - Simplified DH and key derivation
2. **Codec2** - Simplified ADPCM-like encoding
3. **Reed-Solomon FEC** - Simplified GF arithmetic
4. **ChaCha20-Poly1305** - Working but could use libsodium for assurance

These work for testing the pipeline but should be replaced for production use.

---

## Option 1: Full Production Stack (Recommended)

### Dependencies Required

```cmake
# native/libnadecore/CMakeLists.txt

# Fetch dependencies using CMake FetchContent
include(FetchContent)

# 1. noise-c (Noise Protocol Framework)
FetchContent_Declare(
  noise-c
  GIT_REPOSITORY https://github.com/rweather/noise-c.git
  GIT_TAG master
)

# 2. codec2 (Voice Codec)
FetchContent_Declare(
  codec2
  GIT_REPOSITORY https://github.com/drowe67/codec2.git
  GIT_TAG master
)

# 3. libsodium (Crypto primitives)
FetchContent_Declare(
  libsodium
  GIT_REPOSITORY https://github.com/jedisct1/libsodium.git
  GIT_TAG stable
)

FetchContent_MakeAvailable(noise-c codec2 libsodium)

# Link to nadecore
target_link_libraries(nadecore noise codec2 sodium)
```

### 1. Integrate noise-c for Handshake

**Update `handshake.c`:**

```c
#include <noise/protocol.h>
#include "handshake.h"

struct handshake_context {
    NoiseHandshakeState *handshake;
    NoiseDHState *dh_local;
    uint8_t local_static_key[32];
    uint8_t local_ephemeral_key[32];
    uint8_t remote_static_key[32];
    uint8_t session_key_send[32];
    uint8_t session_key_recv[32];
    int is_initiator;
};

handshake_context_t *handshake_create(int is_initiator) {
    handshake_context_t *ctx = calloc(1, sizeof(handshake_context_t));
    if (!ctx) return NULL;
    
    ctx->is_initiator = is_initiator;
    
    // Create Noise handshake state for XK pattern
    int err = noise_handshakestate_new_by_name(
        &ctx->handshake,
        is_initiator ? "Noise_XK_25519_ChaChaPoly_BLAKE2s" 
                     : "Noise_XK_25519_ChaChaPoly_BLAKE2s",
        is_initiator ? NOISE_ROLE_INITIATOR : NOISE_ROLE_RESPONDER
    );
    
    if (err != NOISE_ERROR_NONE) {
        free(ctx);
        return NULL;
    }
    
    // Generate local static keypair
    NoiseDHState *dh;
    noise_handshakestate_get_local_keypair_dh(ctx->handshake, &dh);
    noise_dhstate_generate_keypair(dh);
    
    return ctx;
}

int handshake_start(handshake_context_t *ctx, const uint8_t *remote_static_pubkey,
                    uint8_t *out_message, size_t *out_len) {
    if (!ctx || !out_message || !out_len) return -1;
    
    // Set remote static key if responder
    if (!ctx->is_initiator && remote_static_pubkey) {
        NoiseDHState *remote_dh;
        noise_handshakestate_get_remote_public_key_dh(ctx->handshake, &remote_dh);
        noise_dhstate_set_public_key(remote_dh, remote_static_pubkey, 32);
    }
    
    // Write first message
    NoiseBuffer mbuf;
    noise_buffer_set_output(mbuf, out_message, *out_len);
    
    int err = noise_handshakestate_write_message(ctx->handshake, &mbuf, NULL);
    if (err != NOISE_ERROR_NONE) return -1;
    
    *out_len = mbuf.size;
    return 0;
}

int handshake_process_message(handshake_context_t *ctx, 
                               const uint8_t *in_message, size_t in_len,
                               uint8_t *out_message, size_t *out_len) {
    if (!ctx || !in_message) return -1;
    
    // Read incoming message
    NoiseBuffer in_buf, out_buf;
    noise_buffer_set_input(in_buf, (uint8_t *)in_message, in_len);
    
    int err = noise_handshakestate_read_message(ctx->handshake, &in_buf, NULL);
    if (err != NOISE_ERROR_NONE) return -1;
    
    // Write response if needed
    if (out_message && out_len && *out_len > 0) {
        noise_buffer_set_output(out_buf, out_message, *out_len);
        err = noise_handshakestate_write_message(ctx->handshake, &out_buf, NULL);
        if (err != NOISE_ERROR_NONE) return -1;
        *out_len = out_buf.size;
    }
    
    return 0;
}

int handshake_get_keys(handshake_context_t *ctx, uint8_t *session_key_send,
                       uint8_t *session_key_recv) {
    if (!ctx || !session_key_send || !session_key_recv) return -1;
    
    // Split handshake to get cipher states
    NoiseCipherState *send_cipher, *recv_cipher;
    int err = noise_handshakestate_split(ctx->handshake, &send_cipher, &recv_cipher);
    if (err != NOISE_ERROR_NONE) return -1;
    
    // Extract keys from cipher states
    noise_cipherstate_get_key(send_cipher, session_key_send, 32);
    noise_cipherstate_get_key(recv_cipher, session_key_recv, 32);
    
    noise_cipherstate_free(send_cipher);
    noise_cipherstate_free(recv_cipher);
    
    return 0;
}

void handshake_destroy(handshake_context_t *ctx) {
    if (ctx) {
        if (ctx->handshake) {
            noise_handshakestate_free(ctx->handshake);
        }
        free(ctx);
    }
}
```

---

### 2. Integrate codec2 for Voice

**Update `codec.c`:**

```c
#include <codec2/codec2.h>
#include "codec.h"

struct codec_context {
    struct CODEC2 *c2;
    int mode;
    int samples_per_frame;
    int bits_per_frame;
};

codec_context_t *codec_create(int mode) {
    codec_context_t *ctx = calloc(1, sizeof(codec_context_t));
    if (!ctx) return NULL;
    
    ctx->mode = mode;
    
    // Map our mode to codec2 mode
    int c2_mode;
    switch (mode) {
        case 3200: c2_mode = CODEC2_MODE_3200; break;
        case 2400: c2_mode = CODEC2_MODE_2400; break;
        case 1600: c2_mode = CODEC2_MODE_1600; break;
        case 1400: c2_mode = CODEC2_MODE_1400; break;
        case 1300: c2_mode = CODEC2_MODE_1300; break;
        case 1200: c2_mode = CODEC2_MODE_1200; break;
        case 700:  c2_mode = CODEC2_MODE_700C; break;
        default:   c2_mode = CODEC2_MODE_1400; break;
    }
    
    ctx->c2 = codec2_create(c2_mode);
    if (!ctx->c2) {
        free(ctx);
        return NULL;
    }
    
    ctx->samples_per_frame = codec2_samples_per_frame(ctx->c2);
    ctx->bits_per_frame = codec2_bits_per_frame(ctx->c2);
    
    return ctx;
}

int codec_encode(codec_context_t *ctx, const int16_t *pcm_in, size_t num_samples,
                 uint8_t *bits_out, size_t *bits_len) {
    if (!ctx || !pcm_in || !bits_out || !bits_len) return -1;
    
    // Codec2 expects exactly samples_per_frame samples
    if (num_samples != ctx->samples_per_frame) return -1;
    
    // Encode
    codec2_encode(ctx->c2, bits_out, (short *)pcm_in);
    
    *bits_len = (ctx->bits_per_frame + 7) / 8; // Bits to bytes
    
    return 0;
}

int codec_decode(codec_context_t *ctx, const uint8_t *bits_in, size_t bits_len,
                 int16_t *pcm_out, size_t *num_samples) {
    if (!ctx || !bits_in || !pcm_out || !num_samples) return -1;
    
    // Decode
    codec2_decode(ctx->c2, (short *)pcm_out, (unsigned char *)bits_in);
    
    *num_samples = ctx->samples_per_frame;
    
    return 0;
}

void codec_destroy(codec_context_t *ctx) {
    if (ctx) {
        if (ctx->c2) {
            codec2_destroy(ctx->c2);
        }
        free(ctx);
    }
}
```

---

### 3. Integrate libfec for Reed-Solomon

**Option A: Use existing libfec**

```c
#include <fec.h>
#include "fec.h"

struct fec_context {
    void *rs_handle;
    int data_bytes;
    int parity_bytes;
};

fec_context_t *fec_create(int config) {
    fec_context_t *ctx = calloc(1, sizeof(fec_context_t));
    if (!ctx) return NULL;
    
    switch (config) {
        case FEC_RS_255_223:
            ctx->data_bytes = 223;
            ctx->parity_bytes = 32;
            break;
        // ... other configs
    }
    
    // Initialize RS codec from libfec
    ctx->rs_handle = init_rs_char(8, 0x187, 112, 11, ctx->parity_bytes, 0);
    if (!ctx->rs_handle) {
        free(ctx);
        return NULL;
    }
    
    return ctx;
}

int fec_encode(fec_context_t *ctx, const uint8_t *data, size_t data_len,
               uint8_t *out_encoded, size_t *out_len) {
    if (!ctx || !data || !out_encoded) return -1;
    
    // Copy data
    memcpy(out_encoded, data, ctx->data_bytes);
    
    // Generate parity
    encode_rs_char(ctx->rs_handle, (unsigned char *)out_encoded, 
                   out_encoded + ctx->data_bytes);
    
    *out_len = ctx->data_bytes + ctx->parity_bytes;
    return 0;
}

int fec_decode(fec_context_t *ctx, const uint8_t *encoded, size_t encoded_len,
               uint8_t *out_decoded, size_t *out_len) {
    if (!ctx || !encoded || !out_decoded) return -1;
    
    uint8_t work[256];
    memcpy(work, encoded, 255);
    
    // Decode with error correction
    int errors = decode_rs_char(ctx->rs_handle, work, NULL, 0);
    
    if (errors < 0) return -1; // Uncorrectable
    
    memcpy(out_decoded, work, ctx->data_bytes);
    *out_len = ctx->data_bytes;
    
    return errors;
}
```

---

### 4. Optionally Use libsodium for Crypto

**Update `crypto.c`:**

```c
#include <sodium.h>
#include "crypto.h"

struct crypto_context {
    uint8_t key[CRYPTO_KEY_SIZE];
};

crypto_context_t *crypto_create(const uint8_t *key) {
    if (sodium_init() < 0) return NULL;
    
    crypto_context_t *ctx = malloc(sizeof(crypto_context_t));
    if (!ctx) return NULL;
    
    memcpy(ctx->key, key, CRYPTO_KEY_SIZE);
    return ctx;
}

int crypto_encrypt(crypto_context_t *ctx, const uint8_t *nonce,
                   const uint8_t *plaintext, size_t plaintext_len,
                   const uint8_t *ad, size_t ad_len,
                   uint8_t *out_ciphertext, size_t *out_len) {
    if (!ctx || !nonce || !plaintext || !out_ciphertext) return -1;
    
    unsigned long long ciphertext_len;
    
    int result = crypto_aead_chacha20poly1305_ietf_encrypt(
        out_ciphertext, &ciphertext_len,
        plaintext, plaintext_len,
        ad, ad_len,
        NULL, nonce, ctx->key
    );
    
    if (result != 0) return -1;
    
    *out_len = ciphertext_len;
    return 0;
}

int crypto_decrypt(crypto_context_t *ctx, const uint8_t *nonce,
                   const uint8_t *ciphertext, size_t ciphertext_len,
                   const uint8_t *ad, size_t ad_len,
                   uint8_t *out_plaintext, size_t *out_len) {
    if (!ctx || !nonce || !ciphertext || !out_plaintext) return -1;
    
    unsigned long long plaintext_len;
    
    int result = crypto_aead_chacha20poly1305_ietf_decrypt(
        out_plaintext, &plaintext_len,
        NULL,
        ciphertext, ciphertext_len,
        ad, ad_len,
        nonce, ctx->key
    );
    
    if (result != 0) return -1; // Authentication failed
    
    *out_len = plaintext_len;
    return 0;
}
```

---

## Option 2: Keep Simplified Implementations

If you want to avoid third-party dependencies, the current simplified implementations can work with these improvements:

### 1. Handshake: Add X25519 and HKDF

Use `libsodium` or `monocypher` (single-file library) for just X25519 and HKDF:

```c
// Use monocypher (single .c and .h file)
#include "monocypher.h"

// In handshake.c
void generate_keypair(uint8_t *secret, uint8_t *public) {
    crypto_x25519_public_key(public, secret);
}

void compute_dh(const uint8_t *my_secret, const uint8_t *their_public, 
                uint8_t *shared_secret) {
    crypto_x25519(shared_secret, my_secret, their_public);
}
```

### 2. FEC: Improve RS Implementation

The current GF arithmetic is correct but error correction is simplified. Implement:
- Syndrome calculation
- Berlekamp-Massey algorithm for error locator polynomial
- Chien search for error positions
- Forney algorithm for error values

This is complex but well-documented in literature.

---

## Build Instructions

### Android (with FetchContent dependencies)

```bash
cd android
./gradlew assembleDebug
```

CMake will automatically fetch and build dependencies.

### Manual Git Submodules (Alternative)

```bash
cd native/libnadecore
mkdir third_party
cd third_party

git submodule add https://github.com/rweather/noise-c
git submodule add https://github.com/drowe67/codec2
git submodule add https://github.com/jedisct1/libsodium

cd ..
# Update CMakeLists.txt to add_subdirectory for each
```

---

## Testing After Integration

1. **Unit Test Each Component:**
   - Test Noise handshake with known test vectors
   - Test Codec2 with sample audio
   - Test RS FEC with random bit flips
   - Test ChaCha20-Poly1305 with IETF test vectors

2. **Integration Test:**
   - Loopback mode (encode → decode in same process)
   - Two Android devices
   - Inject errors and verify FEC corrects them

3. **Performance:**
   - Profile CPU usage
   - Check latency (should be <100ms)
   - Monitor battery drain

---

## Recommended Approach

1. **Start with libsodium only** (easiest):
   - Just for crypto primitives (X25519, ChaCha20-Poly1305, HKDF)
   - Keep simplified codec and FEC for now
   - This gets you secure handshake and encryption immediately

2. **Add codec2** (medium difficulty):
   - Replace codec.c with real codec2
   - Test audio quality
   - Tune for your use case (1400 bps recommended)

3. **Add libfec** (harder):
   - Replace fec.c with proper RS implementation
   - Test error correction capacity
   - Validate with bit error injection

4. **Add noise-c** (optional, if you want full Noise protocol):
   - Only if you need advanced features
   - Otherwise, libsodium + your handshake code is sufficient

---

## Minimal Production-Ready Stack

For fastest path to production:

```cmake
# Just add libsodium
FetchContent_Declare(
  libsodium
  GIT_REPOSITORY https://github.com/jedisct1/libsodium.git
  GIT_TAG stable
)
FetchContent_MakeAvailable(libsodium)

target_link_libraries(nadecore sodium)
```

Then update:
- `handshake.c`: Use `crypto_kx_*` for key exchange
- `crypto.c`: Use `crypto_aead_chacha20poly1305_ietf_*`

This gives you:
- ✅ X25519 key exchange
- ✅ ChaCha20-Poly1305 AEAD
- ✅ HKDF for key derivation
- ✅ Constant-time operations
- ✅ Well-tested, audited crypto

Keep simplified codec and FEC for now, add those later as needed.

---

## Summary

| Component | Current State | Production Option | Complexity |
|-----------|---------------|-------------------|------------|
| Handshake | Simplified DH | libsodium crypto_kx | Easy |
| Codec | ADPCM-like | codec2 | Medium |
| FEC | Simplified RS | libfec | Medium |
| Crypto | Working ChaCha20 | libsodium AEAD | Easy |

**Recommended First Step:** Add libsodium for crypto (handshake + AEAD). This is the highest security priority and easiest integration. Test thoroughly, then add codec2 and libfec when needed.
