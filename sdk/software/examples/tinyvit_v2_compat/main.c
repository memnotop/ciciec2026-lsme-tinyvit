#include <stdint.h>
#include <stdio.h>

#include "common_func.h"
#include "confreg_time.h"
#include "dvi.h"
#include "led.h"
#include "lsme.h"
#include "seg7.h"
#include "../tinyvit_demo/tinyvit_runtime.h"

/* 启动代码用这些全局变量完成串口、时钟和计时器初始化。 */
unsigned long UART_BASE = 0xbf000000;
unsigned long CONFREG_TIMER_BASE = 0xbf20f100;
unsigned long CONFREG_CLOCKS_PER_SEC = 50000000L;
unsigned long CORE_CLOCKS_PER_SEC = 33000000L;

#define CONFREG_SWITCH          0xbf20f400u
#define CONFREG_SIMULATION      0xbf20f500u
#define DEMO_AUTOPLAY_MS        1800u
#define DEMO_ACCURACY_X10000    8564u
#define V1_REFERENCE_CYCLES     1827549u
#define V2_CACHED_REFERENCE_CYCLES 1007062u

static tinyvit_result_t result;

/* SW[3:0] 选择真实样例；SW[15] 打开后，每 1.8 秒自动轮播十个样例。 */
static unsigned int select_sample(uint32_t switches, uint32_t now_ms)
{
    unsigned int sample;

    if ((switches & (1u << 15)) != 0u)
        sample = (unsigned int)((now_ms / DEMO_AUTOPLAY_MS) % 10u);
    else
        sample = switches & 0xfu;
    return sample < 10u ? sample : 0u;
}

static uint32_t speedup_x1000(uint32_t cycles)
{
    if (cycles == 0u)
        return 0u;
    return (uint32_t)(((uint64_t)V1_REFERENCE_CYCLES * 1000u + cycles / 2u)
                      / cycles);
}

static uint32_t v2_speedup_x1000(uint32_t cycles)
{
    if (cycles == 0u)
        return 0u;
    return (uint32_t)(((uint64_t)V2_CACHED_REFERENCE_CYCLES * 1000u
                       + cycles / 2u) / cycles);
}

/*
 * DVI 图像、注意力热图、类别得分和性能计数均来自本次真实推理。
 * status=0 同时代表整数参考逐位一致和分类正确，因此可驱动现有 PASS 指示灯。
 */
static int run_and_publish(unsigned int sample)
{
    uint32_t status;
    uint32_t speedup;
    uint32_t v2_speedup;
    int rc;

    printf("V2Z_STAGE=1 INPUT sample=%u\n", sample);
    printf("V2Z_STAGE=2 EXEC path=V2_cached+Softmax+VADD+SW_RMSNorm+ZC_VIEW\n");
    rc = tinyvit_infer(sample, &result);
    if (rc != 0) {
        printf("V2Z_ACCEL_FAIL %d\n", rc);
        setLedPin(0xffffu);
        return rc;
    }

    status = result.bit_exact ? 0u : 2u;
    if (result.predicted != result.expected)
        status |= 1u;
    DVI_XAI_Publish(tinyvit_sample_image(sample), result.attention_map,
                    result.class_scores, result.predicted, result.expected,
                    sample, result.lanes, result.cycles, result.mopa_count,
                    result.gemm_tiles, result.descriptors,
                    DEMO_ACCURACY_X10000, result.test_index, status);
    setLedPin(1u << result.predicted);
    setSegNum(0, result.expected, 1, result.predicted);

    speedup = speedup_x1000(result.cycles);
    v2_speedup = v2_speedup_x1000(result.cycles);
    printf("V2Z_STAGE=3 XAI DVI=published heatmap=8x8 classes=10\n");
    printf("V2Z_RESULT expected=%u predicted=%u exact=%u\n",
           result.expected, result.predicted, result.bit_exact);
    printf("V2Z_METRIC cycles=%u desc=%u mopa=%u tiles=%u softmax=%u "
           "hw_rms_rows=%u speedup_vs_v1=%u.%03ux speedup_vs_v2=%u.%03ux\n",
           result.cycles, result.descriptors, result.mopa_count,
           result.gemm_tiles, result.softmax_rows, result.rmsnorm_rows,
           speedup / 1000u, speedup % 1000u,
           v2_speedup / 1000u, v2_speedup % 1000u);
    if (status == 0u) {
        printf("TINYVIT_V2_ZEROCOPY_PASS\n");
        return 0;
    }
    printf("TINYVIT_V2_ZEROCOPY_FAIL %u\n", status);
    return -(int)status;
}

int main(void)
{
    uint32_t query;
    uint32_t capability;
    uint32_t switches;
    unsigned int sample;
    unsigned int previous;
    int rc;

    /* 该行位于所有 LACC、AXI 和 DVI 访问之前，可作为远程启动探针。 */
    printf("TINYVIT_BOOT_V2_ZEROCOPY_SW_RMSNORM\n");
    query = lsme_lacc_ctrl_query();
    capability = lsme_read(LSME_REG_CAPABILITY);
    printf("V2Z_CAP lacc=%08x csr=%08x\n", query, capability);
    printf("V2Z_ENGINE macro8=1 cached_gemm=1 softmax=1 vadd=1 hw_rmsnorm=0\n");
    printf("V2Z_OPT qkv_view=1 context_direct=1 baseline_v2_cycles=%u\n",
           V2_CACHED_REFERENCE_CYCLES);
    printf("V2Z_CONTROL manual=SW[3:0] carousel=SW[15]\n");

    switches = RegRead(CONFREG_SWITCH);
    sample = select_sample(switches, (uint32_t)get_us() / 1000u);
    rc = run_and_publish(sample);
    if (RegRead(CONFREG_SIMULATION) != 0u)
        return rc == 0 ? 0 : 1;

    previous = sample;
    for (;;) {
        switches = RegRead(CONFREG_SWITCH);
        sample = select_sample(switches, (uint32_t)get_us() / 1000u);
        if (sample != previous) {
            previous = sample;
            run_and_publish(sample);
        }
    }
}
