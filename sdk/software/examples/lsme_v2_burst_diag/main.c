#include <stdint.h>
#include <stdio.h>

#include "lsme.h"

/* 启动代码使用这些全局变量完成串口、时钟和计时器初始化。 */
unsigned long UART_BASE = 0xbf000000;
unsigned long CONFREG_TIMER_BASE = 0xbf20f100;
unsigned long CONFREG_CLOCKS_PER_SEC = 50000000L;
unsigned long CORE_CLOCKS_PER_SEC = 33000000L;

/*
 * 此规模刻意大于旧 self-test 的 4x4x4：
 * A 的每一行有 32 B（8 个 AXI beat），B 的每一行有 8 B，
 * 输出每一行有 32 B。因此 V2 cached 模式会实际走连续 burst 读和 burst 写。
 */
#define DIAG_M 8u
#define DIAG_N 8u
#define DIAG_K 32u

static int8_t a_store[DIAG_M * DIAG_K] __attribute__((aligned(64)));
static int8_t b_store[DIAG_K * DIAG_N] __attribute__((aligned(64)));
static int32_t stream_store[DIAG_M * DIAG_N] __attribute__((aligned(64)));
static int32_t cached_store[DIAG_M * DIAG_N] __attribute__((aligned(64)));
static lsme_descriptor_t descriptor_store __attribute__((aligned(64)));

static int8_t a_value(unsigned int row, unsigned int column)
{
    return (int8_t)(((row * 7u + column * 5u + 3u) % 15u) - 7);
}

static int8_t b_value(unsigned int row, unsigned int column)
{
    return (int8_t)(((row * 11u + column * 3u + 1u) % 17u) - 8);
}

static int32_t expected_value(unsigned int row, unsigned int column)
{
    int32_t sum = 0;
    unsigned int k;

    for (k = 0; k < DIAG_K; ++k)
        sum += (int32_t)a_value(row, k) * (int32_t)b_value(k, column);
    return sum;
}

static void initialize_operands(volatile int8_t *a, volatile int8_t *b)
{
    unsigned int row;
    unsigned int column;

    for (row = 0; row < DIAG_M; ++row)
        for (column = 0; column < DIAG_K; ++column)
            a[row * DIAG_K + column] = a_value(row, column);
    for (row = 0; row < DIAG_K; ++row)
        for (column = 0; column < DIAG_N; ++column)
            b[row * DIAG_N + column] = b_value(row, column);
}

static void clear_output(volatile int32_t *output)
{
    unsigned int index;

    for (index = 0; index < DIAG_M * DIAG_N; ++index)
        output[index] = 0x55aa55aa;
}

static int check_output(const char *name, volatile int32_t *output)
{
    unsigned int row;
    unsigned int column;
    unsigned int mismatch_count = 0;
    unsigned int first_row = 0;
    unsigned int first_column = 0;
    int32_t first_expected = 0;
    int32_t first_observed = 0;

    for (row = 0; row < DIAG_M; ++row) {
        for (column = 0; column < DIAG_N; ++column) {
            int32_t expected = expected_value(row, column);
            int32_t observed = output[row * DIAG_N + column];

            if (observed != expected) {
                if (mismatch_count == 0u) {
                    first_row = row;
                    first_column = column;
                    first_expected = expected;
                    first_observed = observed;
                }
                ++mismatch_count;
            }
        }
    }

    if (mismatch_count == 0u) {
        printf("V2_BURST_%s match=1 mismatches=0\n", name);
        return 0;
    }
    printf("V2_BURST_%s match=0 mismatches=%u first=r%u,c%u exp=%d got=%d\n",
           name, mismatch_count, first_row, first_column,
           first_expected, first_observed);
    return -1;
}

