#include <stdint.h>
#include <stddef.h>

#include "confreg_time.h"
#include "lsme.h"
#include "tinyvit_model.h"
#include "tinyvit_runtime.h"

#define TOKENS 64
#define MODEL_DIM 32
#define HEADS 4
#define HEAD_DIM 8
#define MLP_DIM 64
#define CLASSES_PADDED 12
#define TINYVIT_USE_HW_VADD 1

// 默认使用新版 LSME 的硬件 RMSNorm。兼容已经实板验证的 V2 缓存位流时，
// 构建命令可传入 -DTINYVIT_USE_HW_RMSNORM=0，使三处归一化回退到下面的
// 定点软件实现；这样也不会访问旧硬件中不存在的 0x54 性能寄存器。
#ifndef TINYVIT_USE_HW_RMSNORM
#define TINYVIT_USE_HW_RMSNORM 1
#endif

/* mode=2 强制使用已经实板验证的 V1 流式 GEMM 路径。 */
#ifndef TINYVIT_LSME_MODE
#define TINYVIT_LSME_MODE LSME_V2_MODE_AUTO
#endif

// 使用描述符的行/批次步长把 QKV 输出直接解释为每个 attention head 的视图。
// 这样无需 CPU 将 token-major 的 QKV 重排为三个 head-major 缓冲区，也可让
// AV GEMM 直接写入后续投影层所需的 token-major context 布局。
// 该优化不增加新的硬件指令，只复用 V2 GEMM 已有的描述符寻址能力。
#ifndef TINYVIT_ZERO_COPY_HEAD_LAYOUT
#define TINYVIT_ZERO_COPY_HEAD_LAYOUT 1
#endif

/*
 * 远程板排障开关：保留旧版四块 Attention 临时缓冲区，并补齐被零拷贝路径
 * 缩短的代码长度。这样可让启动阶段的 data LMA、BSS 终点与区域赛基线一致，
 * 排除外部 BaseRAM 对程序地址布局敏感的可能性；这些缓冲区不参与零拷贝计算。
 */
#ifndef TINYVIT_LAYOUT_STABLE
#define TINYVIT_LAYOUT_STABLE 0
#endif

#define ALIGNED64 __attribute__((aligned(64)))

static int8_t patch_store[TOKENS * 16] ALIGNED64;
static int8_t token_store[TOKENS * MODEL_DIM] ALIGNED64;
static int8_t normal_store[TOKENS * MODEL_DIM] ALIGNED64;
static int8_t qkv_linear_store[TOKENS * MODEL_DIM * 3] ALIGNED64;
static int8_t qkv_weight_store[MODEL_DIM * MODEL_DIM * 3] ALIGNED64;
static int32_t qkv_bias_store[MODEL_DIM * 3] ALIGNED64;
static uint8_t qkv_parameters_ready;
#if !TINYVIT_ZERO_COPY_HEAD_LAYOUT || TINYVIT_LAYOUT_STABLE
static int8_t q_head_store[HEADS * TOKENS * HEAD_DIM] ALIGNED64;
static int8_t k_head_store[HEADS * TOKENS * HEAD_DIM] ALIGNED64;
static int8_t v_head_store[HEADS * TOKENS * HEAD_DIM] ALIGNED64;
#endif
static int32_t score_store[HEADS * TOKENS * TOKENS] ALIGNED64;
static uint8_t probability_store[HEADS * TOKENS * TOKENS] ALIGNED64;
#if !TINYVIT_ZERO_COPY_HEAD_LAYOUT || TINYVIT_LAYOUT_STABLE
static int8_t context_head_store[HEADS * TOKENS * HEAD_DIM] ALIGNED64;
#endif

#if TINYVIT_ZERO_COPY_HEAD_LAYOUT && TINYVIT_LAYOUT_STABLE
/*
 * -fdata-sections + --gc-sections 会删除未使用的静态数组。该空汇编只把四个
 * 地址作为输入传给编译器，不会读取或写入它们，却能保留旧版的确切 BSS 布局。
 */
