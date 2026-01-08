#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <iostream>
#include <vector>
#include <iomanip>
#include <cassert>

// -----------------------------------------------------------------------------
// CPU Reference Implementation (SFMT)
// -----------------------------------------------------------------------------
#define SFMT_MEXP 19937
extern "C" {
    #include "./SFMT/SFMT.h"
}

// 元のコードと同じ定数
constexpr int CONSUMPTION = 417;

static void skipSFMT(sfmt_t* sfmt, int offset) {
    for (int i = 0; i < offset; i++) sfmt_genrand_uint64(sfmt);
}

uint64_t gen_hash_cpu(std::array<uint64_t, 8> rand_arr) {
    uint64_t r = 0;
    for (int i = 0; i < 8; i++) {
        r = r * 17 + (rand_arr[i] % 17);
    }
    return r;
}

uint64_t gen_hash_from_seed_cpu(uint32_t seed) {
    sfmt_t sfmt;
    sfmt_init_gen_rand(&sfmt, seed);
    skipSFMT(&sfmt, CONSUMPTION);
    
    std::array<uint64_t, 8> rand_arr;
    for (int i = 0; i < 8; i++) {
        // SFMTの仕様通り、genrand_uint64を呼ぶ
        rand_arr[i] = sfmt_genrand_uint64(&sfmt); 
        // ※Metal側では内部で % 17 を後回しにしていますが、
        // 最終的なハッシュ計算式が合っていれば問題ありません。
        // ここではMetal側のロジックに合わせて比較用の値を調整します。
        // Metal側: (val % 17) を加算
        // CPU側  : (val % 17) を加算 (gen_hash関数内)
    }
    return gen_hash_cpu(rand_arr);
}

// -----------------------------------------------------------------------------
// Main Test Runner
// -----------------------------------------------------------------------------
int main() {
    // 1. Setup Metal
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        std::cerr << "Error: Metal device not found." << std::endl;
        return -1;
    }

    NSError* error = nil;
    // default.metallib を読み込む
    id<MTLLibrary> library = [device newDefaultLibrary];
    if (!library) {
        // カレントディレクトリの .metallib を探しに行く
        NSURL *url = [NSURL fileURLWithPath:@"./default.metallib"];
        library = [device newLibraryWithURL:url error:&error];
    }
    
    if (!library) {
        std::cerr << "Error: Failed to load default.metallib. Did you compile it?" << std::endl;
        return -1;
    }

    id<MTLFunction> kernelFunc = [library newFunctionWithName:@"test_hash_kernel"];
    if (!kernelFunc) {
        std::cerr << "Error: Function 'test_hash_kernel' not found in library." << std::endl;
        return -1;
    }

    id<MTLComputePipelineState> pipeline = [device newComputePipelineStateWithFunction:kernelFunc error:&error];
    if (!pipeline) {
        std::cerr << "Error creating pipeline: " << [error.localizedDescription UTF8String] << std::endl;
        return -1;
    }

    id<MTLCommandQueue> commandQueue = [device newCommandQueue];

    // 2. Prepare Test Data
    const int NUM_TESTS = 100;
    std::vector<uint32_t> seeds(NUM_TESTS);
    
    // エッジケースを含めたシードを用意
    for(int i=0; i<NUM_TESTS; ++i) {
        if (i == 0) seeds[i] = 0;
        else if (i == 1) seeds[i] = 1;
        else if (i == 2) seeds[i] = 0xFFFFFFFF; // Max uint32
        else seeds[i] = i * 12345; // ランダムな値
    }

    // 3. Create Buffers
    id<MTLBuffer> seedsBuffer = [device newBufferWithBytes:seeds.data()
                                                    length:sizeof(uint32_t) * NUM_TESTS
                                                   options:MTLResourceStorageModeShared];
    
    id<MTLBuffer> resultsBuffer = [device newBufferWithLength:sizeof(uint64_t) * NUM_TESTS
                                                      options:MTLResourceStorageModeShared];

    // 4. Run GPU Kernel
    id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];
    id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
    
    [encoder setComputePipelineState:pipeline];
    [encoder setBuffer:seedsBuffer offset:0 atIndex:0];
    [encoder setBuffer:resultsBuffer offset:0 atIndex:1];
    [encoder setBytes:&CONSUMPTION length:sizeof(int) atIndex:2];
    
    MTLSize gridSize = MTLSizeMake(NUM_TESTS, 1, 1);
    MTLSize threadGroupSize = MTLSizeMake(pipeline.maxTotalThreadsPerThreadgroup, 1, 1);
    if (threadGroupSize.width > NUM_TESTS) threadGroupSize.width = NUM_TESTS;
    
    [encoder dispatchThreads:gridSize threadsPerThreadgroup:threadGroupSize];
    [encoder endEncoding];
    
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];

    // 5. Compare Results
    uint64_t* gpuResults = (uint64_t*)resultsBuffer.contents;
    int errors = 0;

    std::cout << "--- Starting Verification ---" << std::endl;
    std::cout << std::hex << std::setfill('0');

    for (int i = 0; i < NUM_TESTS; i++) {
        uint32_t seed = seeds[i];
        uint64_t gpuVal = gpuResults[i];
        uint64_t cpuVal = gen_hash_from_seed_cpu(seed);

        if (gpuVal != cpuVal) {
            std::cout << "[FAIL] Seed: 0x" << std::setw(8) << seed 
                      << " | GPU: 0x" << std::setw(16) << gpuVal 
                      << " | CPU: 0x" << std::setw(16) << cpuVal << std::endl;
            errors++;
        } else {
            // 最初の数個だけOKログを出す
            if (i < 5) {
                std::cout << "[ OK ] Seed: 0x" << std::setw(8) << seed 
                          << " | Hash: 0x" << std::setw(16) << gpuVal << std::endl;
            }
        }
    }

    std::cout << std::dec;
    if (errors == 0) {
        std::cout << "--- SUCCESS: All " << NUM_TESTS << " tests passed! ---" << std::endl;
    } else {
        std::cout << "--- FAILED: " << errors << " mismatches found. ---" << std::endl;
    }

    return 0;
}