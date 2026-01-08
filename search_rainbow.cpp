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
#include <map>
#include <utility>
#include <fstream>

#include "gen_hash.h"

using std::array;
using std::cin;
using std::cout;
using std::endl;
using std::vector;
using std::set;
using std::multimap;
using std::tuple;

constexpr uint64_t MAX = 1ull << 32;

const int MAX_CHAIN_LENGTH = 3000;

vector<tuple<uint32_t, uint32_t>> all_data;

void check(int consumption, uint32_t initial_seed, int columnno, hash_t hash, set<uint32_t> &result) {
    //printf("check(%d, %08x, %d, %016llx)\n", consumption, initial_seed, columnno, hash);
    uint32_t s = initial_seed;
    for (int n = 0; n < columnno; n ++) {
        hash_t h = gen_hash_from_seed(s, consumption);
        s = (reduce_hash(h) + n) % MAX;
    }
    hash_t h = gen_hash_from_seed(s, consumption);

    if (hash == h) {
        result.insert(s);
    }
}

int binary_search(int consumption, int head, int tail, hash_t hash) {
    //printf("binary_search(%d, %d, %d, %016llx)\n", consumption, head, tail, hash);
    if (head < tail) {
        int mid = (head + tail) / 2;
        hash_t h = gen_hash_from_seed(std::get<1>(all_data[mid]), consumption);
        if (h > hash) {
            return binary_search(consumption, head, mid, hash);
        } else if (h < hash) {
            return binary_search(consumption, mid + 1, tail, hash);
        } else {
            return binary_search(consumption, head, mid, hash);
        }
    } else {
        return head;
    }
}

void search(int consumption, hash_t hash, int columnno, set<uint32_t> &result) {
    //printf("search(%d, %016llx, %d)\n", consumption, hash, columnno);
    hash_t h = hash;
    for (int n = columnno + 1; n <= MAX_CHAIN_LENGTH; n ++) {
        uint32_t seed = (reduce_hash(h) + (n - 1)) % MAX;
        h = gen_hash_from_seed(seed, consumption);
    }
    int start_index = binary_search(consumption, 0, all_data.size(), h);
    for (unsigned int i = start_index; i < all_data.size(); i ++) {
        //printf("i=%d, all_data[i]={%08x, %08x}\n", i, all_data[i].first, all_data[i].second);
        if (gen_hash_from_seed(std::get<1>(all_data[i]), consumption) != h) break;
        check(consumption, std::get<0>(all_data[i]), columnno, hash, result);
    }
}

void search_all(int consumption, hash_t hash) {
    set<uint32_t> result;
    for (int columnno = 0; columnno < MAX_CHAIN_LENGTH; columnno ++) {
        search(consumption, hash, columnno, result);
    }
    for (uint32_t r : result) {
        printf("%08x\n", r);
    }
}

int main(int argc, char* argv[]) {
    if (argc < 2) {
        std::cerr << "error: specify the argument\n";
        return 1;
    }
    int consumption = std::stoi(argv[1]);
    std::ifstream fin;
	fin.open(std::to_string(consumption) + ".sorted.bin", std::ios::in|std::ios::binary); 
    uint32_t buffer[2];
    while (fin.read((char*)buffer, sizeof(uint32_t) * 2)) {
        uint32_t first_seed = buffer[0];
        uint32_t last_seed = buffer[1];
        all_data.push_back({first_seed, last_seed});
    };
    fin.close();
    std::cout << "finshed loading" << endl;
    std::cout << "> " << std::flush;
    array<uint64_t, 8> rand;
    for (int i = 0; i < 8; i ++) {
        std::cin >> rand[i];
    }
    std::cout << "searching..." << std::endl;
    search_all(consumption, gen_hash(rand));
    printf("finished\n");
}