static void retain_legacy_attention_layout(void) __attribute__((noinline));
static void retain_legacy_attention_layout(void)
{
    __asm__ volatile (""
                      :
                      : "r"(q_head_store), "r"(k_head_store),
                        "r"(v_head_store), "r"(context_head_store)
                      : "memory");
}
#endif
static int8_t context_store[TOKENS * MODEL_DIM] ALIGNED64;
static int8_t projection_store[TOKENS * MODEL_DIM] ALIGNED64;
static int8_t hidden_store[TOKENS * MLP_DIM] ALIGNED64;
static int8_t mlp_store[TOKENS * MODEL_DIM] ALIGNED64;
static int8_t final_store[TOKENS * MODEL_DIM] ALIGNED64;
static int8_t classifier_input_store[4 * MODEL_DIM] ALIGNED64;
static int32_t classifier_output_store[4 * CLASSES_PADDED] ALIGNED64;
static lsme_descriptor_t descriptor_store ALIGNED64;

static volatile void *uncached(const void *pointer)
{
    return (volatile void *)lsme_uncached_ptr(pointer);
}

// 描述符地址字段只有 32 位，因此这里把 C 指针转换成 LSME 可使用的
// 32 位非缓存地址。硬件收到后会在 physical_addr() 中去掉 DMW 别名前缀。
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

#if !TINYVIT_USE_HW_RMSNORM
static uint32_t integer_sqrt(uint32_t value)
{
    uint32_t result = 0;
    uint32_t bit = 1u << 30;

    while (bit > value)
        bit >>= 2;
    while (bit != 0) {
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
#endif

static int round_nearest_even(int numerator, int denominator)
{
    unsigned int magnitude = numerator < 0
                           ? (unsigned int)(-numerator)
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
    if ((status & 0xffu) != 0)
        return -(int)(status & 0xffu);
    status = lsme_lacc_wait();
    lsme_memory_barrier();
    return (status & 0xffu) == 0 ? 0 : -(int)(status & 0xffu);
}

// GEMM 的数学含义：C[batch][M×N] = A[batch][M×K] × B[batch][K×N]。
// M 是输出行数，N 是输出列数，K 是乘加归约长度；batch 表示独立矩阵乘
// 的组数。TRANS_B 置位时，B 在内存中按 N×K 保存，但数学意义仍是 K×N。
static int run_gemm(const void *src0, const void *src1, void *dst,
                    const int32_t *bias, unsigned int m, unsigned int n,
                    unsigned int k, unsigned int batch,
                    unsigned int src0_row_stride,
                    unsigned int src1_row_stride,
                    unsigned int dst_row_stride,
                    unsigned int src0_batch_stride,
                    unsigned int src1_batch_stride,
                    unsigned int dst_batch_stride,
                    unsigned int shift, unsigned int flags,
                    uint32_t tag)
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
        shift, 0, (flags & LSME_FLAG_HEAD4) != 0 ? HEADS : 0,
        (flags & LSME_FLAG_HEAD4) != 0 ? HEAD_DIM : 0);
    descriptor->user_tag = tag;
    descriptor->aux0 = lsme_descriptor_v2_aux(TINYVIT_LSME_MODE);
    return run_descriptor(descriptor);
}

static int run_softmax(const int32_t *src, uint8_t *dst)
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
    descriptor->user_tag = 0x534f4654u; /* ASCII "SOFT"，用于调试识别 */
    return run_descriptor(descriptor);
}

static int run_vadd(const void *src0, const void *src1, void *dst,
                    unsigned int rows, unsigned int columns,
                    unsigned int src0_row_stride,
                    unsigned int src1_row_stride,
                    unsigned int dst_row_stride, uint32_t tag)
{
    volatile lsme_descriptor_t *descriptor =
        (volatile lsme_descriptor_t *)uncached(&descriptor_store);

    lsme_descriptor_clear(descriptor);
    descriptor->op_flags = lsme_descriptor_op_flags(
        LSME_OP_VECTOR_ADD, LSME_FLAG_OUTPUT_INT8);
    descriptor->src0 = accelerator_address(src0);
    descriptor->src1 = accelerator_address(src1);
    descriptor->dst = accelerator_address(dst);
    descriptor->m_n = lsme_pack_u16(rows, columns);
    descriptor->k_batch = lsme_pack_u16(0, 1);
    descriptor->src0_row_stride = src0_row_stride;
    descriptor->src1_row_stride = src1_row_stride;
    descriptor->dst_row_stride = dst_row_stride;
    descriptor->user_tag = tag;
    return run_descriptor(descriptor);
}

