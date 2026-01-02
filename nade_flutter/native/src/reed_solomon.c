/*
 * Reed-Solomon Error Correction Implementation
 * 
 * RS(255, 223) over GF(2^8) using primitive polynomial x^8 + x^4 + x^3 + x^2 + 1
 * This is the same field used by CCSDS, DVB, and QR codes.
 * 
 * Can correct up to 16 byte errors per 255-byte block.
 * Supports shortened codes for smaller packets.
 */

#include "reed_solomon.h"
#include <string.h>

// Primitive polynomial: x^8 + x^4 + x^3 + x^2 + 1 = 0x11D
#define RS_PRIMITIVE_POLY   0x11D
#define RS_FIELD_SIZE       256     // 2^8 elements in GF(2^8)
#define RS_GENERATOR_ROOT   2       // First consecutive root (alpha^1)

// Galois Field lookup tables
static uint8_t gf_exp[512];     // Anti-log table (extended for easy multiplication)
static uint8_t gf_log[256];     // Log table
static uint8_t gf_generator[RS_PARITY_SIZE + 1];  // Generator polynomial coefficients
static bool rs_initialized = false;

// -------------------------------------------------------------------------
// Galois Field GF(2^8) Arithmetic
// -------------------------------------------------------------------------

// Initialize GF(2^8) lookup tables
static void gf_init(void) {
    uint16_t x = 1;
    for (int i = 0; i < 255; i++) {
        gf_exp[i] = (uint8_t)x;
        gf_log[x] = (uint8_t)i;
        x <<= 1;
        if (x & 0x100) {
            x ^= RS_PRIMITIVE_POLY;
        }
    }
    // Extend exp table for easier modular reduction
    for (int i = 255; i < 512; i++) {
        gf_exp[i] = gf_exp[i - 255];
    }
    gf_log[0] = 0;  // log(0) is undefined, but we set to 0 for convenience
}

// Multiply two elements in GF(2^8)
static inline uint8_t gf_mul(uint8_t a, uint8_t b) {
    if (a == 0 || b == 0) return 0;
    return gf_exp[gf_log[a] + gf_log[b]];
}

// Divide in GF(2^8): a / b
static inline uint8_t gf_div(uint8_t a, uint8_t b) {
    if (a == 0) return 0;
    if (b == 0) return 0;  // Division by zero - shouldn't happen
    return gf_exp[(gf_log[a] + 255 - gf_log[b]) % 255];
}

// Compute a^n in GF(2^8)
static inline uint8_t gf_pow(uint8_t a, int n) {
    if (n == 0) return 1;
    if (a == 0) return 0;
    return gf_exp[(gf_log[a] * n) % 255];
}

// Inverse in GF(2^8)
static inline uint8_t gf_inv(uint8_t a) {
    if (a == 0) return 0;
    return gf_exp[255 - gf_log[a]];
}

// -------------------------------------------------------------------------
// Polynomial Operations over GF(2^8)
// -------------------------------------------------------------------------

// Multiply polynomial by (x - alpha^n)
// poly has degree 'degree', result has degree 'degree + 1'
static void poly_mul_term(uint8_t *poly, int degree, int n) {
    uint8_t root = gf_exp[n];  // alpha^n
    
    // Start from highest degree, work down
    for (int i = degree; i >= 0; i--) {
        poly[i + 1] ^= poly[i];
        poly[i] = gf_mul(poly[i], root);
    }
}

// Evaluate polynomial at x = alpha^n
static uint8_t poly_eval(const uint8_t *poly, int degree, int n) {
    uint8_t x = gf_exp[n];
    uint8_t result = poly[degree];
    for (int i = degree - 1; i >= 0; i--) {
        result = gf_mul(result, x) ^ poly[i];
    }
    return result;
}

// -------------------------------------------------------------------------
// Generator Polynomial
// g(x) = (x - α^1)(x - α^2)...(x - α^32)
// -------------------------------------------------------------------------

static void build_generator(void) {
    memset(gf_generator, 0, sizeof(gf_generator));
    gf_generator[0] = 1;  // Start with 1
    
    for (int i = 0; i < RS_PARITY_SIZE; i++) {
        poly_mul_term(gf_generator, i, RS_GENERATOR_ROOT + i);
    }
}

// -------------------------------------------------------------------------
// Reed-Solomon Encoding
// -------------------------------------------------------------------------

void rs_init(void) {
    if (rs_initialized) return;
    gf_init();
    build_generator();
    rs_initialized = true;
}

