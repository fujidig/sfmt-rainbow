#include <sys/stat.h>
#include <algorithm>
#include <array>
#include <cstdint>
#include <iomanip>
#include <iostream>
#include <iterator>
#include <string>
#include <vector>
#include <set>
#include <tuple>

#include "gen_hash.h"

using std::array;
using std::cin;
using std::cout;
using std::endl;
using std::vector;
using std::set;

constexpr uint64_t MAX = 1ull << 32;

int main(int argc, char* argv[]) {
    hash_t hash = gen_hash_from_seed(0x00000000, 417);
    printf("hash = %016llx\n", hash);
    int values[8];
    for (int i = 7; i >= 0; i --) {
        values[i] = hash % 17;
        hash /= 17;
    }
    for (int i = 0; i < 8; i ++) {
        printf("%d ", values[i]);
    }
    puts("");
    return 0;
}