// RMSNorm 描述符把 M 解释为行数、N 解释为每行元素数；src0 是 INT8
// 输入，src1 是长度为 N 的 INT8 增益向量，dst 是 INT8 输出。word13 的
// 低两个字节分别传递 token_frac 和 gain_frac，硬件复现软件定点公式。
static int run_rmsnorm(const void *src, const int8_t *gain, void *dst,
                       unsigned int rows, unsigned int columns,
                       uint32_t tag)
{
    volatile lsme_descriptor_t *descriptor =
        (volatile lsme_descriptor_t *)uncached(&descriptor_store);

    lsme_descriptor_clear(descriptor);
    descriptor->op_flags = lsme_descriptor_op_flags(
        LSME_OP_RMSNORM, LSME_FLAG_OUTPUT_INT8);
    descriptor->src0 = accelerator_address(src);
    descriptor->src1 = accelerator_address(gain);
    descriptor->dst = accelerator_address(dst);
    descriptor->m_n = lsme_pack_u16(rows, columns);
    descriptor->k_batch = lsme_pack_u16(0, 1);
    descriptor->src0_row_stride = columns;
    descriptor->dst_row_stride = columns;
    descriptor->quant_head = lsme_pack_quant_head(
        TINYVIT_FRAC_TOKEN, TINYVIT_NORM_GAIN_FRAC, 0, 0);
    descriptor->user_tag = tag;
    return run_descriptor(descriptor);
}

static void prepare_qkv_parameters(void)
{
    volatile int8_t *weight =
        (volatile int8_t *)uncached(qkv_weight_store);
    volatile int32_t *bias =
        (volatile int32_t *)uncached(qkv_bias_store);
    unsigned int row;
    unsigned int col;

    if (qkv_parameters_ready)
        return;
    for (row = 0; row < MODEL_DIM; ++row) {
        for (col = 0; col < MODEL_DIM; ++col) {
            weight[row * (MODEL_DIM * 3u) + col] =
                tinyvit_q_weight[row * MODEL_DIM + col];
            weight[row * (MODEL_DIM * 3u) + MODEL_DIM + col] =
                tinyvit_k_weight[row * MODEL_DIM + col];
            weight[row * (MODEL_DIM * 3u) + MODEL_DIM * 2u + col] =
                tinyvit_v_weight[row * MODEL_DIM + col];
        }
    }
    for (col = 0; col < MODEL_DIM; ++col) {
        bias[col] = tinyvit_q_bias[col];
        bias[MODEL_DIM + col] = tinyvit_k_bias[col];
        bias[MODEL_DIM * 2u + col] = tinyvit_v_bias[col];
    }
    lsme_memory_barrier();
    qkv_parameters_ready = 1;
}

static void prepare_patches(unsigned int sample, volatile int8_t *patch)
{
    const uint8_t *image = tinyvit_demo_images + sample * 28u * 28u;
    unsigned int patch_row;
    unsigned int patch_col;
    unsigned int inner_row;
    unsigned int inner_col;

    for (patch_row = 0; patch_row < 8; ++patch_row) {
        for (patch_col = 0; patch_col < 8; ++patch_col) {
            unsigned int token = patch_row * 8u + patch_col;
            for (inner_row = 0; inner_row < 4; ++inner_row) {
                for (inner_col = 0; inner_col < 4; ++inner_col) {
                    int y = (int)(patch_row * 4u + inner_row) - 2;
                    int x = (int)(patch_col * 4u + inner_col) - 2;
                    unsigned int pixel = 0;
                    if (x >= 0 && x < 28 && y >= 0 && y < 28)
                        pixel = image[(unsigned int)y * 28u + (unsigned int)x];
                    patch[token * 16u + inner_row * 4u + inner_col] =
                        (int8_t)((pixel * 127u + 127u) / 255u);
                }
            }
        }
    }
}

