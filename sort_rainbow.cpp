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
#include <fstream>

#include "gen_hash.h"

using std::array;
using std::cin;
using std::cout;
using std::endl;
using std::vector;
using std::set;
using std::tuple;
using std::multimap;

int main(int argc, char* argv[]) {
    if (argc < 2) {
        std::cerr << "error: specify the argument\n";
        return 1;
    }
    int consumption = std::stoi(argv[1]);
    vector<tuple<uint32_t, uint32_t>> all_data;
    std::ifstream fin;
	fin.open(std::to_string(consumption) + ".bin", std::ios::in|std::ios::binary);
    uint32_t buffer[2];
    while (fin.read((char*)buffer, sizeof(uint32_t) * 2)) {
        uint32_t first_seed = buffer[0];
        uint32_t last_seed = buffer[1];
        uint32_t last_hash_truncated = (uint32_t)gen_hash_from_seed(last_seed, consumption);
        all_data.emplace_back(first_seed, last_hash_truncated);
    }
    fin.close();
    printf("finshed loading\n");
    sort(all_data.begin(), all_data.end(), [](auto x, auto y) { return std::get<1>(x) < std::get<1>(y); });
    printf("finshed sort\n");
    std::ofstream fout;
	fout.open(std::to_string(consumption) + ".sorted.bin", std::ios::out|std::ios::binary|std::ios::trunc);
    for (auto x : all_data) {
        uint32_t data[2];
        data[0] = std::get<0>(x);
        data[1] = std::get<1>(x);
        fout.write((char*)data, sizeof(uint32_t) * 2);
    }
	fout.close();
    printf("finished\n");
}