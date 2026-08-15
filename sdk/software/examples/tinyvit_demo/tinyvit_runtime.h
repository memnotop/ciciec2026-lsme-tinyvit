#ifndef TINYVIT_RUNTIME_H
#define TINYVIT_RUNTIME_H

#include <stdint.h>

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
    uint32_t engine_cycles;
    uint32_t axi_read_beats;
    uint32_t axi_write_beats;
    uint32_t compute_cycles;
    uint32_t memory_stall_cycles;
    uint32_t overlap_cycles;
    uint32_t last_descriptor_cycles;
    uint16_t test_index;
    uint8_t predicted;
    uint8_t expected;
    uint8_t lanes;
    uint8_t bit_exact;
    int error;
} tinyvit_result_t;

int tinyvit_infer(unsigned int sample, tinyvit_result_t *result);
const uint8_t *tinyvit_sample_image(unsigned int sample);
const char *tinyvit_class_name(unsigned int class_id);

#endif
