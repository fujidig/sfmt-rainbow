#include <metal_stdlib>
using namespace metal;

// -----------------------------------------------------------------------------
// SFMT19937 Constants
// -----------------------------------------------------------------------------
constant int SFMT_N = 156;
constant int SFMT_POS1 = 122;
constant int SFMT_SL1 = 18;
constant int SFMT_SR1 = 11;

// Masks
constant uint MSK1 = 0xdfffffefU;
constant uint MSK2 = 0xddfecb7fU;
constant uint MSK3 = 0xbffaffffU;
constant uint MSK4 = 0xbffffff6U;

// Parity for Period Certification
constant uint PARITY1 = 0x00000001U;
constant uint PARITY2 = 0x00000000U;
constant uint PARITY3 = 0x00000000U;
constant uint PARITY4 = 0x13c9e684U;

// SFMT generates 312 uint64_t numbers per block recursion
constant int SFMT_BLOCK_SIZE64 = 312; 

// -----------------------------------------------------------------------------
// 128-bit Logic Helpers
// -----------------------------------------------------------------------------
inline uint4 lshift128_8(uint4 v) {
    return uint4((v.x << 8), (v.y << 8) | (v.x >> 24), (v.z << 8) | (v.y >> 24), (v.w << 8) | (v.z >> 24));
}

inline uint4 rshift128_8(uint4 v) {
    return uint4((v.x >> 8) | (v.y << 24), (v.y >> 8) | (v.z << 24), (v.z >> 8) | (v.w << 24), (v.w >> 8));
}

inline uint4 do_recursion(uint4 a, uint4 b, uint4 c, uint4 d) {
    uint4 x = lshift128_8(a);
    uint4 y = rshift128_8(c);
    uint4 z = b >> SFMT_SR1;
    z &= uint4(MSK1, MSK2, MSK3, MSK4);
    uint4 w = d << SFMT_SL1;
    return a ^ x ^ z ^ y ^ w;
}

// -----------------------------------------------------------------------------
// Helper: Update State (Generate next block)
// -----------------------------------------------------------------------------
// Updates the 156-element uint4 array in place.
void sfmt_gen_rand_all(thread uint4* state) {
    uint4 r1 = state[SFMT_N - 2];
    uint4 r2 = state[SFMT_N - 1];
    int i;
    for (i = 0; i < SFMT_N - SFMT_POS1; i++) {
        state[i] = do_recursion(state[i], state[i + SFMT_POS1], r1, r2);
        r1 = r2; r2 = state[i];
    }
    for (; i < SFMT_N; i++) {
        state[i] = do_recursion(state[i], state[i + SFMT_POS1 - SFMT_N], r1, r2);
        r1 = r2; r2 = state[i];
    }
}

// -----------------------------------------------------------------------------
// Generic Hash Function (Variable Consumption)
// -----------------------------------------------------------------------------
uint64_t gen_hash_generic(uint32_t seed, int consumption) {
    // SFMT State (in thread local memory)
    uint4 state[SFMT_N];
    thread uint32_t *ps = (thread uint32_t*)state;

    // --- 1. Initialization (Standard LCG) ---
    ps[0] = seed;
    for (int i = 1; i < 624; i++) {
        uint32_t prev = ps[i - 1];
        ps[i] = 1812433253UL * (prev ^ (prev >> 30)) + i;
    }

    // --- 2. Period Certification ---
    uint32_t inner = 0;
    inner ^= ps[0] & PARITY1;
    inner ^= ps[1] & PARITY2;
    inner ^= ps[2] & PARITY3;
    inner ^= ps[3] & PARITY4;

    for (int i = 16; i > 0; i >>= 1) inner ^= inner >> i;
    inner &= 1;

    if (inner == 0) ps[0] ^= 1;

    // --- 3. Fast Forward to Consumption Point ---
    // SFMT generates 312 uint64_t numbers per recursion.
    // LCG state needs to be recursed at least once to be used.
    // Index 0..311 requires 1 recursion.
    // Index 312..623 requires 2 recursions.
    
    // Calculate how many full block recursions are needed to reach 'consumption'
    int recursions_needed = (consumption / SFMT_BLOCK_SIZE64) + 1;
    
    for (int r = 0; r < recursions_needed; r++) {
        sfmt_gen_rand_all(state);
    }

    // Current index within the block (0..311)
    int current_idx = consumption % SFMT_BLOCK_SIZE64;

    // --- 4. Extract 8 numbers & Compute Hash ---
    uint64_t h = 0;
    thread uint32_t* p_res = (thread uint32_t*)state;

    for (int k = 0; k < 8; k++) {
        // Handle Block Boundary:
        // If we reached the end of the current block (index 312),
        // we must generate the next block and reset index to 0.
        if (current_idx >= SFMT_BLOCK_SIZE64) {
            sfmt_gen_rand_all(state);
            current_idx = 0;
        }

        // Get uint64 from two uint32s (Little Endian)
        // uint64 index 'current_idx' maps to uint32 index 'current_idx * 2'
        uint32_t low  = p_res[current_idx * 2];
        uint32_t high = p_res[current_idx * 2 + 1];
        uint64_t val = (uint64_t)low | ((uint64_t)high << 32);

        h = h * 17 + (val % 17);
        
        current_idx++;
    }
    
    return h;
}

// -----------------------------------------------------------------------------
// Main Kernel
// -----------------------------------------------------------------------------
struct ChainResult {
    uint32_t start_val;
    uint32_t end_val;
};

constant int MAX_CHAIN_LENGTH = 3000;
constant uint64_t MAX_VAL = 4294967296UL; // 1 << 32

kernel void compute_chains(
    device const uint32_t* seeds [[ buffer(0) ]],
    device ChainResult* results  [[ buffer(1) ]],
    constant int& consumption    [[ buffer(2) ]],
    uint id [[ thread_position_in_grid ]]
) {
    uint32_t i = seeds[id];
    uint32_t start_val = i;
    
    for (int n = 0; n < MAX_CHAIN_LENGTH; n++) {
        uint64_t hash = gen_hash_generic(i, consumption);
        i = (uint32_t)((hash + n) % MAX_VAL);
    }
    
    results[id].start_val = start_val;
    results[id].end_val = i;
}

// -----------------------------------------------------------------------------
// Test Kernel (For verification)
// -----------------------------------------------------------------------------
kernel void test_hash_kernel(
    device const uint32_t* seeds [[ buffer(0) ]],
    device uint64_t* results     [[ buffer(1) ]],
    constant int& consumption    [[ buffer(2) ]],
    uint id [[ thread_position_in_grid ]]
) {
    results[id] = gen_hash_generic(seeds[id], consumption);
}

// -----------------------------------------------------------------------------
// [NEW] Search Kernel
// -----------------------------------------------------------------------------
// target_hashからチェーンを延長し、各カラム位置に対応する「末尾のハッシュ値」を計算する
kernel void search_rainbow_chain(
    constant uint64_t& target_hash [[ buffer(0) ]],
    device uint64_t* results       [[ buffer(1) ]],
    constant int& consumption      [[ buffer(2) ]],
    uint columnno [[ thread_position_in_grid ]]
) {
    if (columnno >= (uint)MAX_CHAIN_LENGTH) return;

    uint64_t h = target_hash;
    
    for (int n = columnno + 1; n <= MAX_CHAIN_LENGTH; n++) {
        uint32_t seed = (uint32_t)(( (uint64_t)(uint32_t)h + (n - 1) ) % MAX_VAL);
        h = gen_hash_generic(seed, consumption);
    }
    results[columnno] = h;
}