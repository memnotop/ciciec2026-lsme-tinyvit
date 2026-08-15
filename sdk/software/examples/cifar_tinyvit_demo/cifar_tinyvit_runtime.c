#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

#include "confreg_time.h"
#include "lsme.h"
#include "cifar_tinyvit_model.h"
#include "cifar_tinyvit_runtime.h"

/* 模型形状固定为 8x8 token 网格；这样现有 8x8 注意力热图可原样复用。 */
#define TOKENS 64u
#define MODEL_DIM 32u
#define HEADS 4u
#define HEAD_DIM 8u
#define MLP_DIM 64u
#define PATCH_DIM 48u
#define BLOCKS 2u
#define CLASSES_PADDED 12u
#define ALIGNED64 __attribute__((aligned(64)))

/* mode=2 明确要求当前已验证的 V1 Stream GEMM，不进入未验证的 V2 路径。 */
#ifndef TINYVIT_LSME_MODE
#define TINYVIT_LSME_MODE LSME_V2_MODE_STREAM
#endif

/* 新算子只在融合 Attention 位流中启用；默认保持可启动的分解基线。 */
#ifndef TINYVIT_USE_FUSED_ATTENTION
#define TINYVIT_USE_FUSED_ATTENTION 0
#endif

#ifndef TINYVIT_FUSED_SHADOW_CHECK
#define TINYVIT_FUSED_SHADOW_CHECK 0
#endif

/* 所有共享缓冲区都使用非缓存别名，CPU 和 LSME AXI Master 看见相同内容。 */
static int8_t patch_store[TOKENS * PATCH_DIM] ALIGNED64;
static int8_t token_store[TOKENS * MODEL_DIM] ALIGNED64;
static int8_t normal_store[TOKENS * MODEL_DIM] ALIGNED64;
static int8_t qkv_linear_store[TOKENS * MODEL_DIM * 3u] ALIGNED64;
static int8_t q_head_store[HEADS * TOKENS * HEAD_DIM] ALIGNED64;
static int8_t k_head_store[HEADS * TOKENS * HEAD_DIM] ALIGNED64;
static int8_t v_head_store[HEADS * TOKENS * HEAD_DIM] ALIGNED64;
static int32_t score_store[HEADS * TOKENS * TOKENS] ALIGNED64;
static uint8_t probability_store[HEADS * TOKENS * TOKENS] ALIGNED64;
static int8_t context_head_store[HEADS * TOKENS * HEAD_DIM] ALIGNED64;
static int8_t context_store[TOKENS * MODEL_DIM] ALIGNED64;
#if TINYVIT_FUSED_SHADOW_CHECK
static int8_t context_reference_store[TOKENS * MODEL_DIM] ALIGNED64;
#endif
static uint32_t attention_sum_store[TOKENS] ALIGNED64;
static int8_t projection_store[TOKENS * MODEL_DIM] ALIGNED64;
static int8_t hidden_store[TOKENS * MLP_DIM] ALIGNED64;
static int8_t mlp_store[TOKENS * MODEL_DIM] ALIGNED64;
static int8_t final_store[TOKENS * MODEL_DIM] ALIGNED64;
static int8_t classifier_input_store[4u * MODEL_DIM] ALIGNED64;
static int32_t classifier_output_store[4u * CLASSES_PADDED] ALIGNED64;
static lsme_descriptor_t descriptor_store ALIGNED64;

typedef struct {
    const int8_t *norm1_gain;
    const int8_t *q_weight;
    const int32_t *q_bias;
    const int8_t *k_weight;
    const int32_t *k_bias;
    const int8_t *v_weight;
    const int32_t *v_bias;
    const int8_t *projection_weight;
    const int32_t *projection_bias;
    const int8_t *norm2_gain;
    const int8_t *mlp1_weight;
    const int32_t *mlp1_bias;
    const int8_t *mlp2_weight;
    const int32_t *mlp2_bias;
    uint8_t q_shift;
    uint8_t k_shift;
    uint8_t v_shift;
    uint8_t projection_shift;
    uint8_t mlp1_shift;
    uint8_t mlp2_shift;
} transformer_block_t;