size_t rs_encode(const uint8_t *data, size_t data_len, uint8_t *out) {
    if (!rs_initialized) rs_init();
    if (data_len == 0 || data_len > RS_DATA_SIZE) {
        return 0;
    }
    
    // Copy data to output
    memcpy(out, data, data_len);
    
    // Initialize parity bytes to zero
    memset(out + data_len, 0, RS_PARITY_SIZE);
    
    // Systematic encoding: divide message polynomial by generator
    // This computes remainder which becomes the parity
    uint8_t feedback;
    for (size_t i = 0; i < data_len; i++) {
        feedback = out[i] ^ out[data_len];
        if (feedback != 0) {
            for (int j = 1; j < RS_PARITY_SIZE; j++) {
                out[data_len + j - 1] = out[data_len + j] ^ gf_mul(feedback, gf_generator[RS_PARITY_SIZE - j]);
            }
            out[data_len + RS_PARITY_SIZE - 1] = gf_mul(feedback, gf_generator[0]);
        } else {
            // Shift parity registers
            memmove(out + data_len, out + data_len + 1, RS_PARITY_SIZE - 1);
            out[data_len + RS_PARITY_SIZE - 1] = 0;
        }
    }
    
    return data_len + RS_PARITY_SIZE;
}

// -------------------------------------------------------------------------
// Reed-Solomon Decoding (Berlekamp-Massey + Forney)
// -------------------------------------------------------------------------

// Compute syndromes S_1 through S_32
static void compute_syndromes(const uint8_t *codeword, size_t len, uint8_t *syndromes) {
    // For shortened codes, we need to account for virtual leading zeros
    size_t pad = RS_BLOCK_SIZE - len;
    
    for (int i = 0; i < RS_PARITY_SIZE; i++) {
        uint8_t sum = 0;
        uint8_t alpha_power = 1;
        uint8_t alpha = gf_exp[RS_GENERATOR_ROOT + i];
        
        // Account for shortened code (virtual leading zeros)
        for (size_t j = 0; j < pad; j++) {
            alpha_power = gf_mul(alpha_power, alpha);
        }
        
        // Evaluate at alpha^(i+1)
        for (size_t j = 0; j < len; j++) {
            sum ^= gf_mul(codeword[j], alpha_power);
            alpha_power = gf_mul(alpha_power, alpha);
        }
        syndromes[i] = sum;
    }
}

// Check if all syndromes are zero (no errors)
static bool syndromes_zero(const uint8_t *syndromes) {
    for (int i = 0; i < RS_PARITY_SIZE; i++) {
        if (syndromes[i] != 0) return false;
    }
    return true;
}

// Berlekamp-Massey algorithm to find error locator polynomial
// Returns degree of error locator, or -1 on failure
static int berlekamp_massey(const uint8_t *syndromes, uint8_t *sigma) {
    uint8_t C[RS_PARITY_SIZE + 1];    // Error locator polynomial
    uint8_t B[RS_PARITY_SIZE + 1];    // Previous polynomial
    uint8_t T[RS_PARITY_SIZE + 1];    // Temporary
    
    memset(C, 0, sizeof(C));
    memset(B, 0, sizeof(B));
    C[0] = 1;
    B[0] = 1;
    
    int L = 0;      // Current length
    int m = 1;      // Shift amount
    uint8_t b = 1;  // Previous discrepancy
    
    for (int n = 0; n < RS_PARITY_SIZE; n++) {
        // Compute discrepancy
        uint8_t d = syndromes[n];
        for (int i = 1; i <= L; i++) {
            d ^= gf_mul(C[i], syndromes[n - i]);
        }
        
        if (d == 0) {
            m++;
        } else if (2 * L <= n) {
            // Copy C to T
            memcpy(T, C, sizeof(T));
            
            // C(x) = C(x) - d*b^-1 * x^m * B(x)
            uint8_t coef = gf_mul(d, gf_inv(b));
            for (int i = 0; i + m <= RS_PARITY_SIZE; i++) {
                C[i + m] ^= gf_mul(coef, B[i]);
            }
            
            L = n + 1 - L;
            memcpy(B, T, sizeof(B));
            b = d;
            m = 1;
        } else {
            // C(x) = C(x) - d*b^-1 * x^m * B(x)
            uint8_t coef = gf_mul(d, gf_inv(b));
            for (int i = 0; i + m <= RS_PARITY_SIZE; i++) {
                C[i + m] ^= gf_mul(coef, B[i]);
            }
            m++;
        }
    }
    
    memcpy(sigma, C, (L + 1) * sizeof(uint8_t));
    return L;
}

// Chien search to find error positions
// Returns number of roots found, positions stored in error_pos
static int chien_search(const uint8_t *sigma, int degree, size_t n, int *error_pos) {
    int count = 0;
    size_t pad = RS_BLOCK_SIZE - n;
    
    // Evaluate sigma at alpha^-i for i = 0 to n-1
    for (size_t i = 0; i < n; i++) {
        // Position in full 255-byte block
        size_t full_pos = pad + i;
        
        // Evaluate sigma at alpha^-(255 - full_pos)
        int exp = 255 - full_pos;
        uint8_t sum = sigma[0];
        for (int j = 1; j <= degree; j++) {
            sum ^= gf_mul(sigma[j], gf_exp[(exp * j) % 255]);
        }
        
        if (sum == 0) {
            error_pos[count++] = (int)i;
            if (count >= degree) break;  // Found all roots
        }
    }
    
    return count;
}