static void add_position(volatile int8_t *token)
{
    unsigned int index;
    for (index = 0; index < TOKENS * MODEL_DIM; ++index)
        token[index] = saturate_s8((int)token[index] + tinyvit_position[index]);
}

#if !TINYVIT_USE_HW_RMSNORM
static unsigned int rounded_divide_reciprocal(unsigned int magnitude,
                                               unsigned int denominator,
                                               unsigned int reciprocal)
{
    unsigned int quotient = (magnitude * reciprocal) >> 15;
    unsigned int remainder = magnitude - quotient * denominator;

    // reciprocal=floor(2^15/denominator)，因此初始商只可能偏小，不会越界偏大。
    while (remainder >= denominator) {
        remainder -= denominator;
        ++quotient;
    }
    if (remainder * 2u >= denominator)
        ++quotient;
    return quotient;
}

static void rmsnorm(const volatile int8_t *input, volatile int8_t *output,
                    const int8_t *gain, unsigned int rows,
                    unsigned int columns)
{
    unsigned int row;
    unsigned int col;

    for (row = 0; row < rows; ++row) {
        uint32_t sum_square = 0;
        uint32_t rms;
        unsigned int denominator;
        unsigned int reciprocal;
        for (col = 0; col < columns; ++col) {
            int value = input[row * columns + col];
            sum_square += (uint32_t)(value * value);
        }
        rms = integer_sqrt(sum_square / columns);
        if (rms == 0)
            rms = 1;
        denominator = rms << TINYVIT_NORM_GAIN_FRAC;
        reciprocal = (1u << 15) / denominator;
        for (col = 0; col < columns; ++col) {
            int numerator = (int)input[row * columns + col]
                          * (int)gain[col] * (1 << TINYVIT_FRAC_TOKEN);
            int magnitude = numerator < 0 ? -numerator : numerator;
            int rounded = (int)rounded_divide_reciprocal(
                (unsigned int)magnitude, denominator, reciprocal);
            output[row * columns + col] = saturate_s8(
                numerator < 0 ? -rounded : rounded);
        }
    }
}
#endif

