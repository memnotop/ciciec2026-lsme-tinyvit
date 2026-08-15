/*
 * V2 Cached Macro8 + 硬件 RMSNorm 板端预检。
 *
 * 不依赖 TinyViT 完整模型参数，适合在远程平台上先运行：
 *   1. 校验 8x8x32 INT8 GEMM 的 V2 Cached Macro8 路径；
 *   2. 校验 64x32（模型同形状）的新增硬件 RMSNorm。
 *
 * 只有打印 LSME_V2_RMSNORM_PREFLIGHT_PASS 后，才应运行正式 TinyViT 演示。
 */

#include <stdint.h>
#include <stdio.h>

#include "lsme.h"

#define CAPABILITY_V2_RMSNORM 0x024040bfu
#define LSME_RESPONSE_OK 0u

#define PRE_M 8u
#define PRE_N 8u
#define PRE_K 32u
#define RMS_ROWS 64u
#define RMS_COLS 32u

#define ALIGNED64 __attribute__((aligned(64)))

/* 启动汇编从这些全局变量读取串口与时钟地址。 */
unsigned long UART_BASE = 0xbf000000;
unsigned long CONFREG_TIMER_BASE = 0xbf20f100;
unsigned long CONFREG_CLOCKS_PER_SEC = 50000000L;
unsigned long CORE_CLOCKS_PER_SEC = 33000000L;

static int8_t gemm_a[PRE_M * PRE_K] ALIGNED64;
/* B 按 K×N 保存，正好对应未置 TRANS_B 的普通 GEMM 描述符。 */
static int8_t gemm_b[PRE_K * PRE_N] ALIGNED64;
static int32_t gemm_c[PRE_M * PRE_N] ALIGNED64;
static int8_t rms_input[RMS_ROWS * RMS_COLS] ALIGNED64;
static int8_t rms_gain[RMS_COLS] ALIGNED64;
static int8_t rms_output[RMS_ROWS * RMS_COLS] ALIGNED64;
static lsme_descriptor_t descriptor_store ALIGNED64;

/* 在 LoongArch SoC 上，把缓存地址转换为加速器可见的非缓存地址。 */
static uint32_t accelerator_address(const void *pointer)
{
    return (uint32_t)(uintptr_t)lsme_uncached_ptr((void *)pointer);
}

static int8_t saturate_s8(int32_t value)
{
    if (value > 127) {
        return 127;
    }
    if (value < -128) {
        return -128;
    }
    return (int8_t)value;
}

/* 与硬件 lsme_isqrt32 的整数平方根语义一致：floor(sqrt(value))。 */
static uint32_t integer_sqrt(uint32_t value)
{
    uint32_t root = 0;
    uint32_t bit = 1u << 30;

    while (bit > value) {
        bit >>= 2;
    }
    while (bit != 0u) {
        if (value >= root + bit) {
            value -= root + bit;
            root = (root >> 1) + bit;
        } else {
            root >>= 1;
        }
        bit >>= 2;
    }
    return root;
}

/*
 * 硬件最终量化使用“绝对值除法 + 半入（远离零）舍入”。
 * 逐条复写固定点规则，避免浮点参考模型掩盖 RTL 的舍入错误。
 */
static int8_t rmsnorm_reference(int8_t input, int8_t gain, uint32_t rms)
{
    int32_t product = (int32_t)input * (int32_t)gain;
    int32_t numerator = product * 32; /* token_frac = 5 */
    uint32_t denominator = rms << 6;  /* gain_frac = 6 */
    uint32_t magnitude;
    uint32_t quotient;
    uint32_t remainder;
    int32_t rounded;

    if (denominator == 0u) {
        denominator = 1u;
    }
    magnitude = (numerator < 0) ? (uint32_t)(-numerator) : (uint32_t)numerator;
    quotient = magnitude / denominator;
    remainder = magnitude % denominator;
    if (remainder * 2u >= denominator) {
        quotient++;
    }
    rounded = (numerator < 0) ? -(int32_t)quotient : (int32_t)quotient;
    return saturate_s8(rounded);
}

