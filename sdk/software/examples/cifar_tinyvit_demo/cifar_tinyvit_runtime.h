#ifndef CIFAR_TINYVIT_RUNTIME_H
#define CIFAR_TINYVIT_RUNTIME_H

#include <stdint.h>

/* DVI 发布接口沿用原 TinyViT 演示的数据格式，便于保持现有展示布局。 */
typedef struct {
    int32_t logits[10];
    uint8_t class_scores[10];
    uint8_t attention_map[64];
    uint32_t cycles;
    uint32_t descriptors;
    uint32_t mopa_count;
    uint32_t gemm_tiles;
    uint32_t softmax_rows;
    uint32_t rmsnorm_rows;
    uint16_t test_index;
    uint8_t predicted;
    uint8_t expected;
    uint8_t lanes;
    uint8_t bit_exact;
    uint8_t fused_attention;
    int error;
} cifar_tinyvit_result_t;

int cifar_tinyvit_infer(unsigned int sample, cifar_tinyvit_result_t *result);

/* 返回原始空间分辨率的 32x32 RGB332 预览；推理仍使用未降色的 RGB 原图。 */
const uint8_t *cifar_tinyvit_sample_preview_rgb332(unsigned int sample);
const char *cifar_tinyvit_class_name(unsigned int class_id);

#endif