/* 两层参数表让同一执行链依次完成 block0 和 block1。 */
static const transformer_block_t transformer_block[BLOCKS] = {
    {
        tinyvit_block0_norm1_gain,
        tinyvit_block0_q_weight, tinyvit_block0_q_bias,
        tinyvit_block0_k_weight, tinyvit_block0_k_bias,
        tinyvit_block0_v_weight, tinyvit_block0_v_bias,
        tinyvit_block0_projection_weight, tinyvit_block0_projection_bias,
        tinyvit_block0_norm2_gain,
        tinyvit_block0_mlp1_weight, tinyvit_block0_mlp1_bias,
        tinyvit_block0_mlp2_weight, tinyvit_block0_mlp2_bias,
        TINYVIT_BLOCK0_Q_SHIFT, TINYVIT_BLOCK0_K_SHIFT,
        TINYVIT_BLOCK0_V_SHIFT, TINYVIT_BLOCK0_PROJECTION_SHIFT,
        TINYVIT_BLOCK0_MLP1_SHIFT, TINYVIT_BLOCK0_MLP2_SHIFT,
    },
    {
        tinyvit_block1_norm1_gain,
        tinyvit_block1_q_weight, tinyvit_block1_q_bias,
        tinyvit_block1_k_weight, tinyvit_block1_k_bias,
        tinyvit_block1_v_weight, tinyvit_block1_v_bias,
        tinyvit_block1_projection_weight, tinyvit_block1_projection_bias,
        tinyvit_block1_norm2_gain,
        tinyvit_block1_mlp1_weight, tinyvit_block1_mlp1_bias,
        tinyvit_block1_mlp2_weight, tinyvit_block1_mlp2_bias,
        TINYVIT_BLOCK1_Q_SHIFT, TINYVIT_BLOCK1_K_SHIFT,
        TINYVIT_BLOCK1_V_SHIFT, TINYVIT_BLOCK1_PROJECTION_SHIFT,
        TINYVIT_BLOCK1_MLP1_SHIFT, TINYVIT_BLOCK1_MLP2_SHIFT,
    },
};

static volatile void *uncached(const void *pointer)
{
    return (volatile void *)lsme_uncached_ptr(pointer);
}

/* 描述符内的地址字段只有 32 位，使用 LSME 可识别的 DMW 非缓存地址。 */
static uint32_t accelerator_address(const void *pointer)
{
    return (uint32_t)(uintptr_t)lsme_uncached_ptr(pointer);
}

static int8_t saturate_s8(int value)
{
    if (value > 127)
        return 127;
    if (value < -128)
        return -128;
    return (int8_t)value;
}

static uint32_t integer_sqrt(uint32_t value)
{
    uint32_t result = 0;
    uint32_t bit = 1u << 30;

    while (bit > value)
        bit >>= 2;
    while (bit != 0u) {
        if (value >= result + bit) {
            value -= result + bit;
            result = (result >> 1) + bit;
        }
        else {
            result >>= 1;
        }
        bit >>= 2;
    }
    return result;
}

static int round_nearest_even(int numerator, int denominator)
{
    unsigned int magnitude = numerator < 0 ? (unsigned int)(-numerator)
                                            : (unsigned int)numerator;
    unsigned int quotient = magnitude / (unsigned int)denominator;
    unsigned int remainder = magnitude % (unsigned int)denominator;

    if (remainder * 2u > (unsigned int)denominator ||
        (remainder * 2u == (unsigned int)denominator && (quotient & 1u)))
        ++quotient;
    return numerator < 0 ? -(int)quotient : (int)quotient;
}

static int run_descriptor(volatile lsme_descriptor_t *descriptor)
{
    uint32_t status;

    lsme_memory_barrier();
    status = lsme_lacc_exec(descriptor);
    if ((status & 0xffu) != 0u)
        return -(int)(status & 0xffu);
    status = lsme_lacc_wait();
    lsme_memory_barrier();
    return (status & 0xffu) == 0u ? 0 : -(int)(status & 0xffu);
}

/* C[M,N] = A[M,K] x B[K,N]；所有 stride 单位都是字节。 */
static int run_gemm(const void *src0, const void *src1, void *dst,
                    const int32_t *bias, unsigned int m, unsigned int n,
                    unsigned int k, unsigned int batch,
                    unsigned int src0_row_stride,
                    unsigned int src1_row_stride,
                    unsigned int dst_row_stride,
                    unsigned int src0_batch_stride,
                    unsigned int src1_batch_stride,
                    unsigned int dst_batch_stride,
                    unsigned int shift, unsigned int flags, uint32_t tag)
{
    volatile lsme_descriptor_t *descriptor =
        (volatile lsme_descriptor_t *)uncached(&descriptor_store);

    lsme_descriptor_clear(descriptor);
    descriptor->op_flags = lsme_descriptor_op_flags(LSME_OP_GEMM, flags);
    descriptor->src0 = accelerator_address(src0);
    descriptor->src1 = accelerator_address(src1);
    descriptor->dst = accelerator_address(dst);
    descriptor->bias = bias == NULL ? 0u : accelerator_address(bias);
    descriptor->m_n = lsme_pack_u16(m, n);
    descriptor->k_batch = lsme_pack_u16(k, batch);
    descriptor->src0_row_stride = src0_row_stride;
    descriptor->src1_row_stride = src1_row_stride;
    descriptor->dst_row_stride = dst_row_stride;
    descriptor->src0_batch_stride = src0_batch_stride;
    descriptor->src1_batch_stride = src1_batch_stride;
    descriptor->dst_batch_stride = dst_batch_stride;
    descriptor->quant_head = lsme_pack_quant_head(
        shift, 0, (flags & LSME_FLAG_HEAD4) != 0u ? HEADS : 0u,
        (flags & LSME_FLAG_HEAD4) != 0u ? HEAD_DIM : 0u);
    descriptor->user_tag = tag;
    descriptor->aux0 = lsme_descriptor_v2_aux(TINYVIT_LSME_MODE);
    return run_descriptor(descriptor);
}