static int execute_descriptor(volatile lsme_descriptor_t *descriptor)
{
    uint32_t status;

    lsme_memory_barrier();
    status = lsme_lacc_exec(descriptor);
    if ((status & 0xffu) != LSME_RESPONSE_OK) {
        printf("PREFLIGHT_EXEC_FAIL status=%08x\n", (unsigned)status);
        return -1;
    }
    status = lsme_lacc_wait();
    lsme_memory_barrier();
    if ((status & 0xffu) != LSME_RESPONSE_OK) {
        /* CSR status 的 bits[15:8] 保存执行引擎错误码。 */
        printf("PREFLIGHT_DESC_FAIL status=%08x csr_status=%08x\n",
               (unsigned)status, (unsigned)lsme_read(LSME_REG_STATUS));
        return -1;
    }
    return 0;
}

static int test_cached_macro8(void)
{
    volatile int8_t *a = (volatile int8_t *)lsme_uncached_ptr(gemm_a);
    volatile int8_t *b = (volatile int8_t *)lsme_uncached_ptr(gemm_b);
    volatile int32_t *c = (volatile int32_t *)lsme_uncached_ptr(gemm_c);
    volatile lsme_descriptor_t *descriptor =
        (volatile lsme_descriptor_t *)lsme_uncached_ptr(&descriptor_store);
    uint32_t tile_before;
    uint32_t mopa_before;
    uint32_t tile_after;
    uint32_t mopa_after;
    uint32_t status;
    uint32_t row;
    uint32_t column;
    int errors = 0;

    for (row = 0; row < PRE_M; ++row) {
        for (column = 0; column < PRE_K; ++column) {
            a[row * PRE_K + column] =
                (int8_t)((int)((row * 7u + column * 3u + 5u) % 15u) - 7);
        }
    }
    for (row = 0; row < PRE_K; ++row) {
        for (column = 0; column < PRE_N; ++column) {
            b[row * PRE_N + column] =
                (int8_t)((int)((row * 5u + column * 11u + 2u) % 17u) - 8);
        }
    }
    for (row = 0; row < PRE_M * PRE_N; ++row) {
        c[row] = 0x5a5a5a5a;
    }

    tile_before = lsme_read(LSME_REG_PERF_TILES);
    mopa_before = lsme_read(LSME_REG_PERF_MOPA);
    lsme_descriptor_clear(descriptor);
    descriptor->op_flags = lsme_descriptor_op_flags(LSME_OP_GEMM, 0);
    descriptor->src0 = accelerator_address((const void *)a);
    descriptor->src1 = accelerator_address((const void *)b);
    descriptor->dst = accelerator_address((const void *)c);
    descriptor->m_n = lsme_pack_u16(PRE_M, PRE_N);
    descriptor->k_batch = lsme_pack_u16(PRE_K, 1u);
    descriptor->src0_row_stride = PRE_K;
    descriptor->src1_row_stride = PRE_N;
    descriptor->dst_row_stride = PRE_N * sizeof(int32_t);
    descriptor->aux0 = lsme_descriptor_v2_aux(LSME_V2_MODE_CACHED);
    if (execute_descriptor(descriptor) != 0) {
        return -1;
    }

    tile_after = lsme_read(LSME_REG_PERF_TILES);
    mopa_after = lsme_read(LSME_REG_PERF_MOPA);
    status = lsme_read(LSME_REG_STATUS);
    for (row = 0; row < PRE_M; ++row) {
        for (column = 0; column < PRE_N; ++column) {
            uint32_t depth;
            int32_t expected = 0;
            for (depth = 0; depth < PRE_K; ++depth) {
                expected += (int32_t)a[row * PRE_K + depth] *
                            (int32_t)b[depth * PRE_N + column];
            }
            if (c[row * PRE_N + column] != expected) {
                if (errors < 3) {
                    printf("PREFLIGHT_MACRO8_MISMATCH r=%u c=%u got=%d exp=%d\n",
                           (unsigned)row, (unsigned)column,
                           (int)c[row * PRE_N + column], (int)expected);
                }
                errors++;
            }
        }
    }
    printf("PREFLIGHT_MACRO8 tiles=%u mopa=%u schedule=%u errors=%d\n",
           (unsigned)(tile_after - tile_before),
           (unsigned)(mopa_after - mopa_before),
           (unsigned)((status >> 3) & 0x3u), errors);
    if (errors != 0 || (tile_after - tile_before) != 1u ||
        (mopa_after - mopa_before) == 0u || ((status >> 3) & 0x3u) != 3u) {
        return -1;
    }
    return 0;
}

