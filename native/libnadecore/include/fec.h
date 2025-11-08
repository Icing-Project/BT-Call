/**
 * Forward Error Correction (Reed-Solomon)
 * 
 * Provides error correction for lossy audio channels
 */

#ifndef FEC_H
#define FEC_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Standard RS configurations
#define FEC_RS_255_223 0  // 32 parity bytes, corrects 16 errors
#define FEC_RS_255_239 1  // 16 parity bytes, corrects 8 errors
#define FEC_RS_255_247 2  // 8 parity bytes, corrects 4 errors

typedef struct fec_context fec_context_t;

/**
 * Create FEC context.
 * 
 * @param config FEC configuration (FEC_RS_255_223, etc.)
 * @return FEC context or NULL on error
 */
fec_context_t *fec_create(int config);

/**
 * Destroy FEC context.
 */
void fec_destroy(fec_context_t *ctx);

/**
 * Encode data with FEC (add parity bytes).
 * 
 * @param ctx FEC context
 * @param data Input data
 * @param data_len Length of input data (must be <= data bytes for RS config)
 * @param out_encoded Output buffer (must fit data + parity)
 * @param out_len Output length (will be set to data_len + parity_len)
 * @return 0 on success, -1 on error
 */
int fec_encode(fec_context_t *ctx, const uint8_t *data, size_t data_len,
               uint8_t *out_encoded, size_t *out_len);

/**
 * Decode data with FEC (correct errors).
 * 
 * @param ctx FEC context
 * @param encoded Input encoded data (data + parity)
 * @param encoded_len Length of encoded data
 * @param out_decoded Output buffer for corrected data
 * @param out_len Output data length
 * @return Number of errors corrected (>= 0), or -1 if uncorrectable
 */
int fec_decode(fec_context_t *ctx, const uint8_t *encoded, size_t encoded_len,
               uint8_t *out_decoded, size_t *out_len);

/**
 * Get number of data bytes for current configuration.
 */
int fec_get_data_bytes(fec_context_t *ctx);

/**
 * Get number of parity bytes for current configuration.
 */
int fec_get_parity_bytes(fec_context_t *ctx);

/**
 * Get total block size (data + parity).
 */
int fec_get_block_size(fec_context_t *ctx);

#ifdef __cplusplus
}
#endif

#endif // FEC_H