static int run_softmax(const int32_t *src, uint8_t *dst, uint32_t tag)
{
    volatile lsme_descriptor_t *descriptor =
        (volatile lsme_descriptor_t *)uncached(&descriptor_store);

    lsme_descriptor_clear(descriptor);
    descriptor->op_flags = lsme_descriptor_op_flags(
        LSME_OP_SOFTMAX, LSME_FLAG_HEAD4);
    descriptor->src0 = accelerator_address(src);
    descriptor->dst = accelerator_address(dst);
    descriptor->m_n = lsme_pack_u16(TOKENS, TOKENS);
    descriptor->k_batch = lsme_pack_u16(0, HEADS);
    descriptor->src0_row_stride = TOKENS * sizeof(int32_t);
    descriptor->dst_row_stride = TOKENS;
    descriptor->src0_batch_stride = TOKENS * TOKENS * sizeof(int32_t);
    descriptor->dst_batch_stride = TOKENS * TOKENS;
    descriptor->quant_head = lsme_pack_quant_head(
        0, TINYVIT_ATTENTION_SCORE_SHIFT, HEADS, HEAD_DIM);
    descriptor->user_tag = tag;
    descriptor->aux0 = lsme_descriptor_v2_aux(TINYVIT_LSME_MODE);
    return run_descriptor(descriptor);
}

/*
 * 单条描述符启动片上融合 Attention。
 *
 * word4/word12/word15 在这个操作中有专用含义：它们依次是 V、输出中
 * 相邻 head 的偏移，以及供 DVI 热图使用的 64 个 probability 列和地址。
 * context 直接按 [token][head][lane] 写出，CPU 不再执行 merge_heads。
 */
static int run_fused_attention(const void *q, const void *k, const void *v,
                               void *context, uint32_t *attention_sum,
                               uint32_t tag)
{
    volatile lsme_descriptor_t *descriptor =
        (volatile lsme_descriptor_t *)uncached(&descriptor_store);

    lsme_descriptor_clear(descriptor);
    descriptor->op_flags = lsme_descriptor_op_flags(
        LSME_OP_FUSED_ATTENTION, LSME_FLAG_OUTPUT_INT8 | LSME_FLAG_HEAD4);
    descriptor->src0 = accelerator_address(q);
    descriptor->src1 = accelerator_address(k);
    descriptor->dst = accelerator_address(context);
    descriptor->bias = accelerator_address(v);
    descriptor->m_n = lsme_pack_u16(TOKENS, TOKENS);
    descriptor->k_batch = lsme_pack_u16(HEAD_DIM, HEADS);
    descriptor->src0_row_stride = HEAD_DIM;
    descriptor->src1_row_stride = HEAD_DIM;
    descriptor->dst_row_stride = MODEL_DIM;
    descriptor->src0_batch_stride = TOKENS * HEAD_DIM;
    descriptor->src1_batch_stride = TOKENS * HEAD_DIM;
    descriptor->dst_batch_stride = HEAD_DIM;
    descriptor->quant_head = lsme_pack_quant_head(
        TINYVIT_CONTEXT_SHIFT, TINYVIT_ATTENTION_SCORE_SHIFT, HEADS, HEAD_DIM);
    descriptor->user_tag = tag;
    descriptor->aux0 = attention_sum == NULL ? 0u : accelerator_address(attention_sum);
    return run_descriptor(descriptor);
}

