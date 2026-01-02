/*
 * Reed-Solomon Error Correction for NADE Protocol
 * 
 * Implements RS(255, 223) over GF(2^8) with generator polynomial x^8 + x^4 + x^3 + x^2 + 1
 * Can correct up to 16 byte errors per 255-byte block (32 parity bytes)
 * 
 * Optimized for real-time audio transmission over noisy channels (4-FSK, radio, etc.)
 */

#ifndef REED_SOLOMON_H
#define REED_SOLOMON_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// RS(255, 223) parameters - can correct up to 16 symbol errors
#define RS_SYMBOL_SIZE      8       // Bits per symbol (GF(2^8))
#define RS_BLOCK_SIZE       255     // Total codeword length (n)
#define RS_DATA_SIZE        223     // Data bytes per block (k)
#define RS_PARITY_SIZE      32      // Parity bytes (n - k = 2t where t=16)
#define RS_CORRECT_CAPABLE  16      // Can correct up to t symbol errors

// For smaller packets, we use shortened RS codes
// RS(n, k) where n <= 255 and parity = RS_PARITY_SIZE
#define RS_MIN_DATA_SIZE    1       // Minimum data bytes

// Initialize Reed-Solomon encoder/decoder (call once at startup)
void rs_init(void);

// Encode data with Reed-Solomon parity
// Input: data[0..data_len-1] where data_len <= RS_DATA_SIZE
// Output: out[0..data_len+RS_PARITY_SIZE-1] (data followed by parity)
// Returns: total encoded length (data_len + RS_PARITY_SIZE)
size_t rs_encode(const uint8_t *data, size_t data_len, uint8_t *out);

// Decode and correct errors in Reed-Solomon codeword
// Input/Output: codeword[0..len-1] where len = data_len + RS_PARITY_SIZE
// The data portion is corrected in-place
// Returns: number of errors corrected, or -1 if uncorrectable
int rs_decode(uint8_t *codeword, size_t len);

// Check if a codeword has errors (without correcting)
// Returns: true if codeword is valid (no errors or correctable errors)
bool rs_check(const uint8_t *codeword, size_t len);

// Get the data length from an encoded block
// encoded_len = data_len + RS_PARITY_SIZE
static inline size_t rs_data_len(size_t encoded_len) {
    return (encoded_len > RS_PARITY_SIZE) ? (encoded_len - RS_PARITY_SIZE) : 0;
}

// Get the encoded length for a given data length
static inline size_t rs_encoded_len(size_t data_len) {
    return data_len + RS_PARITY_SIZE;
}

#ifdef __cplusplus
}
#endif

#endif // REED_SOLOMON_H
