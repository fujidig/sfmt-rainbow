#include "gen_hash.h"


static void skipSFMT(sfmt_t* sfmt, int offset) {
    for (int i = 0; i < offset; i++) sfmt_genrand_uint64(sfmt);
}

hash_t gen_hash(array<uint64_t, 8> rand) {
    hash_t r = 0;
    for (int i = 0; i < 8; i++) {
        r = r * 17 + (rand[i] % 17);
    }
    return r;
}

hash_t gen_hash_from_seed(uint32_t seed, int offset) {
    sfmt_t sfmt;
    sfmt_init_gen_rand(&sfmt, seed);
    skipSFMT(&sfmt, offset);
    array<uint64_t, 8> rand;
    for (int i = 0; i < 8; i++) {
        rand[i] = sfmt_genrand_uint64(&sfmt) % 17;
    }
    return gen_hash(rand);
}

uint32_t reduce_hash(hash_t hash) {
    return (uint32_t)hash;
}