static int run_vadd(const void *src0, const void *src1, void *dst,
                    uint32_t tag)
{
    volatile lsme_descriptor_t *descriptor =
        (volatile lsme_descriptor_t *)uncached(&descriptor_store);

    lsme_descriptor_clear(descriptor);
    descriptor->op_flags = lsme_descriptor_op_flags(
        LSME_OP_VECTOR_ADD, LSME_FLAG_OUTPUT_INT8);
    descriptor->src0 = accelerator_address(src0);
    descriptor->src1 = accelerator_address(src1);
    descriptor->dst = accelerator_address(dst);
    descriptor->m_n = lsme_pack_u16(TOKENS, MODEL_DIM);
    descriptor->k_batch = lsme_pack_u16(0, 1);
    descriptor->src0_row_stride = MODEL_DIM;
    descriptor->src1_row_stride = MODEL_DIM;
    descriptor->dst_row_stride = MODEL_DIM;
    descriptor->user_tag = tag;
    descriptor->aux0 = lsme_descriptor_v2_aux(TINYVIT_LSME_MODE);
    return run_descriptor(descriptor);
}

/* 与导出脚本完全相同的整数 RMSNorm，避免旧位流没有 RMSNorm 单元的问题。 */
static unsigned int rounded_divide_reciprocal(unsigned int magnitude,
                                               unsigned int denominator,
                                               unsigned int reciprocal)
{
    unsigned int quotient = (magnitude * reciprocal) >> 15;
    unsigned int remainder = magnitude - quotient * denominator;

    while (remainder >= denominator) {
        remainder -= denominator;
        ++quotient;
    }
    if (remainder * 2u >= denominator)
        ++quotient;
    return quotient;
}

static void rmsnorm(const volatile int8_t *input, volatile int8_t *output,
                    const int8_t *gain)
{
    unsigned int row;
    unsigned int col;

    for (row = 0; row < TOKENS; ++row) {
        uint32_t sum_square = 0;
        uint32_t rms;
        unsigned int denominator;
        unsigned int reciprocal;
        for (col = 0; col < MODEL_DIM; ++col) {
            int value = input[row * MODEL_DIM + col];
            sum_square += (uint32_t)(value * value);
        }
        rms = integer_sqrt(sum_square / MODEL_DIM);
        if (rms == 0u)
            rms = 1u;
        denominator = rms << TINYVIT_NORM_GAIN_FRAC;
        reciprocal = (1u << 15) / denominator;
        for (col = 0; col < MODEL_DIM; ++col) {
            int numerator = (int)input[row * MODEL_DIM + col] * (int)gain[col]
                          * (1 << TINYVIT_FRAC_TOKEN);
            int magnitude = numerator < 0 ? -numerator : numerator;
            int rounded = (int)rounded_divide_reciprocal(
                (unsigned int)magnitude, denominator, reciprocal);
            output[row * MODEL_DIM + col] = saturate_s8(
                numerator < 0 ? -rounded : rounded);
        }
    }
}

/* token-major 的 Q/K/V 拆成每个 head 连续的 [head][token][lane]。 */
static void repack_qkv_heads(const volatile int8_t *qkv,
                             volatile int8_t *q_head,
                             volatile int8_t *k_head,
                             volatile int8_t *v_head)
{
    unsigned int head;
    unsigned int token;
    unsigned int lane;

    for (head = 0; head < HEADS; ++head)
        for (token = 0; token < TOKENS; ++token)
            for (lane = 0; lane < HEAD_DIM; ++lane) {
                q_head[(head * TOKENS + token) * HEAD_DIM + lane] =
                    qkv[token * MODEL_DIM * 3u + head * HEAD_DIM + lane];
                k_head[(head * TOKENS + token) * HEAD_DIM + lane] =
                    qkv[token * MODEL_DIM * 3u + MODEL_DIM +
                        head * HEAD_DIM + lane];
                v_head[(head * TOKENS + token) * HEAD_DIM + lane] =
                    qkv[token * MODEL_DIM * 3u + MODEL_DIM * 2u +
                        head * HEAD_DIM + lane];
            }
}

static void merge_heads(const volatile int8_t *head_major,
                        volatile int8_t *linear)
{
    unsigned int head;
    unsigned int token;
    unsigned int lane;

    for (head = 0; head < HEADS; ++head)
        for (token = 0; token < TOKENS; ++token)
            for (lane = 0; lane < HEAD_DIM; ++lane)
                linear[token * MODEL_DIM + head * HEAD_DIM + lane] =
                    head_major[(head * TOKENS + token) * HEAD_DIM + lane];
}

