#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <iostream>
#include <fstream>
#include <vector>
#include <string>
#include <array>
#include <set>
#include <algorithm>
#include <iomanip>
#include "gen_hash.h"
#include <mutex>
#include <dispatch/dispatch.h>
#include <random>

using std::vector;
using std::pair;
using std::set;
using std::cout;
using std::endl;

// --- Constants ---
constexpr uint64_t MAX = 1ull << 32;
constexpr int MAX_CHAIN_LENGTH = 3000;

// --- Global Data ---
vector<pair<uint32_t, uint32_t>> all_data;

// --- Search Logic (Hybrid) ---

// Verify a candidate chain (CPU)
void check(int consumption, uint32_t initial_seed, int columnno, hash_t target_hash, set<uint32_t> &result) {
    uint32_t s = initial_seed;
    for (int n = 0; n < columnno; n++) {
        hash_t h = gen_hash_from_seed(s, consumption);
        s = (reduce_hash(h) + n) % MAX;
    }
    hash_t h_val = gen_hash_from_seed(s, consumption);
    
    if (target_hash == h_val) {
        result.insert(s);
    }
}

// Binary Search (CPU)
// Finds the index of the first element >= hash
int binary_search_idx(int consumption, uint32_t hash_truncated) {
    int low = 0;
    int high = (int)all_data.size();
    
    while (low < high) {
        int mid = low + (high - low) / 2;
        uint32_t h = all_data[mid].second;
        
        if (h < hash_truncated) {
            low = mid + 1;
        } else {
            high = mid;
        }
    }
    return low;
}

// [NEW] Separated Search Function
set<uint32_t> search_rainbow(
    id<MTLDevice> device,
    id<MTLCommandQueue> commandQueue,
    id<MTLComputePipelineState> pipeline,
    int consumption,
    hash_t target_hash
) {
    // 4. Run GPU Search (Chain Extension)
    id<MTLBuffer> targetHashBuffer = [device newBufferWithBytes:&target_hash 
                                                         length:sizeof(uint64_t) 
                                                        options:MTLResourceStorageModeShared];
    
    id<MTLBuffer> resultsBuffer = [device newBufferWithLength:sizeof(uint64_t) * MAX_CHAIN_LENGTH 
                                                      options:MTLResourceStorageModeShared];

    id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];
    id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
    
    [encoder setComputePipelineState:pipeline];
    [encoder setBuffer:targetHashBuffer offset:0 atIndex:0];
    [encoder setBuffer:resultsBuffer offset:0 atIndex:1];
    [encoder setBytes:&consumption length:sizeof(int) atIndex:2];
    
    MTLSize gridSize = MTLSizeMake(MAX_CHAIN_LENGTH, 1, 1);
    MTLSize threadGroupSize = MTLSizeMake(pipeline.maxTotalThreadsPerThreadgroup, 1, 1);
    if (threadGroupSize.width > MAX_CHAIN_LENGTH) threadGroupSize.width = MAX_CHAIN_LENGTH;
    
    [encoder dispatchThreads:gridSize threadsPerThreadgroup:threadGroupSize];
    [encoder endEncoding];
    
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];


    // 5. Check Results (CPU)
    uint64_t* gpu_results = (uint64_t*)resultsBuffer.contents;
    std::mutex result_mutex;
    set<uint32_t> result_set;
    std::mutex *mutex_ptr = &result_mutex;
    set<uint32_t> *set_ptr = &result_set;

    dispatch_apply(MAX_CHAIN_LENGTH, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^(size_t columnno) {
        hash_t end_hash = gpu_results[columnno];
        
        int start_idx = binary_search_idx(consumption, (uint32_t)end_hash);
        
        for (unsigned int i = start_idx; i < all_data.size(); i++) {
            if (all_data[i].second != (uint32_t)end_hash) break;
            
            uint32_t s = all_data[i].first;
            bool match = false;
            uint32_t found_s = 0;
            
            for (int n = 0; n < columnno; n++) {
                hash_t h = gen_hash_from_seed(s, consumption);
                s = (reduce_hash(h) + n) % MAX;
            }
            if (target_hash == gen_hash_from_seed(s, consumption)) {
                match = true;
                found_s = s;
            }
            
            if (match) {
                std::lock_guard<std::mutex> lock(*mutex_ptr);
                set_ptr->insert(found_s);
            }
        }
    });
    
    return result_set;
}