// Forney algorithm to compute error values
static void forney_algorithm(const uint8_t *syndromes, const uint8_t *sigma, int sigma_deg,
                              const int *error_pos, int error_count, size_t n, uint8_t *error_val) {
    // Compute error evaluator polynomial omega(x) = S(x) * sigma(x) mod x^(2t)
    uint8_t omega[RS_PARITY_SIZE];
    memset(omega, 0, sizeof(omega));
    
    for (int i = 0; i < RS_PARITY_SIZE; i++) {
        for (int j = 0; j <= sigma_deg && j <= i; j++) {
            omega[i] ^= gf_mul(syndromes[i - j], sigma[j]);
        }
    }
    
    // Compute sigma'(x) (formal derivative)
    uint8_t sigma_prime[RS_PARITY_SIZE + 1];
    memset(sigma_prime, 0, sizeof(sigma_prime));
    for (int i = 1; i <= sigma_deg; i += 2) {  // Only odd powers contribute in GF(2^m)
        sigma_prime[i - 1] = sigma[i];
    }
    
    size_t pad = RS_BLOCK_SIZE - n;
    
    // Compute error magnitudes
    for (int i = 0; i < error_count; i++) {
        size_t pos = error_pos[i];
        size_t full_pos = pad + pos;
        int X_inv_exp = full_pos;  // alpha^full_pos is X_i, so X_i^-1 = alpha^(-full_pos)
        
        // Evaluate omega at X_i^-1
        uint8_t omega_val = 0;
        for (int j = 0; j < RS_PARITY_SIZE; j++) {
            omega_val ^= gf_mul(omega[j], gf_exp[(X_inv_exp * j) % 255]);
        }
        
        // Evaluate sigma' at X_i^-1
        uint8_t sigma_prime_val = 0;
        for (int j = 0; j <= sigma_deg; j++) {
            sigma_prime_val ^= gf_mul(sigma_prime[j], gf_exp[(X_inv_exp * j) % 255]);
        }
        
        if (sigma_prime_val == 0) {
            error_val[i] = 0;  // Shouldn't happen
        } else {
            // e_i = X_i * omega(X_i^-1) / sigma'(X_i^-1)
            // But we need X_i which is alpha^(255-full_pos)
            uint8_t X_i = gf_exp[(255 - full_pos) % 255];
            error_val[i] = gf_mul(gf_mul(X_i, omega_val), gf_inv(sigma_prime_val));
        }
    }
}

int rs_decode(uint8_t *codeword, size_t len) {
    if (!rs_initialized) rs_init();
    if (len <= RS_PARITY_SIZE || len > RS_BLOCK_SIZE) {
        return -1;
    }
    
    uint8_t syndromes[RS_PARITY_SIZE];
    compute_syndromes(codeword, len, syndromes);
    
    // No errors?
    if (syndromes_zero(syndromes)) {
        return 0;
    }
    
    // Find error locator polynomial
    uint8_t sigma[RS_PARITY_SIZE + 1];
    memset(sigma, 0, sizeof(sigma));
    int num_errors = berlekamp_massey(syndromes, sigma);
    
    if (num_errors > RS_CORRECT_CAPABLE) {
        return -1;  // Too many errors
    }
    
    // Find error positions
    int error_pos[RS_CORRECT_CAPABLE];
    int roots_found = chien_search(sigma, num_errors, len, error_pos);
    
    if (roots_found != num_errors) {
        return -1;  // Decoding failure
    }
    
    // Compute error values
    uint8_t error_val[RS_CORRECT_CAPABLE];
    forney_algorithm(syndromes, sigma, num_errors, error_pos, num_errors, len, error_val);
    
    // Correct errors
    for (int i = 0; i < num_errors; i++) {
        if (error_pos[i] < (int)len) {
            codeword[error_pos[i]] ^= error_val[i];
        }
    }
    
    // Verify correction
    compute_syndromes(codeword, len, syndromes);
    if (!syndromes_zero(syndromes)) {
        return -1;  // Correction failed
    }
    
    return num_errors;
}

bool rs_check(const uint8_t *codeword, size_t len) {
    if (!rs_initialized) rs_init();
    if (len <= RS_PARITY_SIZE || len > RS_BLOCK_SIZE) {
        return false;
    }
    
    uint8_t syndromes[RS_PARITY_SIZE];
    compute_syndromes(codeword, len, syndromes);
    return syndromes_zero(syndromes);
}