/* 32x32 RGB 原图的每个 4x4 patch 依次写 R/G/B，共 K=48 个 INT8 元素。 */
static void prepare_patches(unsigned int sample, volatile int8_t *patch)
{
    const uint8_t *image = tinyvit_demo_images +
                           (sample % 10u) * 32u * 32u * 3u;
    unsigned int patch_row;
    unsigned int patch_col;
    unsigned int inner_row;
    unsigned int inner_col;
    unsigned int channel;

    for (patch_row = 0; patch_row < 8u; ++patch_row)
        for (patch_col = 0; patch_col < 8u; ++patch_col) {
            unsigned int token = patch_row * 8u + patch_col;
            for (inner_row = 0; inner_row < 4u; ++inner_row)
                for (inner_col = 0; inner_col < 4u; ++inner_col)
                    for (channel = 0; channel < 3u; ++channel) {
                        unsigned int pixel_index =
                            ((patch_row * 4u + inner_row) * 32u +
                             patch_col * 4u + inner_col) * 3u + channel;
                        unsigned int patch_index = token * PATCH_DIM +
                            (inner_row * 4u + inner_col) * 3u + channel;
                        patch[patch_index] = (int8_t)(
                            ((unsigned int)image[pixel_index] * 127u + 127u) / 255u);
                    }
        }
}

static void pool_tokens(const volatile int8_t *token,
                        volatile int8_t *classifier_input)
{
    unsigned int row;
    unsigned int col;

    for (row = 0; row < 4u; ++row)
        for (col = 0; col < MODEL_DIM; ++col)
            classifier_input[row * MODEL_DIM + col] = 0;
    for (col = 0; col < MODEL_DIM; ++col) {
        int sum = 0;
        for (row = 0; row < TOKENS; ++row)
            sum += token[row * MODEL_DIM + col];
        classifier_input[col] = saturate_s8(round_nearest_even(sum, TOKENS));
    }
}

/* 将最后一层 Attention 的 key 列和压缩为 8x8 热图，DVI 不需要概率矩阵本身。 */
static void make_attention_map(const volatile uint8_t *probability,
                               uint8_t *map)
{
    uint32_t sums[TOKENS];
    uint32_t minimum = 0xffffffffu;
    uint32_t maximum = 0;
    unsigned int key;
    unsigned int query;
    unsigned int head;

    for (key = 0; key < TOKENS; ++key) {
        uint32_t sum = 0;
        for (head = 0; head < HEADS; ++head)
            for (query = 0; query < TOKENS; ++query)
                sum += probability[(head * TOKENS + query) * TOKENS + key];
        sums[key] = sum;
        if (sum < minimum)
            minimum = sum;
        if (sum > maximum)
            maximum = sum;
    }
    for (key = 0; key < TOKENS; ++key)
        map[key] = maximum == minimum ? 128u : (uint8_t)(
            ((sums[key] - minimum) * 255u) / (maximum - minimum));
}

/* 融合硬件导出的就是上面双重循环的列和，软件只保留同一归一化显示规则。 */
static void make_attention_map_sum(const volatile uint32_t *sums, uint8_t *map)
{
    uint32_t minimum = 0xffffffffu;
    uint32_t maximum = 0;
    unsigned int key;

    for (key = 0; key < TOKENS; ++key) {
        uint32_t sum = sums[key];
        if (sum < minimum)
            minimum = sum;
        if (sum > maximum)
            maximum = sum;
    }
    for (key = 0; key < TOKENS; ++key)
        map[key] = maximum == minimum ? 128u : (uint8_t)(
            ((sums[key] - minimum) * 255u) / (maximum - minimum));
}

static void make_class_scores(const int32_t *logits, uint8_t *scores)
{
    int32_t minimum = logits[0];
    int32_t maximum = logits[0];
    unsigned int index;

    for (index = 1; index < 10u; ++index) {
        if (logits[index] < minimum)
            minimum = logits[index];
        if (logits[index] > maximum)
            maximum = logits[index];
    }
    for (index = 0; index < 10u; ++index)
        scores[index] = maximum == minimum ? 128u : (uint8_t)(
            ((uint32_t)(logits[index] - minimum) * 255u) /
            (uint32_t)(maximum - minimum));
}

