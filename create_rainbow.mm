#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <iostream>
#include <fstream>
#include <vector>
#include <string>
#include <iomanip>
#include <algorithm>
#include <unordered_set>

constexpr uint64_t MAX = 1ull << 32;
constexpr int BATCH_SIZE = 2000; // 安全のため少し小さめに設定
constexpr int NUM_CHAIN_MAX = 1310000;
constexpr int NUM_BLOCKS = 5;

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
        NSURL *url = [NSURL fileURLWithPath:@"./default.metallib"];
        defaultLibrary = [device newLibraryWithURL:url error:&error];
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
    // 重複チェック用セット
    // ---------------------------------------------------------
    std::unordered_set<uint32_t> saved_endpoints;

    // ---------------------------------------------------------
    // メインループ
    // ---------------------------------------------------------
    std::ofstream fout;
    fout.open(std::to_string(consumption) + ".bin", std::ios::out|std::ios::binary|std::ios::trunc);
    if (!fout) { std::cerr << "Error: Cannot open output file.\n"; return 1; }

    uint64_t num_seed_counter = 0; // シード生成用カウンタ（試行回数）

    for (int block = 0; block < NUM_BLOCKS; block ++) {
        saved_endpoints.clear();
        saved_endpoints.reserve(NUM_CHAIN_MAX);
        int saved_count = 0;           // 保存済みチェイン数
        while (saved_count < NUM_CHAIN_MAX) {
            // A. 入力データの準備
            uint32_t* seedPtr = (uint32_t*)seedsBuffer.contents;
            ChainResult* resultPtr = (ChainResult*)resultsBuffer.contents;

            for (int i = 0; i < BATCH_SIZE; i++) {
                // シードが32bitを超えない範囲でループさせる
                seedPtr[i] = (uint32_t)(num_seed_counter + i);
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
                std::cerr << "\n[GPU Error] Batch failed at seed offset " << num_seed_counter << std::endl;
                // エラー処理（必要ならリトライなど）
                return 1;
            }

            // D. 保存（重複チェック付き）
            for (int i = 0; i < BATCH_SIZE; i++) {
                // もしこのバッチ処理中に目標数に達したら即終了
                if (saved_count >= NUM_CHAIN_MAX) break;

                // 重複チェック
                if (saved_endpoints.find(resultPtr[i].end_val) == saved_endpoints.end()) {
                    saved_endpoints.insert(resultPtr[i].end_val);

                    uint32_t data[2];
                    data[0] = resultPtr[i].start_val;
                    data[1] = resultPtr[i].end_val;
                    fout.write((char*)data, sizeof(uint32_t) * 2);
                    
                    saved_count++;
                }
            }
            
            num_seed_counter += BATCH_SIZE;
            
            // 進捗表示
            printf("block=%d progress=%06.2f %% (Saved: %d / %d, Seed: %llu)\n",
                block, (double)saved_count * 100.0 / NUM_CHAIN_MAX, 
                saved_count, NUM_CHAIN_MAX, num_seed_counter);
        }
    }
    
    fout.close();
    printf("finished.\n");
    return 0;
}