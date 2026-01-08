#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <iostream>
#include <fstream>
#include <vector>
#include <string>
#include <iomanip>
#include <algorithm>

constexpr uint64_t MAX = 1ull << 32;
constexpr int BATCH_SIZE = 1000;
constexpr int NUM_CHAIN_MAX = 25800000;

struct ChainResult {
    uint32_t start_val;
    uint32_t end_val;
};

int main(int argc, char* argv[]) {
    if (argc < 2) {
        std::cerr << "error: specify the consumption argument\n";
        return 1;
    }
    int consumption = std::stoi(argv[1]);

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) { std::cerr << "Error: Metal device not found.\n"; return -1; }

    NSError* error = nil;
    id<MTLLibrary> defaultLibrary = [device newDefaultLibrary];
    if (!defaultLibrary) {
        // カレントディレクトリを探すフォールバック
        NSURL *url = [NSURL fileURLWithPath:@"./default.metallib"];
        defaultLibrary = [device newLibraryWithFile:url.path error:&error];
    }
    if (!defaultLibrary) { std::cerr << "Error: Failed to load default.metallib.\n"; return -1; }

    id<MTLFunction> function = [defaultLibrary newFunctionWithName:@"compute_chains"];
    if (!function) { std::cerr << "Error: Function 'compute_chains' not found.\n"; return -1; }

    id<MTLComputePipelineState> pipeline = [device newComputePipelineStateWithFunction:function error:&error];
    if (!pipeline) { std::cerr << "Error: Pipeline creation failed: " << error.localizedDescription.UTF8String << "\n"; return -1; }

    id<MTLCommandQueue> commandQueue = [device newCommandQueue];

    // ---------------------------------------------------------
    // バッファ確保
    // ---------------------------------------------------------
    id<MTLBuffer> seedsBuffer = [device newBufferWithLength:sizeof(uint32_t) * BATCH_SIZE
                                                    options:MTLResourceStorageModeShared];
    
    id<MTLBuffer> resultsBuffer = [device newBufferWithLength:sizeof(ChainResult) * BATCH_SIZE
                                                      options:MTLResourceStorageModeShared];

    // ---------------------------------------------------------
    // メインループ
    // ---------------------------------------------------------
    std::ofstream fout;
    fout.open(std::to_string(consumption) + ".bin", std::ios::out|std::ios::binary|std::ios::trunc);
    if (!fout) { std::cerr << "Error: Cannot open output file.\n"; return 1; }

    std::cout << "Starting Metal Rainbow Table Generation..." << std::endl;
    std::cout << "Batch Size: " << BATCH_SIZE << std::endl;

    int num_chain = 0;

    while (num_chain < NUM_CHAIN_MAX) {
        // A. 入力データの準備
        uint32_t* seedPtr = (uint32_t*)seedsBuffer.contents;
        ChainResult* resultPtr = (ChainResult*)resultsBuffer.contents;

        for (int i = 0; i < BATCH_SIZE; i++) {
            seedPtr[i] = num_chain + i;
            resultPtr[i].start_val = 0xFFFFFFFF;
            resultPtr[i].end_val   = 0xFFFFFFFF;
        }

        // B. エンコーディング
        id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
        
        [encoder setComputePipelineState:pipeline];
        [encoder setBuffer:seedsBuffer offset:0 atIndex:0];
        [encoder setBuffer:resultsBuffer offset:0 atIndex:1];
        [encoder setBytes:&consumption length:sizeof(int) atIndex:2];

        MTLSize gridSize = MTLSizeMake(BATCH_SIZE, 1, 1);
        NSUInteger threadGroupSize = pipeline.maxTotalThreadsPerThreadgroup;
        if (threadGroupSize > BATCH_SIZE) threadGroupSize = BATCH_SIZE;
        MTLSize threadgroupSize = MTLSizeMake(threadGroupSize, 1, 1);

        [encoder dispatchThreads:gridSize threadsPerThreadgroup:threadgroupSize];
        [encoder endEncoding];

        // C. 実行と待機
        [commandBuffer commit];
        [commandBuffer waitUntilCompleted];

        if (commandBuffer.status == MTLCommandBufferStatusError) {
            std::cerr << "\n[GPU Error] Batch failed at offset " << num_chain << std::endl;
            std::cerr << "Error Domain: " << commandBuffer.error.domain.UTF8String << std::endl;
            std::cerr << "Error Code: " << commandBuffer.error.code << std::endl;
            std::cerr << "Description: " << commandBuffer.error.localizedDescription.UTF8String << std::endl;
            return 1;
        }

        // D. 保存
        for (int i = 0; i < BATCH_SIZE; i++) {
            if (resultPtr[i].start_val == 0xFFFFFFFF && resultPtr[i].end_val == 0xFFFFFFFF) {
                std::cerr << "[Warning] GPU did not update index " << i << " (Start/End is FFFFFFFF)\n";
            }

            uint32_t data[2];
            data[0] = resultPtr[i].start_val;
            data[1] = resultPtr[i].end_val;
            fout.write((char*)data, sizeof(uint32_t) * 2);
        }
        
        num_chain += BATCH_SIZE;
        
        // 進捗表示
        printf("progress=%06.2f %%\n", (double)num_chain * 100.0 / NUM_CHAIN_MAX);
    }
    fout.close();
    printf("finished\n");
    return 0;
}