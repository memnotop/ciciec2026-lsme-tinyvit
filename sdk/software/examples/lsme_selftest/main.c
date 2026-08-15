#include <stdio.h>
#include <stdint.h>
#include "lsme.h"

unsigned long UART_BASE = 0xbf000000;
unsigned long CONFREG_TIMER_BASE = 0xbf20f100;
unsigned long CONFREG_CLOCKS_PER_SEC = 50000000L;
unsigned long CORE_CLOCKS_PER_SEC = 33000000L;

static int8_t matrix_a_store[16] __attribute__((aligned(64)));
static int8_t matrix_b_store[16] __attribute__((aligned(64)));
static int32_t low_result_store[16] __attribute__((aligned(64)));
static int32_t exec_result_store[16] __attribute__((aligned(64)));
static int32_t score_store[8] __attribute__((aligned(64)));
static uint8_t probability_store[8] __attribute__((aligned(64)));
static lsme_descriptor_t descriptor_store __attribute__((aligned(64)));

/* 诊断时可用 -DLSME_SELFTEST_MODE=2 强制 V1 流式 GEMM；默认仍测试 V2。 */
#ifndef LSME_SELFTEST_MODE
#define LSME_SELFTEST_MODE LSME_V2_MODE_AUTO
#endif

static int check_matrix(volatile int32_t *result,
                        volatile int8_t *a,
                        volatile int8_t *b)
{
    int row;
    int col;
    int k;

    for (row = 0; row < 4; ++row) {
        for (col = 0; col < 4; ++col) {
            int expected = 0;
            for (k = 0; k < 4; ++k)
                expected += a[row * 4 + k] * b[k * 4 + col];
            if (result[row * 4 + col] != expected) {
                printf("matrix mismatch r=%d c=%d expected=%d got=%d\n",
                       row, col, expected, result[row * 4 + col]);
                return -1;
            }
        }
    }
    return 0;
}

int main(void)
{
    volatile int8_t *a = (volatile int8_t *)lsme_uncached_ptr(matrix_a_store);
    volatile int8_t *b = (volatile int8_t *)lsme_uncached_ptr(matrix_b_store);
    volatile int32_t *low_result =
        (volatile int32_t *)lsme_uncached_ptr(low_result_store);
    volatile int32_t *exec_result =
        (volatile int32_t *)lsme_uncached_ptr(exec_result_store);
    volatile int32_t *scores =
        (volatile int32_t *)lsme_uncached_ptr(score_store);
    volatile uint8_t *probabilities =
        (volatile uint8_t *)lsme_uncached_ptr(probability_store);
    volatile lsme_descriptor_t *descriptor =
        (volatile lsme_descriptor_t *)lsme_uncached_ptr(&descriptor_store);
    uint32_t feature;
    int i;
    int rc;

    printf("LSME-128I self-test start\n");
    printf("sync=DBAR mode=%u\n", (unsigned)LSME_SELFTEST_MODE);
    feature = lsme_lacc_ctrl_query();
    printf("feature=0x%08x lanes=%u\n", feature, (feature >> 16) & 0xffu);
    if ((feature >> 24) != 2 || ((feature >> 16) & 0xffu) == 0) {
        printf("LSME_SELFTEST_FAIL feature\n");
        return 1;
    }

    for (i = 0; i < 16; ++i) {
        a[i] = (int8_t)((i * 3) % 11 - 5);
        b[i] = (int8_t)((i * 5 + 2) % 13 - 6);
        low_result[i] = 0;
        exec_result[i] = 0;
    }
    lsme_memory_barrier();

    lsme_lacc_ctrl_clear();
    lsme_lacc_pset_p0(0xffffu);
    lsme_lacc_pset_p1(0xffffu);
    lsme_lacc_zero_za0();
    lsme_lacc_ldz_z0((const void *)a, 4);
    lsme_lacc_ldzt_z1((const void *)b, 4);
    lsme_lacc_smopa(0x108u);
    lsme_lacc_stza_s32((void *)low_result, 16);
    lsme_memory_barrier();
    if (check_matrix(low_result, a, b) != 0) {
        printf("LSME_SELFTEST_FAIL low-level\n");
        return 2;
    }
    printf("low-level SMOPA pass\n");

    lsme_descriptor_clear(descriptor);
    descriptor->op_flags = lsme_descriptor_op_flags(LSME_OP_GEMM, 0);
    descriptor->src0 = (uint32_t)(uintptr_t)a;
    descriptor->src1 = (uint32_t)(uintptr_t)b;
    descriptor->dst = (uint32_t)(uintptr_t)exec_result;
    descriptor->m_n = lsme_pack_u16(4, 4);
    descriptor->k_batch = lsme_pack_u16(4, 1);
    descriptor->src0_row_stride = 4;
    descriptor->src1_row_stride = 4;
    descriptor->dst_row_stride = 16;
    descriptor->user_tag = 0x47454d4du;
    descriptor->aux0 = lsme_descriptor_v2_aux(LSME_SELFTEST_MODE);
    lsme_memory_barrier();
    rc = (int)lsme_lacc_exec(descriptor);
    if (rc == 0)
        rc = (int)lsme_lacc_wait();
    lsme_memory_barrier();
    if (rc != 0 || check_matrix(exec_result, a, b) != 0) {
        printf("LSME_SELFTEST_FAIL descriptor rc=%d\n", rc);
        return 3;
    }
    printf("descriptor GEMM pass\n");

    for (i = 0; i < 8; ++i) {
        scores[i] = i * 19 - i * i * 2 - 30;
        probabilities[i] = 0;
    }
    lsme_descriptor_clear(descriptor);
    descriptor->op_flags = lsme_descriptor_op_flags(LSME_OP_SOFTMAX, 0);
    descriptor->src0 = (uint32_t)(uintptr_t)scores;
    descriptor->dst = (uint32_t)(uintptr_t)probabilities;
    descriptor->m_n = lsme_pack_u16(1, 8);
    descriptor->k_batch = lsme_pack_u16(0, 1);
    descriptor->src0_row_stride = 32;
    descriptor->dst_row_stride = 8;
    descriptor->quant_head = lsme_pack_quant_head(0, 2, 0, 0);
    descriptor->user_tag = 0x534f4654u;
    lsme_memory_barrier();
    rc = lsme_submit_mmio(descriptor, 1000000u);
    lsme_memory_barrier();
    if (rc != 0 || probabilities[7] <= probabilities[0]) {
        printf("LSME_SELFTEST_FAIL softmax rc=%d p0=%u p7=%u\n",
               rc, probabilities[0], probabilities[7]);
        return 4;
    }

    printf("softmax pass: ");
    for (i = 0; i < 8; ++i)
        printf("%u%c", probabilities[i], i == 7 ? '\n' : ' ');
    printf("perf desc=%u mopa=%u tiles=%u softmax_rows=%u\n",
           lsme_read(LSME_REG_PERF_DESC), lsme_read(LSME_REG_PERF_MOPA),
           lsme_read(LSME_REG_PERF_TILES),
           lsme_read(LSME_REG_PERF_SOFTMAX));
    printf("LSME_SELFTEST_PASS\n");
    return 0;
}
