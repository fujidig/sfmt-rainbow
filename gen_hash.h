#pragma once

#include <array>

#define SFMT_MEXP 19937
extern "C" {
#include "./SFMT/SFMT.h"
}

using std::array;

typedef uint64_t hash_t;

hash_t gen_hash(array<uint64_t, 8> rand);
hash_t gen_hash_from_seed(uint32_t seed, int offset);

uint32_t reduce_hash(hash_t hash);