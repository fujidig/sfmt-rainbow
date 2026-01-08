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
int binary_search_idx(int consumption, hash_t hash) {
    int low = 0;
    int high = (int)all_data.size();
    
    while (low < high) {
        int mid = low + (high - low) / 2;
        // all_data stores {first, last}. We sort by Hash(last).
        hash_t h = gen_hash_from_seed(all_data[mid].second, consumption);
        
        if (h < hash) {
            low = mid + 1;
        } else {
            high = mid;
        }
    }
    return low;
}

int main(int argc, char* argv[]) {
    if (argc < 2) {
        std::cerr << "error: specify the consumption argument\n";
        return 1;
    }
    int consumption = std::stoi(argv[1]);

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
        library = [device newLibraryWithFile:url.path error:&error];
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
    
    // Read entire file to vector (Memory intensive but same as original)
    // Optimization: reserve space if file size is known
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
    std::cout << "> " << std::flush;

    // 3. Read Input Hash
    array<uint64_t, 8> rand_input;
    for (int i = 0; i < 8; i++) {
        std::cin >> rand_input[i];
    }
    hash_t target_hash = gen_hash(rand_input);

    std::cout << "searching..." << std::endl;

    // 4. Run GPU Search (Chain Extension)
    // Input: Target Hash
    // Output: 1500 potential end-hashes (one for each column assumption)
    
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

    printf("calculation finished\n");

    // 5. Check Results (CPU)
    uint64_t* gpu_results = (uint64_t*)resultsBuffer.contents;
    std::mutex result_mutex;
    set<uint32_t> result_set;
    std::mutex *mutex_ptr = &result_mutex;
    set<uint32_t> *set_ptr = &result_set;

    dispatch_apply(MAX_CHAIN_LENGTH, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^(size_t columnno) {
        hash_t end_hash = gpu_results[columnno];
        
        int start_idx = binary_search_idx(consumption, end_hash);
        
        for (unsigned int i = start_idx; i < all_data.size(); i++) {
            if (gen_hash_from_seed(all_data[i].second, consumption) != end_hash) break;
            
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

    for (uint32_t r : result_set) {
        printf("%08x\n", r);
    }
    printf("finished\n");

    return 0;
}