static int run_gemm(uint32_t mode, volatile int8_t *a, volatile int8_t *b,
                    volatile int32_t *output,
                    volatile lsme_descriptor_t *descriptor)
{
    int rc;

    clear_output(output);
    lsme_descriptor_clear(descriptor);
    descriptor->op_flags = lsme_descriptor_op_flags(LSME_OP_GEMM, 0);
    descriptor->src0 = (uint32_t)(uintptr_t)a;
    descriptor->src1 = (uint32_t)(uintptr_t)b;
    descriptor->dst = (uint32_t)(uintptr_t)output;
    descriptor->m_n = lsme_pack_u16(DIAG_M, DIAG_N);
    descriptor->k_batch = lsme_pack_u16(DIAG_K, 1);
    descriptor->src0_row_stride = DIAG_K;
    descriptor->src1_row_stride = DIAG_N;
    descriptor->dst_row_stride = DIAG_N * sizeof(int32_t);
    descriptor->user_tag = 0x42525354u; /* ASCII "BRST"：burst 诊断。 */
    descriptor->aux0 = lsme_descriptor_v2_aux(mode);

    lsme_memory_barrier();
    rc = (int)lsme_lacc_exec(descriptor);
    if (rc == 0)
        rc = (int)lsme_lacc_wait();
    lsme_memory_barrier();
    return rc;
}

static void print_counters(const char *name, uint32_t desc_before,
                           uint32_t read_before, uint32_t write_before,
                           uint32_t tile_before)
{
    printf("V2_BURST_%s_COUNTER desc=%u read=%u write=%u tiles=%u\n", name,
           lsme_read(LSME_REG_PERF_DESC) - desc_before,
           lsme_read(LSME_REG_PERF_AXI_READ) - read_before,
           lsme_read(LSME_REG_PERF_AXI_WRITE) - write_before,
           lsme_read(LSME_REG_PERF_TILES) - tile_before);
}

int main(void)
{
    volatile int8_t *a = (volatile int8_t *)lsme_uncached_ptr(a_store);
    volatile int8_t *b = (volatile int8_t *)lsme_uncached_ptr(b_store);
    volatile int32_t *stream =
        (volatile int32_t *)lsme_uncached_ptr(stream_store);
    volatile int32_t *cached =
        (volatile int32_t *)lsme_uncached_ptr(cached_store);
    volatile lsme_descriptor_t *descriptor =
        (volatile lsme_descriptor_t *)lsme_uncached_ptr(&descriptor_store);
    uint32_t query;
    uint32_t capability;
    uint32_t desc_before;
    uint32_t read_before;
    uint32_t write_before;
    uint32_t tile_before;
    int stream_rc;
    int cached_rc;
    int stream_ok;
    int cached_ok;

    printf("LSME_V2_BURST_DIAG_BOOT\n");
    query = lsme_lacc_ctrl_query();
    capability = lsme_read(LSME_REG_CAPABILITY);
    printf("V2_BURST_CAP lacc=%08x csr=%08x shape=%ux%ux%u\n",
           query, capability, DIAG_M, DIAG_N, DIAG_K);

    initialize_operands(a, b);
    lsme_memory_barrier();
    lsme_lacc_ctrl_clear();

    desc_before = lsme_read(LSME_REG_PERF_DESC);
    read_before = lsme_read(LSME_REG_PERF_AXI_READ);
    write_before = lsme_read(LSME_REG_PERF_AXI_WRITE);
    tile_before = lsme_read(LSME_REG_PERF_TILES);
    stream_rc = run_gemm(LSME_V2_MODE_STREAM, a, b, stream, descriptor);
    stream_ok = stream_rc == 0 && check_output("STREAM", stream) == 0;
    printf("V2_BURST_STREAM rc=%d\n", stream_rc);
    print_counters("STREAM", desc_before, read_before, write_before,
                   tile_before);

    desc_before = lsme_read(LSME_REG_PERF_DESC);
    read_before = lsme_read(LSME_REG_PERF_AXI_READ);
    write_before = lsme_read(LSME_REG_PERF_AXI_WRITE);
    tile_before = lsme_read(LSME_REG_PERF_TILES);
    cached_rc = run_gemm(LSME_V2_MODE_CACHED, a, b, cached, descriptor);
    cached_ok = cached_rc == 0 && check_output("CACHED", cached) == 0;
    printf("V2_BURST_CACHED rc=%d\n", cached_rc);
    print_counters("CACHED", desc_before, read_before, write_before,
                   tile_before);

    if (stream_ok && cached_ok) {
        printf("LSME_V2_BURST_DIAG_PASS\n");
        return 0;
    }
    if (!stream_ok)
        printf("LSME_V2_BURST_DIAG_STREAM_FAIL\n");
    if (!cached_ok)
        printf("LSME_V2_BURST_DIAG_CACHED_FAIL\n");
    return 1;
}