#if !TINYVIT_ZERO_COPY_HEAD_LAYOUT
// 旧布局的基线实现：显式把 token-major QKV 搬运为 head-major 缓冲区。
// 保留它是为了让 TINYVIT_ZERO_COPY_HEAD_LAYOUT=0 可复现分赛区决赛基线。
static void repack_qkv_heads(const volatile int8_t *qkv,
                             volatile int8_t *q_head,
                             volatile int8_t *k_head,
                             volatile int8_t *v_head)
{
    unsigned int head;
    unsigned int token;
    unsigned int lane;
    for (head = 0; head < HEADS; ++head) {
        for (token = 0; token < TOKENS; ++token) {
            for (lane = 0; lane < HEAD_DIM; ++lane) {
                q_head[(head * TOKENS + token) * HEAD_DIM + lane] =
                    qkv[token * (MODEL_DIM * 3u) +
                        head * HEAD_DIM + lane];
                k_head[(head * TOKENS + token) * HEAD_DIM + lane] =
                    qkv[token * (MODEL_DIM * 3u) + MODEL_DIM +
                        head * HEAD_DIM + lane];
                v_head[(head * TOKENS + token) * HEAD_DIM + lane] =
                    qkv[token * (MODEL_DIM * 3u) + MODEL_DIM * 2u +
                        head * HEAD_DIM + lane];
            }
        }
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
#endif

static void residual_add(volatile int8_t *token,
                         const volatile int8_t *residual)
{
    unsigned int index;
    for (index = 0; index < TOKENS * MODEL_DIM; ++index)
        token[index] = saturate_s8((int)token[index] + (int)residual[index]);
}

static void pool_tokens(const volatile int8_t *token,
                        volatile int8_t *classifier_input)
{
    unsigned int row;
    unsigned int col;

    for (row = 0; row < 4; ++row)
        for (col = 0; col < MODEL_DIM; ++col)
            classifier_input[row * MODEL_DIM + col] = 0;
    for (col = 0; col < MODEL_DIM; ++col) {
        int sum = 0;
        for (row = 0; row < TOKENS; ++row)
            sum += token[row * MODEL_DIM + col];
        classifier_input[col] = saturate_s8(round_nearest_even(sum, TOKENS));
    }
}

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
    for (key = 0; key < TOKENS; ++key) {
        if (maximum == minimum)
            map[key] = 128;
        else
            map[key] = (uint8_t)(((sums[key] - minimum) * 255u)
                               / (maximum - minimum));
    }
}

static void make_class_scores(const int32_t *logits, uint8_t *scores)
{
    int32_t minimum = logits[0];
    int32_t maximum = logits[0];
    unsigned int index;

    for (index = 1; index < 10; ++index) {
        if (logits[index] < minimum)
            minimum = logits[index];
        if (logits[index] > maximum)
            maximum = logits[index];
    }
    for (index = 0; index < 10; ++index) {
        if (maximum == minimum)
            scores[index] = 128;
        else
            scores[index] = (uint8_t)(((uint32_t)(logits[index] - minimum)
                                     * 255u)
                                    / (uint32_t)(maximum - minimum));
    }
}

const uint8_t *tinyvit_sample_image(unsigned int sample)
{
    return tinyvit_demo_images + (sample % 10u) * 28u * 28u;
}

const char *tinyvit_class_name(unsigned int class_id)
{
    return tinyvit_class_names[class_id < 10u ? class_id : 0u];
}

int tinyvit_infer(unsigned int sample, tinyvit_result_t *result)
{
    volatile int8_t *patch = (volatile int8_t *)uncached(patch_store);
    volatile int8_t *token = (volatile int8_t *)uncached(token_store);
    volatile int8_t *normal = (volatile int8_t *)uncached(normal_store);
    volatile int8_t *qkv_linear =
        (volatile int8_t *)uncached(qkv_linear_store);
#if !TINYVIT_ZERO_COPY_HEAD_LAYOUT
    volatile int8_t *q_head = (volatile int8_t *)uncached(q_head_store);
    volatile int8_t *k_head = (volatile int8_t *)uncached(k_head_store);
    volatile int8_t *v_head = (volatile int8_t *)uncached(v_head_store);
#endif
    volatile int32_t *score = (volatile int32_t *)uncached(score_store);
    volatile uint8_t *probability =
        (volatile uint8_t *)uncached(probability_store);
#if !TINYVIT_ZERO_COPY_HEAD_LAYOUT
    volatile int8_t *context_head =
        (volatile int8_t *)uncached(context_head_store);
#endif
    volatile int8_t *context = (volatile int8_t *)uncached(context_store);
    volatile int8_t *projection =
        (volatile int8_t *)uncached(projection_store);
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
    uint32_t rmsnorm_before;
    uint32_t engine_before;
    uint32_t read_beats_before;
    uint32_t write_beats_before;
    uint32_t compute_before;
    uint32_t stall_before;
    uint32_t overlap_before;
    uint32_t start_cycles;
    uint32_t feature;
    unsigned int index;
    int rc;

    if (result == NULL)
        return -1;
    sample %= 10u;
    result->error = 0;
    result->bit_exact = 1;

    prepare_qkv_parameters();

    feature = lsme_lacc_ctrl_query();
    result->lanes = (uint8_t)((feature >> 16) & 0xffu);
    if ((feature >> 24) != 2u || result->lanes == 0) {
        result->error = -2;
        return result->error;
    }

    lsme_lacc_ctrl_clear();
    descriptor_before = lsme_read(LSME_REG_PERF_DESC);
    tiles_before = lsme_read(LSME_REG_PERF_TILES);
    softmax_before = lsme_read(LSME_REG_PERF_SOFTMAX);
#if TINYVIT_USE_HW_RMSNORM
    rmsnorm_before = lsme_read(LSME_REG_PERF_RMSNORM);
#else
    rmsnorm_before = 0;
#endif
    engine_before = lsme_read(LSME_REG_PERF_ENGINE);
    read_beats_before = lsme_read(LSME_REG_PERF_AXI_READ);
    write_beats_before = lsme_read(LSME_REG_PERF_AXI_WRITE);
    compute_before = lsme_read(LSME_REG_PERF_COMPUTE);
    stall_before = lsme_read(LSME_REG_PERF_STALL);
    overlap_before = lsme_read(LSME_REG_PERF_OVERLAP);
    start_cycles = (uint32_t)get_cpu_clock_count();

    prepare_patches(sample, patch);
    rc = run_gemm((const void *)patch, tinyvit_patch_weight,
                  (void *)token, tinyvit_patch_bias,
                  TOKENS, MODEL_DIM, 16, 1, 16, MODEL_DIM, MODEL_DIM,
                  0, 0, 0, TINYVIT_PATCH_SHIFT,
                  LSME_FLAG_OUTPUT_INT8 | LSME_FLAG_BIAS, 0x50415443u);
    if (rc != 0) { result->error = -100 + rc; return result->error; }
#if TINYVIT_USE_HW_VADD
    rc = run_vadd((const void *)token, tinyvit_position, (void *)token,
                  TOKENS, MODEL_DIM, MODEL_DIM, MODEL_DIM, MODEL_DIM,
                  0x504f534eu); /* ASCII "POSN"：位置编码加法 */
    if (rc != 0) { result->error = -150 + rc; return result->error; }
#else
    add_position(token);
#endif
#if TINYVIT_USE_HW_RMSNORM
    rc = run_rmsnorm((const void *)token, tinyvit_norm1_gain,
                     (void *)normal, TOKENS, MODEL_DIM, 0x524e3031u);
    if (rc != 0) { result->error = -175 + rc; return result->error; }
#else
    rmsnorm(token, normal, tinyvit_norm1_gain, TOKENS, MODEL_DIM);
#endif

    rc = run_gemm((const void *)normal, qkv_weight_store,
                  (void *)qkv_linear, qkv_bias_store,
                  TOKENS, MODEL_DIM * 3u, MODEL_DIM, 1,
                  MODEL_DIM, MODEL_DIM * 3u, MODEL_DIM * 3u,
                  0, 0, 0, TINYVIT_Q_SHIFT,
                  LSME_FLAG_OUTPUT_INT8 | LSME_FLAG_BIAS, 0x514b5650u);
    if (rc != 0) { result->error = -200 + rc; return result->error; }
#if TINYVIT_ZERO_COPY_HEAD_LAYOUT
    // qkv_linear 的每个 token 占 96B：Q/K/V 各 32B。对第 h 个 head，
    // Q、K、V 的起始列分别为 h*8、32+h*8、64+h*8；batch_stride=8
    // 使 V2 GEMM 在四个 head 间切换时只移动一个 8B 子向量，而每一 token
    // 的实际行间距仍保留 96B。这是零拷贝的关键。
    rc = run_gemm((const void *)qkv_linear,
                  (const void *)(qkv_linear + MODEL_DIM),
                  (void *)score, NULL,
                  TOKENS, TOKENS, HEAD_DIM, HEADS,
                  MODEL_DIM * 3u, MODEL_DIM * 3u,
                  TOKENS * sizeof(int32_t),
                  HEAD_DIM, HEAD_DIM,
                  TOKENS * TOKENS * sizeof(int32_t), 0,
                  LSME_FLAG_TRANS_B | LSME_FLAG_HEAD4, 0x4154544eu);
#else
    repack_qkv_heads(qkv_linear, q_head, k_head, v_head);
    rc = run_gemm((const void *)q_head, (const void *)k_head,
                  (void *)score, NULL,
                  TOKENS, TOKENS, HEAD_DIM, HEADS,
                  HEAD_DIM, HEAD_DIM, TOKENS * sizeof(int32_t),
                  TOKENS * HEAD_DIM, TOKENS * HEAD_DIM,
                  TOKENS * TOKENS * sizeof(int32_t), 0,
                  LSME_FLAG_TRANS_B | LSME_FLAG_HEAD4, 0x4154544eu);
#endif
    if (rc != 0) { result->error = -500 + rc; return result->error; }
    rc = run_softmax((const int32_t *)score, (uint8_t *)probability);
    if (rc != 0) { result->error = -600 + rc; return result->error; }
#if TINYVIT_ZERO_COPY_HEAD_LAYOUT
    // 结果地址采用 dst_row_stride=32、dst_batch_stride=8，因此 C[q,h,d]
    // 直接落在 context[q][h*8+d]，省去 context_head_store 和 merge_heads。
    rc = run_gemm((const void *)probability,
                  (const void *)(qkv_linear + MODEL_DIM * 2u),
                  (void *)context, NULL,
                  TOKENS, HEAD_DIM, TOKENS, HEADS,
                  TOKENS, MODEL_DIM * 3u, MODEL_DIM,
                  TOKENS * TOKENS, HEAD_DIM, HEAD_DIM,
                  TINYVIT_CONTEXT_SHIFT,
                  LSME_FLAG_OUTPUT_INT8 | LSME_FLAG_HEAD4, 0x434f4e54u);
#else
    rc = run_gemm((const void *)probability, (const void *)v_head,
                  (void *)context_head, NULL,
                  TOKENS, HEAD_DIM, TOKENS, HEADS,
                  TOKENS, HEAD_DIM, HEAD_DIM,
                  TOKENS * TOKENS, TOKENS * HEAD_DIM, TOKENS * HEAD_DIM,
                  TINYVIT_CONTEXT_SHIFT,
                  LSME_FLAG_OUTPUT_INT8 | LSME_FLAG_HEAD4, 0x434f4e54u);
#endif
    if (rc != 0) { result->error = -700 + rc; return result->error; }
#if !TINYVIT_ZERO_COPY_HEAD_LAYOUT
    merge_heads(context_head, context);
#endif

    rc = run_gemm((const void *)context, tinyvit_projection_weight,
                  (void *)projection, tinyvit_projection_bias,
                  TOKENS, MODEL_DIM, MODEL_DIM, 1,
                  MODEL_DIM, MODEL_DIM, MODEL_DIM, 0, 0, 0,
                  TINYVIT_PROJECTION_SHIFT,
                  LSME_FLAG_OUTPUT_INT8 | LSME_FLAG_BIAS, 0x50524f4au);
    if (rc != 0) { result->error = -800 + rc; return result->error; }
#if TINYVIT_USE_HW_VADD
    rc = run_vadd((const void *)token, (const void *)projection,
                  (void *)token, TOKENS, MODEL_DIM,
                  MODEL_DIM, MODEL_DIM, MODEL_DIM, 0x52455331u);
    if (rc != 0) { result->error = -850 + rc; return result->error; }
#else
    residual_add(token, projection);
#endif
#if TINYVIT_USE_HW_RMSNORM
    rc = run_rmsnorm((const void *)token, tinyvit_norm2_gain,
                     (void *)normal, TOKENS, MODEL_DIM, 0x524e3032u);
    if (rc != 0) { result->error = -875 + rc; return result->error; }
#else
    rmsnorm(token, normal, tinyvit_norm2_gain, TOKENS, MODEL_DIM);
#endif

    rc = run_gemm((const void *)normal, tinyvit_mlp1_weight,
                  (void *)hidden, tinyvit_mlp1_bias,
                  TOKENS, MLP_DIM, MODEL_DIM, 1,
                  MODEL_DIM, MLP_DIM, MLP_DIM, 0, 0, 0,
                  TINYVIT_MLP1_SHIFT,
                  LSME_FLAG_OUTPUT_INT8 | LSME_FLAG_BIAS | LSME_FLAG_RELU,
                  0x4d4c5031u);
    if (rc != 0) { result->error = -900 + rc; return result->error; }
    rc = run_gemm((const void *)hidden, tinyvit_mlp2_weight,
                  (void *)mlp, tinyvit_mlp2_bias,
                  TOKENS, MODEL_DIM, MLP_DIM, 1,
                  MLP_DIM, MODEL_DIM, MODEL_DIM, 0, 0, 0,
                  TINYVIT_MLP2_SHIFT,
                  LSME_FLAG_OUTPUT_INT8 | LSME_FLAG_BIAS, 0x4d4c5032u);
    if (rc != 0) { result->error = -1000 + rc; return result->error; }
#if TINYVIT_USE_HW_VADD
    rc = run_vadd((const void *)token, (const void *)mlp,
                  (void *)token, TOKENS, MODEL_DIM,
                  MODEL_DIM, MODEL_DIM, MODEL_DIM, 0x52455332u);
    if (rc != 0) { result->error = -1050 + rc; return result->error; }
#else
    residual_add(token, mlp);
#endif
#if TINYVIT_USE_HW_RMSNORM
    rc = run_rmsnorm((const void *)token, tinyvit_norm3_gain,
                     (void *)final, TOKENS, MODEL_DIM, 0x524e3033u);
    if (rc != 0) { result->error = -1075 + rc; return result->error; }
#else
    rmsnorm(token, final, tinyvit_norm3_gain, TOKENS, MODEL_DIM);
#endif
    pool_tokens(final, classifier_input);

    rc = run_gemm((const void *)classifier_input, tinyvit_classifier_weight,
                  (void *)classifier_output, tinyvit_classifier_bias,
                  4, CLASSES_PADDED, MODEL_DIM, 1,
                  MODEL_DIM, CLASSES_PADDED,
                  CLASSES_PADDED * sizeof(int32_t), 0, 0, 0, 0,
                  LSME_FLAG_BIAS, 0x434c4153u);
    if (rc != 0) { result->error = -1100 + rc; return result->error; }

    result->cycles = (uint32_t)get_cpu_clock_count() - start_cycles;
    result->descriptors = lsme_read(LSME_REG_PERF_DESC) - descriptor_before;
    result->mopa_count = lsme_read(LSME_REG_PERF_MOPA);
    result->gemm_tiles = lsme_read(LSME_REG_PERF_TILES) - tiles_before;
    result->softmax_rows = lsme_read(LSME_REG_PERF_SOFTMAX) - softmax_before;
#if TINYVIT_USE_HW_RMSNORM
    result->rmsnorm_rows = lsme_read(LSME_REG_PERF_RMSNORM) - rmsnorm_before;
#else
    // 软件回退没有硬件行计数器；保留 0 以便串口/DVI 能诚实展示该模式。
    result->rmsnorm_rows = 0;
#endif
    result->engine_cycles = lsme_read(LSME_REG_PERF_ENGINE) - engine_before;
    result->axi_read_beats = lsme_read(LSME_REG_PERF_AXI_READ) -
                             read_beats_before;
    result->axi_write_beats = lsme_read(LSME_REG_PERF_AXI_WRITE) -
                              write_beats_before;
    result->compute_cycles = lsme_read(LSME_REG_PERF_COMPUTE) -
                             compute_before;
    result->memory_stall_cycles = lsme_read(LSME_REG_PERF_STALL) -
                                  stall_before;
    result->overlap_cycles = lsme_read(LSME_REG_PERF_OVERLAP) -
                             overlap_before;
    result->last_descriptor_cycles = lsme_read(LSME_REG_LAST_DESC);
    result->predicted = 0;
    for (index = 0; index < 10; ++index) {
        result->logits[index] = classifier_output[index];
        if (result->logits[index] !=
            tinyvit_demo_expected_logits[sample * 10u + index])
            result->bit_exact = 0;
        if (result->logits[index] > result->logits[result->predicted])
            result->predicted = (uint8_t)index;
    }
    result->expected = tinyvit_demo_labels[sample];
    result->test_index = tinyvit_demo_indices[sample];
    make_class_scores(result->logits, result->class_scores);
    make_attention_map(probability, result->attention_map);
#if TINYVIT_ZERO_COPY_HEAD_LAYOUT && TINYVIT_LAYOUT_STABLE
    retain_legacy_attention_layout();
    /* 40 条 nop 与地址锚点共同补齐 224B，且不计入 result->cycles。 */
    __asm__ volatile (
        ".rept 40\n"
        "nop\n"
        ".endr\n"
        ::: "memory");
#endif
    return 0;
}