/* 执行一层标准 Transformer：RMSNorm、QKV、Attention、投影、MLP 和两次残差。 */
static int run_transformer_block(unsigned int block,
                                 volatile int8_t *token,
                                 volatile int8_t *normal,
                                 volatile int8_t *qkv,
                                 volatile int8_t *q_head,
                                 volatile int8_t *k_head,
                                 volatile int8_t *v_head,
                                 volatile int32_t *score,
                                 volatile uint8_t *probability,
                                 volatile int8_t *context_head,
                                 volatile int8_t *context,
                                 volatile uint32_t *attention_sum,
                                 volatile int8_t *projection,
                                 volatile int8_t *hidden,
                                 volatile int8_t *mlp)
{
    const transformer_block_t *parameter = &transformer_block[block];
    uint32_t suffix = block == 0u ? 0x30u : 0x31u;
    int rc;

    rmsnorm(token, normal, parameter->norm1_gain);

    /* block1 的 Q/K/V 量化位移不同，故安全地分三次 GEMM，而非错误地拼接。 */
    rc = run_gemm((const void *)normal, parameter->q_weight, (void *)qkv,
                  parameter->q_bias, TOKENS, MODEL_DIM, MODEL_DIM, 1,
                  MODEL_DIM, MODEL_DIM, MODEL_DIM * 3u, 0, 0, 0,
                  parameter->q_shift, LSME_FLAG_OUTPUT_INT8 | LSME_FLAG_BIAS,
                  0x51400000u | suffix);
    if (rc != 0) return -200 + rc;
    rc = run_gemm((const void *)normal, parameter->k_weight,
                  (void *)(qkv + MODEL_DIM), parameter->k_bias,
                  TOKENS, MODEL_DIM, MODEL_DIM, 1,
                  MODEL_DIM, MODEL_DIM, MODEL_DIM * 3u, 0, 0, 0,
                  parameter->k_shift, LSME_FLAG_OUTPUT_INT8 | LSME_FLAG_BIAS,
                  0x4b000000u | suffix);
    if (rc != 0) return -220 + rc;
    rc = run_gemm((const void *)normal, parameter->v_weight,
                  (void *)(qkv + MODEL_DIM * 2u), parameter->v_bias,
                  TOKENS, MODEL_DIM, MODEL_DIM, 1,
                  MODEL_DIM, MODEL_DIM, MODEL_DIM * 3u, 0, 0, 0,
                  parameter->v_shift, LSME_FLAG_OUTPUT_INT8 | LSME_FLAG_BIAS,
                  0x56000000u | suffix);
    if (rc != 0) return -240 + rc;

    repack_qkv_heads(qkv, q_head, k_head, v_head);
#if TINYVIT_USE_FUSED_ATTENTION
    rc = run_fused_attention((const void *)q_head, (const void *)k_head,
                             (const void *)v_head, (void *)context,
                             (uint32_t *)attention_sum,
                             0x46415454u | suffix);
    if (rc != 0) return -260 + rc;
#if TINYVIT_FUSED_SHADOW_CHECK
    /* 仅仿真诊断：用完全原有的三条描述符复算并定位融合输出首个差异。 */
    rc = run_gemm((const void *)q_head, (const void *)k_head, (void *)score,
                  NULL, TOKENS, TOKENS, HEAD_DIM, HEADS,
                  HEAD_DIM, HEAD_DIM, TOKENS * sizeof(int32_t),
                  TOKENS * HEAD_DIM, TOKENS * HEAD_DIM,
                  TOKENS * TOKENS * sizeof(int32_t), 0,
                  LSME_FLAG_TRANS_B | LSME_FLAG_HEAD4, 0x41534430u | suffix);
    if (rc != 0) return -261 + rc;
    rc = run_softmax((const int32_t *)score, (uint8_t *)probability,
                     0x53534430u | suffix);
    if (rc != 0) return -262 + rc;
    rc = run_gemm((const void *)probability, (const void *)v_head,
                  (void *)context_head, NULL, TOKENS, HEAD_DIM, TOKENS, HEADS,
                  TOKENS, HEAD_DIM, HEAD_DIM, TOKENS * TOKENS,
                  TOKENS * HEAD_DIM, TOKENS * HEAD_DIM, TINYVIT_CONTEXT_SHIFT,
                  LSME_FLAG_OUTPUT_INT8 | LSME_FLAG_HEAD4, 0x43534430u | suffix);
    if (rc != 0) return -263 + rc;
    merge_heads(context_head, (volatile int8_t *)uncached(context_reference_store));
    {
        unsigned int debug_index;
        for (debug_index = 0; debug_index < TOKENS * MODEL_DIM; ++debug_index)
            if (context[debug_index] !=
                ((volatile int8_t *)uncached(context_reference_store))[debug_index]) {
                printf("FUSED_SHADOW_DIFF block=%u token=%u head=%u lane=%u "
                       "fused=%d reference=%d\n", block,
                       debug_index / MODEL_DIM,
                       (debug_index % MODEL_DIM) / HEAD_DIM,
                       debug_index % HEAD_DIM, context[debug_index],
                       ((volatile int8_t *)uncached(context_reference_store))[debug_index]);
                return -900 - (int)debug_index;
            }
    }
#endif
#else
    rc = run_gemm((const void *)q_head, (const void *)k_head, (void *)score,
                  NULL, TOKENS, TOKENS, HEAD_DIM, HEADS,
                  HEAD_DIM, HEAD_DIM, TOKENS * sizeof(int32_t),
                  TOKENS * HEAD_DIM, TOKENS * HEAD_DIM,
                  TOKENS * TOKENS * sizeof(int32_t), 0,
                  LSME_FLAG_TRANS_B | LSME_FLAG_HEAD4, 0x41540000u | suffix);
    if (rc != 0) return -260 + rc;
    rc = run_softmax((const int32_t *)score, (uint8_t *)probability,
                     0x534f0000u | suffix);
    if (rc != 0) return -280 + rc;
    rc = run_gemm((const void *)probability, (const void *)v_head,
                  (void *)context_head, NULL, TOKENS, HEAD_DIM, TOKENS, HEADS,
                  TOKENS, HEAD_DIM, HEAD_DIM, TOKENS * TOKENS,
                  TOKENS * HEAD_DIM, TOKENS * HEAD_DIM, TINYVIT_CONTEXT_SHIFT,
                  LSME_FLAG_OUTPUT_INT8 | LSME_FLAG_HEAD4, 0x43540000u | suffix);
    if (rc != 0) return -300 + rc;
    merge_heads(context_head, context);
#endif

    rc = run_gemm((const void *)context, parameter->projection_weight,
                  (void *)projection, parameter->projection_bias,
                  TOKENS, MODEL_DIM, MODEL_DIM, 1,
                  MODEL_DIM, MODEL_DIM, MODEL_DIM, 0, 0, 0,
                  parameter->projection_shift,
                  LSME_FLAG_OUTPUT_INT8 | LSME_FLAG_BIAS, 0x50520000u | suffix);
    if (rc != 0) return -320 + rc;
    rc = run_vadd((const void *)token, (const void *)projection, (void *)token,
                  0x52310000u | suffix);
    if (rc != 0) return -340 + rc;

    rmsnorm(token, normal, parameter->norm2_gain);
    rc = run_gemm((const void *)normal, parameter->mlp1_weight,
                  (void *)hidden, parameter->mlp1_bias,
                  TOKENS, MLP_DIM, MODEL_DIM, 1,
                  MODEL_DIM, MLP_DIM, MLP_DIM, 0, 0, 0,
                  parameter->mlp1_shift,
                  LSME_FLAG_OUTPUT_INT8 | LSME_FLAG_BIAS | LSME_FLAG_RELU,
                  0x4d310000u | suffix);
    if (rc != 0) return -360 + rc;
    rc = run_gemm((const void *)hidden, parameter->mlp2_weight,
                  (void *)mlp, parameter->mlp2_bias,
                  TOKENS, MODEL_DIM, MLP_DIM, 1,
                  MLP_DIM, MODEL_DIM, MODEL_DIM, 0, 0, 0,
                  parameter->mlp2_shift, LSME_FLAG_OUTPUT_INT8 | LSME_FLAG_BIAS,
                  0x4d320000u | suffix);
    if (rc != 0) return -380 + rc;
    rc = run_vadd((const void *)token, (const void *)mlp, (void *)token,
                  0x52320000u | suffix);
    return rc == 0 ? 0 : -400 + rc;
}