int main(int argc, char* argv[]) {
    if (argc < 2) {
        std::cerr << "error: specify the consumption argument\n";
        return 1;
    }
    int consumption;
    bool test_mode = false;
    if (argc == 3 && std::string(argv[1]) == "test") {
        consumption = std::stoi(argv[2]);
        test_mode = true;
    } else {
        consumption = std::stoi(argv[1]);
    }

    // 1. Setup Metal
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        std::cerr << "Error: Metal device not found." << std::endl;
        return -1;
    }
    
    NSError* error = nil;
    id<MTLLibrary> library = [device newDefaultLibrary];
    if (!library) {
        NSURL *url = [NSURL fileURLWithPath:@"./default.metallib"];
        library = [device newLibraryWithURL:url error:&error];
    }
    if (!library) {
        std::cerr << "Error: Failed to load default.metallib." << std::endl;
        return -1;
    }

    id<MTLFunction> kernelFunc = [library newFunctionWithName:@"search_rainbow_chain"];
    if (!kernelFunc) {
        std::cerr << "Error: Kernel 'search_rainbow_chain' not found." << std::endl;
        return -1;
    }

    id<MTLComputePipelineState> pipeline = [device newComputePipelineStateWithFunction:kernelFunc error:&error];
    id<MTLCommandQueue> commandQueue = [device newCommandQueue];

    // 2. Load Data
    std::string filename = std::to_string(consumption) + ".sorted.bin";
    std::ifstream fin(filename, std::ios::in | std::ios::binary);
    if (!fin) {
        std::cerr << "Error: Cannot open " << filename << std::endl;
        return 1;
    }
    
    fin.seekg(0, std::ios::end);
    size_t fileSize = fin.tellg();
    fin.seekg(0, std::ios::beg);
    size_t numRecords = fileSize / (sizeof(uint32_t) * 2);
    all_data.reserve(numRecords);

    // Bulk read
    vector<uint32_t> buffer(numRecords * 2);
    fin.read((char*)buffer.data(), fileSize);
    fin.close();

    for (size_t i = 0; i < numRecords; i++) {
        all_data.push_back({buffer[i*2], buffer[i*2+1]});
    }

    std::cout << "finished loading (" << numRecords << " records)" << endl;

    if (test_mode) {
        std::random_device rd;
        std::uniform_int_distribution<uint32_t> dist(0, 0xffffffff);
        int num_succeeded = 0;
        const int num_all = 300;
        for (int i = 0; i < num_all; i ++) {
            uint32_t seed = dist(rd);
            hash_t target_hash = gen_hash_from_seed(seed, 417);
            set<uint32_t> result_set = search_rainbow(device, commandQueue, pipeline, consumption, target_hash);
            if (result_set.find(seed) != result_set.end()) {
                std::cout << "O" << std::flush;
                num_succeeded ++;
            } else {
                std::cout << "." << std::flush;
            }
            if (i % 10 == 9) {
                std::cout << std::endl;
            }
        }
        std::cout << num_succeeded << " / " << num_all << std::endl;
    } else {
        std::cout << "> " << std::flush;
        // 3. Read Input Hash
        array<uint64_t, 8> rand_input;
        for (int i = 0; i < 8; i++) {
            std::cin >> rand_input[i];
        }
        hash_t target_hash = gen_hash(rand_input);

        std::cout << "searching..." << std::endl;

        // Call the separated search function
        set<uint32_t> result_set = search_rainbow(device, commandQueue, pipeline, consumption, target_hash);

        for (uint32_t r : result_set) {
            printf("%08x\n", r);
        }
        printf("finished\n");
    }

    return 0;
}