static int test_rmsnorm(void)
{
    volatile int8_t *input = (volatile int8_t *)lsme_uncached_ptr(rms_input);
    volatile int8_t *gain = (volatile int8_t *)lsme_uncached_ptr(rms_gain);
    volatile int8_t *output = (volatile int8_t *)lsme_uncached_ptr(rms_output);
    volatile lsme_descriptor_t *descriptor =
        (volatile lsme_descriptor_t *)lsme_uncached_ptr(&descriptor_store);
    uint32_t row_before;
    uint32_t row_after;
    uint32_t row;
    uint32_t column;
    int errors = 0;

    for (column = 0; column < RMS_COLS; ++column) {
        int gain_value = (int)((column * 19u + 37u) % 127u) - 63;
        if (column == 3u) {
            gain_value = -96;
        } else if (column == 7u) {
            gain_value = 96;
        }
        gain[column] = (int8_t)gain_value;
    }
    for (row = 0; row < RMS_ROWS; ++row) {
        for (column = 0; column < RMS_COLS; ++column) {
            input[row * RMS_COLS + column] =
                (int8_t)((int)((row * 29u + column * 17u + 7u) % 255u) - 127);
            output[row * RMS_COLS + column] = 0x55;
        }
    }

    row_before = lsme_read(LSME_REG_PERF_RMSNORM);
    lsme_descriptor_clear(descriptor);
    descriptor->op_flags = lsme_descriptor_op_flags(
        LSME_OP_RMSNORM, LSME_FLAG_OUTPUT_INT8);
    descriptor->src0 = accelerator_address((const void *)input);
    descriptor->src1 = accelerator_address((const void *)gain);
    descriptor->dst = accelerator_address((const void *)output);
    descriptor->m_n = lsme_pack_u16(RMS_ROWS, RMS_COLS);
    descriptor->k_batch = lsme_pack_u16(0u, 1u);
    descriptor->src0_row_stride = RMS_COLS;
    descriptor->dst_row_stride = RMS_COLS;
    descriptor->quant_head = lsme_pack_quant_head(5u, 6u, 0u, 0u);
    if (execute_descriptor(descriptor) != 0) {
        return -1;
    }

    row_after = lsme_read(LSME_REG_PERF_RMSNORM);
    for (row = 0; row < RMS_ROWS; ++row) {
        uint32_t sum_squares = 0;
        uint32_t rms;
        for (column = 0; column < RMS_COLS; ++column) {
            int32_t value = input[row * RMS_COLS + column];
            sum_squares += (uint32_t)(value * value);
        }
        rms = integer_sqrt(sum_squares / RMS_COLS);
        if (rms == 0u) {
            rms = 1u;
        }
        for (column = 0; column < RMS_COLS; ++column) {
            int8_t expected = rmsnorm_reference(input[row * RMS_COLS + column],
                                                gain[column], rms);
            int8_t actual = output[row * RMS_COLS + column];
            if (actual != expected) {
                if (errors < 3) {
                    printf("PREFLIGHT_RMS_MISMATCH r=%u c=%u got=%d exp=%d rms=%u\n",
                           (unsigned)row, (unsigned)column, (int)actual,
                           (int)expected, (unsigned)rms);
                }
                errors++;
            }
        }
    }
    printf("PREFLIGHT_RMSNORM rows=%u errors=%d\n",
           (unsigned)(row_after - row_before), errors);
    if (errors != 0 || (row_after - row_before) != RMS_ROWS) {
        return -1;
    }
    return 0;
}

int main(void)
{
    uint32_t lacc_capability = lsme_lacc_ctrl_query();
    uint32_t csr_capability = lsme_read(LSME_REG_CAPABILITY);
    int failed = 0;

    printf("LSME_V2_RMSNORM_PREFLIGHT_BOOT\n");
    printf("PREFLIGHT_CAP lacc=%08x csr=%08x expected=%08x\n",
           (unsigned)lacc_capability, (unsigned)csr_capability,
           (unsigned)CAPABILITY_V2_RMSNORM);
    if (lacc_capability != CAPABILITY_V2_RMSNORM ||
        csr_capability != CAPABILITY_V2_RMSNORM) {
        printf("PREFLIGHT_CAP_FAIL\n");
        return 1;
    }

    lsme_lacc_ctrl_clear();
    if (test_cached_macro8() != 0) {
        failed = 1;
    }
    if (test_rmsnorm() != 0) {
        failed = 1;
    }
    if (failed != 0) {
        printf("LSME_V2_RMSNORM_PREFLIGHT_FAIL\n");
        return 1;
    }
    printf("LSME_V2_RMSNORM_PREFLIGHT_PASS\n");
    return 0;
}