const uint8_t *cifar_tinyvit_sample_preview_rgb332(unsigned int sample)
{
    return tinyvit_demo_preview_rgb332 + (sample % 10u) * 32u * 32u;
}

const char *cifar_tinyvit_class_name(unsigned int class_id)
{
    return tinyvit_class_names[class_id < 10u ? class_id : 0u];
}

int cifar_tinyvit_infer(unsigned int sample, cifar_tinyvit_result_t *result)
{
    volatile int8_t *patch = (volatile int8_t *)uncached(patch_store);
    volatile int8_t *token = (volatile int8_t *)uncached(token_store);
    volatile int8_t *normal = (volatile int8_t *)uncached(normal_store);
    volatile int8_t *qkv = (volatile int8_t *)uncached(qkv_linear_store);
    volatile int8_t *q_head = (volatile int8_t *)uncached(q_head_store);
    volatile int8_t *k_head = (volatile int8_t *)uncached(k_head_store);
    volatile int8_t *v_head = (volatile int8_t *)uncached(v_head_store);
    volatile int32_t *score = (volatile int32_t *)uncached(score_store);
    volatile uint8_t *probability =
        (volatile uint8_t *)uncached(probability_store);
    volatile int8_t *context_head =
        (volatile int8_t *)uncached(context_head_store);
    volatile int8_t *context = (volatile int8_t *)uncached(context_store);
    volatile uint32_t *attention_sum =
        (volatile uint32_t *)uncached(attention_sum_store);
    volatile int8_t *projection = (volatile int8_t *)uncached(projection_store);
    volatile int8_t *hidden = (volatile int8_t *)uncached(hidden_store);
    volatile int8_t *mlp = (volatile int8_t *)uncached(mlp_store);
    volatile int8_t *final = (volatile int8_t *)uncached(final_store);
    volatile int8_t *classifier_input =
        (volatile int8_t *)uncached(classifier_input_store);
    volatile int32_t *classifier_output =
        (volatile int32_t *)uncached(classifier_output_store);
    uint32_t descriptor_before;
    uint32_t tiles_before;
    uint32_t softmax_before;
    uint32_t start_cycles;
    uint32_t feature;
    unsigned int block;
    unsigned int index;
    int rc;

    if (result == NULL)
        return -1;
    sample %= 10u;
    result->error = 0;
    result->bit_exact = 1u;
    result->fused_attention = TINYVIT_USE_FUSED_ATTENTION ? 1u : 0u;

    feature = lsme_lacc_ctrl_query();
    result->lanes = (uint8_t)((feature >> 16) & 0xffu);
    if ((feature >> 24) != 2u || result->lanes == 0u) {
        result->error = -2;
        return result->error;
    }

    lsme_lacc_ctrl_clear();
    descriptor_before = lsme_read(LSME_REG_PERF_DESC);
    tiles_before = lsme_read(LSME_REG_PERF_TILES);
    softmax_before = lsme_read(LSME_REG_PERF_SOFTMAX);
    start_cycles = (uint32_t)get_cpu_clock_count();

    prepare_patches(sample, patch);
    rc = run_gemm((const void *)patch, tinyvit_patch_weight, (void *)token,
                  tinyvit_patch_bias, TOKENS, MODEL_DIM, PATCH_DIM, 1,
                  PATCH_DIM, MODEL_DIM, MODEL_DIM, 0, 0, 0,
                  TINYVIT_PATCH_SHIFT, LSME_FLAG_OUTPUT_INT8 | LSME_FLAG_BIAS,
                  0x50415443u);
    if (rc != 0) { result->error = -100 + rc; return result->error; }
    rc = run_vadd((const void *)token, tinyvit_position, (void *)token,
                  0x504f534eu);
    if (rc != 0) { result->error = -120 + rc; return result->error; }

    for (block = 0; block < BLOCKS; ++block) {
        rc = run_transformer_block(block, token, normal, qkv, q_head, k_head,
                                   v_head, score, probability, context_head,
                                   context, attention_sum, projection, hidden, mlp);
        if (rc != 0) {
            result->error = -(int)((block + 1u) * 1000u) + rc;
            return result->error;
        }
    }

    rmsnorm(token, final, tinyvit_final_norm_gain);
    pool_tokens(final, classifier_input);
    rc = run_gemm((const void *)classifier_input, tinyvit_classifier_weight,
                  (void *)classifier_output, tinyvit_classifier_bias,
                  4, CLASSES_PADDED, MODEL_DIM, 1,
                  MODEL_DIM, CLASSES_PADDED, CLASSES_PADDED * sizeof(int32_t),
                  0, 0, 0, 0, LSME_FLAG_BIAS, 0x434c4153u);
    if (rc != 0) { result->error = -5000 + rc; return result->error; }

    result->cycles = (uint32_t)get_cpu_clock_count() - start_cycles;
    result->descriptors = lsme_read(LSME_REG_PERF_DESC) - descriptor_before;
    result->mopa_count = lsme_read(LSME_REG_PERF_MOPA);
    result->gemm_tiles = lsme_read(LSME_REG_PERF_TILES) - tiles_before;
    result->softmax_rows = lsme_read(LSME_REG_PERF_SOFTMAX) - softmax_before;
    result->rmsnorm_rows = 0u; /* 本位流中三次/层 RMSNorm 是软件精确实现。 */
    result->predicted = 0u;
    for (index = 0; index < 10u; ++index) {
        result->logits[index] = classifier_output[index];
        if (result->logits[index] !=
            tinyvit_demo_expected_logits[sample * 10u + index])
            result->bit_exact = 0u;
        if (result->logits[index] > result->logits[result->predicted])
            result->predicted = (uint8_t)index;
    }
    result->expected = tinyvit_demo_labels[sample];
    result->test_index = tinyvit_demo_indices[sample];
    make_class_scores(result->logits, result->class_scores);
#if TINYVIT_USE_FUSED_ATTENTION
    make_attention_map_sum(attention_sum, result->attention_map);
#else
    make_attention_map(probability, result->attention_map);
#endif
    return 0;
}
